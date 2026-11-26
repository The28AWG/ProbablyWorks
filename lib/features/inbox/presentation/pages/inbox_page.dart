import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/backend/backend_status.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/chats/presentation/bloc/chat_list_cubit.dart';
import 'package:probably_works/features/workspace/presentation/navigation/workspace_navigation.dart';
import 'package:probably_works/features/workspace/presentation/widgets/workspace_shell.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/domain/chat_attention.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/turn/turn_file_kind.dart';
import 'package:pw_agent/core/domain/host.dart';

/// Входящие: решения и проблемы, собранные по всем чатам.
///
/// Экран не хранит свою копию карточек: снимок строит сервер, а действия идут
/// через [ChatListCubit]. Поэтому бейдж навигации и список не расходятся, а
/// закрытая в другом окне карточка исчезает здесь по SSE-событию.
@RoutePage(deferredLoading: true)
class InboxPage extends StatelessWidget {
  const InboxPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppScaffold(
      appBar: AppBar(
        leading: context.workspaceLayout == .compact
            ? const WorkspaceLeadingButton()
            : null,
        title: Text(
          l10n.inboxTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: l10n.commonRetry,
            icon: const Icon(Icons.refresh),
            onPressed: () => context.read<ChatListCubit>().refreshAttention(),
          ),
        ],
      ),
      maxWidth: AppLayout.pageMaxWidth,
      body: BackendStatusBuilder(
        builder: (context, status) {
          if (status == AgentStatus.offline) {
            return const BackendOfflineView();
          }
          return BlocBuilder<ChatListCubit, ChatListState>(
            buildWhen: (previous, current) =>
                previous.attention != current.attention ||
                previous.attentionLoading != current.attentionLoading ||
                previous.attentionError != current.attentionError ||
                previous.attentionSupported != current.attentionSupported ||
                previous.hosts != current.hosts,
            builder: (context, state) => _InboxBody(state: state),
          );
        },
      ),
    );
  }
}

class _InboxBody extends StatelessWidget {
  const _InboxBody({required this.state});

  final ChatListState state;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (!state.attentionSupported) {
      return AppEmptyState(
        icon: Icons.inbox_outlined,
        title: l10n.inboxEmptyTitle,
        message: l10n.inboxUnavailable,
      );
    }
    final error = state.attentionError;
    if (state.attentionLoading && state.attention.items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final hosts = {for (final host in state.hosts) host.id: host};
    final decisions = <Widget>[];
    final problems = <Widget>[];
    final unread = <Widget>[];
    for (final item in state.attention.items) {
      final host = hosts[item.hostId];
      final chatLabel = _chatLabel(item, host, l10n);
      if (item.approvals.length > 1) {
        decisions.add(
          _BulkApproveRow(
            count: item.approvals.length,
            onApprove: () => _approveAll(context, item),
          ),
        );
      }
      for (final approval in item.approvals) {
        decisions.add(
          _ApprovalInboxCard(
            item: item,
            request: approval,
            chatLabel: chatLabel,
          ),
        );
      }
      for (final question in item.questions) {
        decisions.add(
          _QuestionInboxCard(
            // Ключ привязан к вопросу: при перестановке карточек поле ответа
            // должно переезжать вместе со своим вопросом, а не с позицией.
            key: ValueKey(question.id),
            item: item,
            question: question,
            chatLabel: chatLabel,
          ),
        );
      }
      for (final request in item.editFileChanges) {
        decisions.add(
          _EditFilesInboxCard(
            item: item,
            request: request,
            chatLabel: chatLabel,
          ),
        );
      }
      if (item.hasProblem) {
        problems.add(_ProblemInboxCard(item: item, host: host));
      }
      if (!item.hasDecisions && !item.hasProblem && item.unreadCount > 0) {
        unread.add(_UnreadInboxCard(item: item, chatLabel: chatLabel));
      }
    }
    final content = <Widget>[
      if (error != null)
        AppBanner(
          message: l10n.inboxLoadFailed(error),
          icon: Icons.sync_problem,
          tone: AppTone.danger,
          action: TextButton(
            onPressed: () => context.read<ChatListCubit>().refreshAttention(),
            child: Text(l10n.commonRetry),
          ),
        ),
      if (decisions.isNotEmpty)
        AppSection(title: l10n.inboxDecisionsSection, children: decisions),
      if (problems.isNotEmpty) ...[
        if (decisions.isNotEmpty) const SizedBox(height: AppSpacing.xl),
        AppSection(title: l10n.inboxProblemsSection, children: problems),
      ],
      if (unread.isNotEmpty) ...[
        if (decisions.isNotEmpty || problems.isNotEmpty)
          const SizedBox(height: AppSpacing.xl),
        AppSection(title: l10n.inboxUnreadSection, children: unread),
      ],
    ];
    if (content.isEmpty) {
      return AppEmptyState(
        icon: Icons.inbox_outlined,
        title: l10n.inboxEmptyTitle,
        message: l10n.inboxEmptyMessage,
      );
    }
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: content,
    );
  }

  static String _chatLabel(
    ChatAttention item,
    Host? host,
    AppLocalizations l10n,
  ) {
    final title = item.title.trim().isEmpty ? l10n.chatsNew : item.title;
    // Локальный хост в базе называется `Local`; в интерфейсе его подпись
    // зависит от платформы и переводится, как в списке чатов.
    final hostName = host == null ? null : hostDisplayName(host, l10n).trim();
    if (hostName == null || hostName.isEmpty) return title;
    return '$title · $hostName';
  }

  static Future<void> _approveAll(
    BuildContext context,
    ChatAttention item,
  ) async {
    final cubit = context.read<ChatListCubit>();
    for (final request in item.approvals) {
      await cubit.approve(request.id);
    }
  }
}

class _BulkApproveRow extends StatelessWidget {
  const _BulkApproveRow({required this.count, required this.onApprove});

  final int count;
  final VoidCallback onApprove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Align(
      alignment: AlignmentDirectional.centerEnd,
      child: TextButton(
        onPressed: onApprove,
        child: Text(l10n.inboxBulkApprove(count)),
      ),
    );
  }
}

class _ApprovalInboxCard extends StatelessWidget {
  const _ApprovalInboxCard({
    required this.item,
    required this.request,
    required this.chatLabel,
  });

  final ChatAttention item;
  final ApprovalRequest request;
  final String chatLabel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cubit = context.read<ChatListCubit>();
    final diff = request.diff;
    return ActionCard(
      title: l10n.inboxApprovalTitle,
      icon: Icons.lock_clock_outlined,
      tone: AppTone.waiting,
      actions: [
        TextButton(
          onPressed: () => openChat(context, item.chatId),
          child: Text(l10n.inboxOpenChat),
        ),
        TextButton(
          onPressed: () => cubit.deny(request.id),
          child: Text(l10n.inboxDeny),
        ),
        FilledButton(
          onPressed: () => cubit.approve(request.id),
          child: Text(l10n.inboxApprove),
        ),
      ],
      children: [
        _ChatLabel(text: chatLabel),
        Text(request.reason, style: Theme.of(context).textTheme.bodyMedium),
        CodeBlock(text: request.summary, maxHeight: 160),
        if (diff != null && diff.isNotEmpty) DiffView(diff: diff),
      ],
    );
  }
}

class _QuestionInboxCard extends StatefulWidget {
  const _QuestionInboxCard({
    required this.item,
    required this.question,
    required this.chatLabel,
    super.key,
  });

  final ChatAttention item;
  final UserQuestion question;
  final String chatLabel;

  @override
  State<_QuestionInboxCard> createState() => _QuestionInboxCardState();
}

class _QuestionInboxCardState extends State<_QuestionInboxCard> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _answer() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final sent = await context.read<ChatListCubit>().answer(
      widget.question.id,
      text,
    );
    if (sent && mounted) _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ActionCard(
      title: l10n.inboxQuestionTitle,
      icon: Icons.help_outline,
      tone: AppTone.waiting,
      actions: [
        TextButton(
          onPressed: () => openChat(context, widget.item.chatId),
          child: Text(l10n.inboxOpenChat),
        ),
        FilledButton(onPressed: _answer, child: Text(l10n.inboxAnswer)),
      ],
      children: [
        _ChatLabel(text: widget.chatLabel),
        Text(
          widget.question.text,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        TextField(
          controller: _controller,
          minLines: 2,
          maxLines: 5,
          decoration: InputDecoration(hintText: l10n.inboxAnswerHint),
        ),
      ],
    );
  }
}

class _EditFilesInboxCard extends StatelessWidget {
  const _EditFilesInboxCard({
    required this.item,
    required this.request,
    required this.chatLabel,
  });

  final ChatAttention item;
  final EditFileChangesRequest request;
  final String chatLabel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cubit = context.read<ChatListCubit>();
    final scheme = Theme.of(context).colorScheme;
    final hasFiles = request.files.isNotEmpty;
    final tasks = request.scheduledTasks;
    final fileLines = [
      for (final file in request.files)
        '${_editFileKindLabel(l10n, file.kind)}  ${file.path}',
    ].join('\n');
    return ActionCard(
      title: hasFiles
          ? l10n.editFileChangesTitle
          : l10n.historyRewindTasksTitle,
      icon: hasFiles ? Icons.edit_note_outlined : Icons.schedule_outlined,
      tone: AppTone.warning,
      actions: [
        TextButton(
          onPressed: () => openChat(context, item.chatId),
          child: Text(l10n.inboxOpenChat),
        ),
        TextButton(
          onPressed: () => cubit.resolveEditChanges(
            request.id,
            EditFileChangesChoice.cancel,
          ),
          child: Text(l10n.commonCancel),
        ),
        if (hasFiles) ...[
          TextButton(
            onPressed: () => cubit.resolveEditChanges(
              request.id,
              EditFileChangesChoice.continueWithoutRollback,
            ),
            child: Text(l10n.editFileChangesKeep),
          ),
          FilledButton(
            onPressed: () => cubit.resolveEditChanges(
              request.id,
              EditFileChangesChoice.rollbackAndContinue,
            ),
            child: Text(l10n.editFileChangesRestore),
          ),
        ] else
          FilledButton(
            onPressed: () => cubit.resolveEditChanges(
              request.id,
              EditFileChangesChoice.continueWithoutRollback,
            ),
            child: Text(l10n.historyRewindTasksContinue),
          ),
      ],
      children: [
        _ChatLabel(text: chatLabel),
        Text(
          hasFiles
              ? l10n.editFileChangesBody
              : l10n.historyRewindTasksBody(tasks),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        if (hasFiles && tasks > 0)
          Text(
            l10n.historyRewindTasksWarning(tasks),
            style: TextStyle(color: scheme.error, fontSize: 12),
          ),
        if (request.shellMayHaveChangedFiles)
          Text(
            l10n.editFileChangesShellWarning,
            style: TextStyle(color: scheme.error, fontSize: 12),
          ),
        if (fileLines.isNotEmpty) CodeBlock(text: fileLines, maxHeight: 160),
      ],
    );
  }
}

class _ProblemInboxCard extends StatelessWidget {
  const _ProblemInboxCard({required this.item, required this.host});

  final ChatAttention item;
  final Host? host;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cubit = context.read<ChatListCubit>();
    final reason = item.reasons.firstWhere(
      (reason) => reason.problem,
      orElse: () => ChatAttentionReason.failed,
    );
    final title = switch (reason) {
      ChatAttentionReason.stepLimit => l10n.notifyStepLimitTitle,
      ChatAttentionReason.budget => l10n.notifyBudgetTitle,
      ChatAttentionReason.stalled => l10n.notifyStalledTitle,
      _ => l10n.inboxProblemFailedTitle,
    };
    final message = switch (reason) {
      ChatAttentionReason.stepLimit => l10n.stepLimitReached,
      ChatAttentionReason.budget => l10n.turnBudgetReached,
      ChatAttentionReason.stalled => l10n.progressStalled,
      _ => l10n.inboxProblemFailedBody,
    };
    final canContinue = reason != ChatAttentionReason.failed;
    final label = _InboxBody._chatLabel(
      item,
      host,
      AppLocalizations.of(context),
    );
    return ActionCard(
      title: title,
      icon: Icons.error_outline,
      tone: AppTone.danger,
      actions: [
        TextButton(
          onPressed: () => openChat(context, item.chatId),
          child: Text(l10n.inboxOpenChat),
        ),
        TextButton(
          onPressed: () => cubit.dismissAttention(item.chatId),
          child: Text(l10n.inboxDismiss),
        ),
        if (canContinue)
          FilledButton(
            onPressed: () => cubit.continueTurn(item.chatId),
            child: Text(l10n.inboxContinue),
          ),
      ],
      children: [
        _ChatLabel(text: label),
        Text(message, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }
}

class _UnreadInboxCard extends StatelessWidget {
  const _UnreadInboxCard({required this.item, required this.chatLabel});

  final ChatAttention item;
  final String chatLabel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cubit = context.read<ChatListCubit>();
    return ActionCard(
      title: l10n.inboxUnreadTitle(item.unreadCount),
      icon: Icons.mark_chat_unread_outlined,
      tone: AppTone.info,
      actions: [
        TextButton(
          onPressed: () => openChat(context, item.chatId),
          child: Text(l10n.inboxOpenChat),
        ),
        FilledButton(
          onPressed: () => cubit.markAttentionRead(item),
          child: Text(l10n.inboxMarkRead),
        ),
      ],
      children: [
        _ChatLabel(text: chatLabel),
        Text(
          l10n.inboxUnreadBody,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }
}

/// Подпись чата в карточке. Отдельный виджет, чтобы все карточки выглядели
/// одинаково и не дублировали стиль.
class _ChatLabel extends StatelessWidget {
  const _ChatLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(context).textTheme.titleSmall
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
  );
}

String _editFileKindLabel(AppLocalizations l10n, TurnFileKind kind) =>
    switch (kind) {
      TurnFileKind.created => l10n.editFileChangesKindCreated,
      TurnFileKind.modified => l10n.editFileChangesKindModified,
      TurnFileKind.deleted => l10n.editFileChangesKindDeleted,
    };

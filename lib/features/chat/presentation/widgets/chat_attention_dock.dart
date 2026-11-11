import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/interaction/edit_file_changes_request.dart';
import 'package:probably_works/agent/interaction/interaction_broker.dart';
import 'package:probably_works/agent/turn/turn_file_kind.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/util/text_clip.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_column.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Док над композером: всё, что требует решения пользователя, и ошибки.
///
/// Подтверждения и вопросы живут здесь, а не в ленте: при прокрутке вверх агент не может
/// ждать ответа незаметно. Док пуст, когда решений не нужно, и не занимает место. Карточки
/// появляются, уходят и сдвигают соседей плавно: см. [_DockList].
class ChatAttentionDock extends StatelessWidget {
  const ChatAttentionDock({required this.state, super.key});

  final ChatState state;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final items = <_DockItem>[
      if (state.failure != null && !state.failureIsModelMissing)
        _DockItem(
          'failure',
          AppBanner(
            message: l10n.commonError(
              TextClip.headTail(state.failure!, maxChars: 400),
            ),
            icon: Icons.error_outline,
            tone: AppTone.danger,
          ),
        ),
      if (state.modelUnavailable || state.failureIsModelMissing)
        _DockItem(
          'model-unavailable',
          AppBanner(
            message: l10n.chatModelUnavailableBanner(
              state.catalog.nameOf(state.effectiveModelId ?? ''),
            ),
            icon: Icons.warning_amber_outlined,
            tone: AppTone.warning,
          ),
        ),
      if (state.trustNeeded)
        _DockItem(
          'trust',
          AppBanner(
            title: l10n.trustTitle,
            message: l10n.trustBody,
            icon: Icons.shield_outlined,
            tone: AppTone.warning,
            action: FilledButton(
              onPressed: () =>
                  context.read<ChatBloc>().add(const ChatWorkspaceTrusted()),
              child: Text(l10n.trustAction),
            ),
          ),
        ),
      if (state.stepLimitReached)
        _DockItem(
          'step-limit',
          AppBanner(
            message: l10n.stepLimitReached,
            icon: Icons.pause_circle_outline,
            tone: AppTone.warning,
            action: FilledButton(
              onPressed: () =>
                  context.read<ChatBloc>().add(const ChatContinued()),
              child: Text(l10n.stepLimitContinue),
            ),
          ),
        ),
      if (state.approvals.length > 1)
        _DockItem(
          'approvals-bulk',
          AppBanner(
            message: l10n.approvalBulkCount(state.approvals.length),
            icon: Icons.lock_clock_outlined,
            tone: AppTone.waiting,
            action: FilledButton(
              onPressed: () => _approveAll(context, state.approvals),
              child: Text(l10n.approvalAllowAllOnce),
            ),
          ),
        ),
      for (final approval in state.approvals)
        _DockItem('approval:${approval.id}', _ApprovalCard(request: approval)),
      for (final question in state.questions)
        _DockItem('question:${question.id}', _QuestionCard(question: question)),
      for (final request in state.editFileChanges)
        _DockItem(
          'edit-files:${request.id}',
          _EditFileChangesCard(request: request),
        ),
      if (state.queue.isNotEmpty)
        _DockItem('queue', _QueueCard(items: state.queue)),
    ];
    return ChatColumn.fixed(
      context,
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 320),
        child: SingleChildScrollView(child: _DockList(items: items)),
      ),
    );
  }

  /// Массовое подтверждение безопасно: каждое действие всё равно разрешается
  /// ровно один раз, без шаблона и без общего разрешения на инструмент.
  void _approveAll(BuildContext context, List<ApprovalRequest> approvals) {
    final bloc = context.read<ChatBloc>();
    for (final approval in approvals) {
      bloc.add(
        ChatApprovalAnswered(approval.id, const ApprovalDecision.allowOnce()),
      );
    }
  }
}

/// Элемент дока с идентификатором: по нему список понимает, что карточка новая, а что ушла.
class _DockItem {
  const _DockItem(this.id, this.child);

  final String id;
  final Widget child;
}

/// Список карточек дока. Новая карточка выезжает по высоте и проявляется, ушедшая сворачивается
/// и гаснет, соседи плавно смещаются. Элементы идентифицируются по id, поэтому состояние
/// карточек (например, поле ответа на вопрос) сохраняется при перестройке.
class _DockList extends StatefulWidget {
  const _DockList({required this.items});

  final List<_DockItem> items;

  @override
  State<_DockList> createState() => _DockListState();
}

class _DockListState extends State<_DockList> with TickerProviderStateMixin {
  final _entries = <_DockEntry>[];

  @override
  void initState() {
    super.initState();
    for (final item in widget.items) {
      final entry = _DockEntry(item.id, item.child, this)..controller.value = 1;
      _entries.add(entry);
      _track(entry);
    }
  }

  @override
  void didUpdateWidget(covariant _DockList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final incoming = {for (final item in widget.items) item.id: item};
    for (final entry in _entries) {
      final item = incoming[entry.id];
      if (item == null) {
        if (!entry.leaving) {
          entry.leaving = true;
          entry.controller.reverse();
        }
        continue;
      }
      // Свежий child нужен всегда: в нём актуальные данные карточки.
      entry.child = item.child;
      if (entry.leaving) {
        entry.leaving = false;
        entry.controller.forward();
      }
    }
    for (var i = 0; i < widget.items.length; i++) {
      final item = widget.items[i];
      if (_entries.any((e) => e.id == item.id)) continue;
      final entry = _DockEntry(item.id, item.child, this)..controller.forward();
      _entries.insert(i < _entries.length ? i : _entries.length, entry);
      _track(entry);
    }
  }

  /// Убирает карточку, когда она полностью свернулась. Контроллер освобождаем после кадра,
  /// чтобы не освободить его во время собственного уведомления.
  void _track(_DockEntry entry) {
    entry.controller.addStatusListener((status) {
      if (status != AnimationStatus.dismissed || !entry.leaving) return;
      if (!mounted) return;
      setState(() => _entries.remove(entry));
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => entry.controller.dispose(),
      );
    });
  }

  @override
  void dispose() {
    for (final entry in _entries) {
      entry.controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final entry in _entries)
        KeyedSubtree(
          key: ValueKey(entry.id),
          child: SizeTransition(
            sizeFactor: entry.animation,
            alignment: Alignment.topCenter,
            child: FadeTransition(
              opacity: entry.animation,
              child: Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: entry.child,
              ),
            ),
          ),
        ),
    ],
  );
}

/// Состояние одной карточки списка: контроллер появления и ухода и признак ухода.
class _DockEntry {
  _DockEntry(this.id, this.child, TickerProvider vsync)
    : controller = AnimationController(
        vsync: vsync,
        duration: AppDurations.fast,
      ) {
    animation = CurvedAnimation(
      parent: controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
  }

  final String id;
  Widget child;
  final AnimationController controller;
  late final Animation<double> animation;
  var leaving = false;
}

class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({required this.request});

  final ApprovalRequest request;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final bloc = context.read<ChatBloc>();
    final diff = request.diff;
    return ActionCard(
      title: l10n.approvalTitle,
      icon: Icons.lock_clock_outlined,
      tone: AppTone.waiting,
      actions: [
        TextButton(
          onPressed: () => _deny(context, bloc, request),
          child: Text(l10n.approvalDeny),
        ),
        if (request.grantable) ...[
          TextButton(
            onPressed: () => bloc.add(
              ChatApprovalAnswered(
                request.id,
                const ApprovalDecision.allowTurn(),
              ),
            ),
            child: Text(l10n.approvalAllowTurn),
          ),
          TextButton(
            onPressed: () => bloc.add(
              ChatApprovalAnswered(
                request.id,
                const ApprovalDecision.allowChat(),
              ),
            ),
            child: Text(l10n.approvalAllowChat),
          ),
        ],
        FilledButton(
          onPressed: () => bloc.add(
            ChatApprovalAnswered(
              request.id,
              const ApprovalDecision.allowOnce(),
            ),
          ),
          child: Text(l10n.approvalApprove),
        ),
      ],
      children: [
        Text(request.reason, style: Theme.of(context).textTheme.bodyMedium),
        CodeBlock(text: request.summary, maxHeight: 160),
        if (diff != null && diff.isNotEmpty) DiffView(diff: diff),
      ],
    );
  }

  Future<void> _deny(
    BuildContext context,
    ChatBloc bloc,
    ApprovalRequest request,
  ) async {
    final l10n = AppLocalizations.of(context);
    final reason = await ConfirmDialog.prompt(
      context,
      title: l10n.approvalDenyReasonTitle,
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.approvalDeny,
      hint: l10n.approvalDenyReasonHint,
      minLines: 2,
      maxLines: 4,
    );
    if (reason == null) return;
    final text = reason.trim();
    bloc.add(
      ChatApprovalAnswered(
        request.id,
        ApprovalDecision.deny(reason: text.isEmpty ? null : text),
      ),
    );
  }
}

String _editFileKindLabel(AppLocalizations l10n, TurnFileKind kind) =>
    switch (kind) {
      TurnFileKind.created => l10n.editFileChangesKindCreated,
      TurnFileKind.modified => l10n.editFileChangesKindModified,
      TurnFileKind.deleted => l10n.editFileChangesKindDeleted,
    };

class _EditFileChangesCard extends StatelessWidget {
  const _EditFileChangesCard({required this.request});

  final EditFileChangesRequest request;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final bloc = context.read<ChatBloc>();
    final scheme = Theme.of(context).colorScheme;
    final fileLines = [
      for (final file in request.files)
        '${_editFileKindLabel(l10n, file.kind)}  ${file.path}',
    ].join('\n');
    return ActionCard(
      title: l10n.editFileChangesTitle,
      icon: Icons.edit_note_outlined,
      tone: AppTone.warning,
      actions: [
        TextButton(
          onPressed: () => bloc.add(
            ChatEditFileChangesAnswered(
              request.id,
              EditFileChangesChoice.cancel,
            ),
          ),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          onPressed: () => bloc.add(
            ChatEditFileChangesAnswered(
              request.id,
              EditFileChangesChoice.continueWithoutRollback,
            ),
          ),
          child: Text(l10n.editFileChangesKeep),
        ),
        FilledButton(
          onPressed: () => bloc.add(
            ChatEditFileChangesAnswered(
              request.id,
              EditFileChangesChoice.rollbackAndContinue,
            ),
          ),
          child: Text(l10n.editFileChangesRestore),
        ),
      ],
      children: [
        Text(
          l10n.editFileChangesBody,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        if (request.shellMayHaveChangedFiles)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: Text(
              l10n.editFileChangesShellWarning,
              style: TextStyle(color: scheme.error, fontSize: 12),
            ),
          ),
        if (fileLines.isNotEmpty) CodeBlock(text: fileLines, maxHeight: 160),
      ],
    );
  }
}

class _QuestionCard extends StatefulWidget {
  const _QuestionCard({required this.question});

  final UserQuestion question;

  @override
  State<_QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<_QuestionCard> {
  final _answer = TextEditingController();

  @override
  void dispose() {
    _answer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ActionCard(
      title: l10n.questionTitle,
      icon: Icons.help_outline,
      tone: AppTone.waiting,
      actions: [
        FilledButton(onPressed: _submit, child: Text(l10n.questionSubmit)),
      ],
      children: [
        Text(
          widget.question.text,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        AppTextField(
          controller: _answer,
          hint: l10n.questionAnswerHint,
          autofocus: true,
          onSubmitted: (_) => _submit(),
        ),
      ],
    );
  }

  void _submit() {
    final text = _answer.text.trim();
    if (text.isEmpty) return;
    context.read<ChatBloc>().add(
      ChatQuestionAnswered(widget.question.id, text),
    );
  }
}

class _QueueCard extends StatelessWidget {
  const _QueueCard({required this.items});

  final List<String> items;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final bloc = context.read<ChatBloc>();
    // Строка очереди идентифицируется текстом и номером повтора: удаление из середины не перезапускает соседей.
    final seen = <String, int>{};
    final rows = <_DockItem>[
      for (var i = 0; i < items.length; i++)
        _DockItem(
          '${items[i]}#${seen.update(items[i], (n) => n + 1, ifAbsent: () => 0)}',
          Row(
            children: [
              Expanded(
                child: Text(
                  items[i],
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: l10n.queueSendNow,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.bolt, size: 18),
                onPressed: () => bloc.add(ChatQueueSendNow(i)),
              ),
              IconButton(
                tooltip: l10n.queueEdit,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.edit_outlined, size: 18),
                onPressed: () => bloc.add(ChatQueueEdited(i)),
              ),
              IconButton(
                tooltip: l10n.queueRemove,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => bloc.add(ChatQueueRemoved(i)),
              ),
            ],
          ),
        ),
    ];
    return ActionCard(
      title: l10n.queueTitle(items.length),
      icon: Icons.queue_outlined,
      tone: AppTone.info,
      children: [_DockList(items: rows)],
    );
  }
}

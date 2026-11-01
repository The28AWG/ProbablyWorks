import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/interaction/interaction_broker.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Лента чата: сообщения, карточки инструментов, approve, вопросы и очередь.
class ChatTimeline extends StatelessWidget {
  const ChatTimeline({required this.state, super.key});

  final ChatState state;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final visible = [
      for (final m in state.messages)
        if (m.role != MessageRole.tool) m,
    ];
    final runsByMessage = <String, List<ToolRun>>{};
    for (final run in state.runs) {
      runsByMessage.putIfAbsent(run.messageId, () => []).add(run);
    }
    if (visible.isEmpty && !state.isRunning) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(l10n.chatEmptyState, textAlign: TextAlign.center),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        for (final message in visible) ...[
          _MessageItem(message: message, state: state),
          for (final run in runsByMessage[message.id] ?? const <ToolRun>[])
            _RunCard(run: run, live: state.live[run.id]),
        ],
        if (state.streamText.isNotEmpty)
          _StreamingBubble(text: state.streamText),
        for (final approval in state.approvals)
          _ApprovalCard(request: approval),
        for (final question in state.questions)
          _QuestionCard(question: question),
        if (state.queue.isNotEmpty) _QueueCard(items: state.queue),
        if (state.stepLimitReached)
          Card(
            child: ListTile(
              leading: const Icon(Icons.pause_circle_outline),
              title: Text(l10n.stepLimitReached),
              trailing: FilledButton(
                onPressed: () =>
                    context.read<ChatBloc>().add(const ChatContinued()),
                child: Text(l10n.stepLimitContinue),
              ),
            ),
          ),
        if (state.isRunning && state.streamText.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(),
          ),
      ],
    );
  }
}

class _MessageItem extends StatelessWidget {
  const _MessageItem({required this.message, required this.state});

  final ChatMessage message;
  final ChatState state;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    switch (message.role) {
      case MessageRole.user:
        return Align(
          alignment: Alignment.centerRight,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Card(
              color: scheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: SelectableText(message.text)),
                    if (!state.isRunning)
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.more_horiz, size: 18),
                        onSelected: (action) =>
                            _onAction(context, action, l10n),
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'edit',
                            child: Text(l10n.messageEdit),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Text(l10n.messageDeleteAfter),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      case MessageRole.assistant:
        if (message.text.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: MarkdownBlock(data: message.text),
        );
      case MessageRole.event:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            message.text,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(fontStyle: FontStyle.italic),
          ),
        );
      case MessageRole.tool:
        return const SizedBox.shrink();
    }
  }

  Future<void> _onAction(
    BuildContext context,
    String action,
    AppLocalizations l10n,
  ) async {
    final bloc = context.read<ChatBloc>();
    if (action == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          content: Text(l10n.messageDeleteAfterConfirm),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(l10n.commonDelete),
            ),
          ],
        ),
      );
      if (ok == true) bloc.add(ChatDeletedAfter(message.id));
      return;
    }
    if (!context.mounted) return;
    final controller = TextEditingController(text: message.text);
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: TextField(
          controller: controller,
          minLines: 2,
          maxLines: 10,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: Text(l10n.messageEdit),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text != null && text.trim().isNotEmpty) {
      bloc.add(ChatMessageEdited(message.id, text));
    }
  }
}

class _StreamingBubble extends StatelessWidget {
  const _StreamingBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: MarkdownBlock(data: text),
  );
}

class _RunCard extends StatelessWidget {
  const _RunCard({required this.run, this.live});

  final ToolRun run;
  final String? live;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final output = live ?? run.outputText ?? '';
    final active =
        run.isActive || run.status == ToolRunStatus.backgroundRunning;
    final finishedAt = run.finishedAt;
    final meta = [
      if (run.pid != null) l10n.runPid(run.pid!),
      if (finishedAt != null)
        l10n.runDuration(finishedAt.difference(run.startedAt).inSeconds),
    ];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(_icon(run), size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    run.command ?? run.toolName,
                    style: const TextStyle(fontFamily: 'monospace'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (run.background)
                  Chip(
                    label: Text(l10n.runBackgroundBadge),
                    visualDensity: VisualDensity.compact,
                  ),
                Chip(
                  label: Text(_statusLabel(run.status, l10n)),
                  visualDensity: VisualDensity.compact,
                ),
                if (active && run.status != ToolRunStatus.waitingApproval)
                  IconButton(
                    tooltip: l10n.runStop,
                    icon: const Icon(Icons.stop_circle_outlined),
                    onPressed: () => context.read<ChatBloc>().add(
                      ChatRunStopRequested(run.id),
                    ),
                  ),
              ],
            ),
            if (meta.isNotEmpty)
              Text(
                meta.join(' · '),
                style: Theme.of(context).textTheme.labelSmall,
              ),
            if (output.isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(
                constraints: const BoxConstraints(maxHeight: 220),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  reverse: true,
                  child: SelectableText(
                    output,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ],
            if (run.outputTruncated)
              Text(
                l10n.runOutputTruncated,
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }

  IconData _icon(ToolRun run) => switch (run.status) {
    ToolRunStatus.waitingApproval => Icons.lock_clock_outlined,
    ToolRunStatus.denied => Icons.block,
    ToolRunStatus.done => Icons.check_circle_outline,
    ToolRunStatus.failed ||
    ToolRunStatus.spawnFailed ||
    ToolRunStatus.connectionLost => Icons.error_outline,
    _ => Icons.terminal,
  };

  String _statusLabel(ToolRunStatus status, AppLocalizations l10n) =>
      switch (status) {
        ToolRunStatus.running => l10n.runStatusRunning,
        ToolRunStatus.backgroundRunning => l10n.runStatusBackground,
        ToolRunStatus.done => l10n.runStatusDone,
        ToolRunStatus.failed => l10n.runStatusFailed,
        ToolRunStatus.timedOut => l10n.runStatusTimedOut,
        ToolRunStatus.interrupted => l10n.runStatusInterrupted,
        ToolRunStatus.denied => l10n.runStatusDenied,
        ToolRunStatus.connectionLost => l10n.runStatusConnectionLost,
        ToolRunStatus.spawnFailed => l10n.runStatusSpawnFailed,
        ToolRunStatus.waitingApproval => l10n.runStatusWaitingApproval,
        ToolRunStatus.waitingUser => l10n.runStatusWaitingUser,
      };
}

class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({required this.request});

  final ApprovalRequest request;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Card(
      color: Theme.of(context).colorScheme.tertiaryContainer,
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.approvalTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(request.reason, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 6),
            SelectableText(
              request.summary,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            if (request.diff != null && request.diff!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(
                constraints: const BoxConstraints(maxHeight: 260),
                padding: const EdgeInsets.all(8),
                color: Theme.of(context).colorScheme.surface,
                child: SingleChildScrollView(
                  child: SelectableText(
                    request.diff!,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => context.read<ChatBloc>().add(
                    ChatApprovalAnswered(request.id, allow: false),
                  ),
                  child: Text(l10n.approvalDeny),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => context.read<ChatBloc>().add(
                    ChatApprovalAnswered(request.id, allow: true),
                  ),
                  child: Text(l10n.approvalApprove),
                ),
              ],
            ),
          ],
        ),
      ),
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
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.questionTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(widget.question.text),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _answer,
                    decoration: InputDecoration(
                      labelText: l10n.questionAnswerHint,
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _submit,
                  child: Text(l10n.questionSubmit),
                ),
              ],
            ),
          ],
        ),
      ),
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
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.queueTitle(items.length),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            for (var i = 0; i < items.length; i++)
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
                    icon: const Icon(Icons.bolt),
                    onPressed: () => bloc.add(ChatQueueSendNow(i)),
                  ),
                  IconButton(
                    tooltip: l10n.queueEdit,
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => bloc.add(ChatQueueEdited(i)),
                  ),
                  IconButton(
                    tooltip: l10n.queueRemove,
                    icon: const Icon(Icons.close),
                    onPressed: () => bloc.add(ChatQueueRemoved(i)),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

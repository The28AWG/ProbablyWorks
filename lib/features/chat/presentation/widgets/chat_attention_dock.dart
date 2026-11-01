import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/interaction/interaction_broker.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/util/text_clip.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_column.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Док над композером: всё, что требует решения пользователя, и ошибки.
///
/// Подтверждения и вопросы живут здесь, а не в ленте: при прокрутке вверх агент не может
/// ждать ответа незаметно. Док пуст, когда решений не нужно, и не занимает место.
class ChatAttentionDock extends StatelessWidget {
  const ChatAttentionDock({required this.state, super.key});

  final ChatState state;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final items = <Widget>[
      if (state.failure != null)
        AppBanner(
          message: l10n.commonError(
            TextClip.headTail(state.failure!, maxChars: 400),
          ),
          icon: Icons.error_outline,
          tone: AppTone.danger,
        ),
      if (state.trustNeeded)
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
      if (state.stepLimitReached)
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
      for (final approval in state.approvals) _ApprovalCard(request: approval),
      for (final question in state.questions) _QuestionCard(question: question),
      if (state.queue.isNotEmpty) _QueueCard(items: state.queue),
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: ChatColumn.fixed(
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const SizedBox(height: AppSpacing.sm),
                  items[i],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
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
          onPressed: () =>
              bloc.add(ChatApprovalAnswered(request.id, allow: false)),
          child: Text(l10n.approvalDeny),
        ),
        FilledButton(
          onPressed: () =>
              bloc.add(ChatApprovalAnswered(request.id, allow: true)),
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
    return ActionCard(
      title: l10n.queueTitle(items.length),
      icon: Icons.queue_outlined,
      tone: AppTone.info,
      children: [
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
      ],
    );
  }
}

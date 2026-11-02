import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/util/char_substring.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Сообщение в ленте. Пользователь — нейтральный пузырь справа, ассистент — текст на всю колонку,
/// служебные события — одна приглушённая строка. Действия сообщения пользователя видны при наведении
/// и при фокусе с клавиатуры. У ответа агента кнопка «Копировать» есть только у последнего ответа.
class ChatMessageTile extends StatelessWidget {
  const ChatMessageTile({
    required this.message,
    required this.editable,
    this.isLastAnswer = false,
    super.key,
  });

  final ChatMessage message;

  /// Правка и удаление недоступны, пока агент работает: история меняется только между шагами.
  final bool editable;

  /// Ответ агента — последний в ленте: только у него есть кнопка «Копировать».
  final bool isLastAnswer;

  @override
  Widget build(BuildContext context) => switch (message.role) {
    MessageRole.user => _UserMessage(message: message, editable: editable),
    MessageRole.assistant => _AssistantMessage(
      message: message,
      isLastAnswer: isLastAnswer,
    ),
    MessageRole.event => _EventLine(text: message.text),
    MessageRole.tool => const SizedBox.shrink(),
  };
}

/// Длинное сообщение пользователя сокращается до превью: выделяемый текст раскладывается целиком,
/// и один огромный абзац (лог, вставленный из буфера) стоит десятков миллисекунд на кадр.
const _previewChars = 2000;

class _UserMessage extends StatefulWidget {
  const _UserMessage({required this.message, required this.editable});

  final ChatMessage message;
  final bool editable;

  @override
  State<_UserMessage> createState() => _UserMessageState();
}

class _UserMessageState extends State<_UserMessage> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final editable = widget.editable;
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final preview = charPrefix(message.text, _previewChars);
    final long = preview.length < message.text.length;
    final shown = long && !_expanded ? '$preview…' : message.text;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Align(
        alignment: AlignmentDirectional.centerEnd,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: _HoverActions(
            crossAxisAlignment: CrossAxisAlignment.end,
            actions: [
              _ActionIcon(
                tooltip: l10n.commonCopy,
                icon: Icons.copy_outlined,
                onPressed: () => _copy(context, message.text, l10n),
              ),
              if (editable) ...[
                _ActionIcon(
                  tooltip: l10n.messageEdit,
                  icon: Icons.edit_outlined,
                  onPressed: () => _edit(context, l10n),
                ),
                _ActionIcon(
                  tooltip: l10n.messageDeleteAfter,
                  icon: Icons.delete_outline,
                  onPressed: () => _deleteAfter(context, l10n),
                ),
              ],
            ],
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: AppRadius.lgAll,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.md,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SelectableText(
                      shown,
                      style: Theme.of(context).textTheme.bodyLarge
                          ?.copyWith(color: scheme.onSurface),
                    ),
                    if (long)
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton(
                          onPressed: () =>
                              setState(() => _expanded = !_expanded),
                          child: Text(
                            _expanded
                                ? l10n.messageCollapse
                                : l10n.messageShowFull,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _edit(BuildContext context, AppLocalizations l10n) async {
    final bloc = context.read<ChatBloc>();
    final text = await ConfirmDialog.prompt(
      context,
      title: l10n.messageEdit,
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.messageEdit,
      initialText: widget.message.text,
      minLines: 2,
      maxLines: 10,
    );
    if (text != null && text.trim().isNotEmpty) {
      bloc.add(ChatMessageEdited(widget.message.id, text));
    }
  }

  Future<void> _deleteAfter(BuildContext context, AppLocalizations l10n) async {
    final bloc = context.read<ChatBloc>();
    final ok = await ConfirmDialog.confirm(
      context,
      title: l10n.messageDeleteAfter,
      message: l10n.messageDeleteAfterConfirm,
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.commonDelete,
      destructive: true,
    );
    if (ok) bloc.add(ChatDeletedAfter(widget.message.id));
  }
}

class _AssistantMessage extends StatelessWidget {
  const _AssistantMessage({required this.message, required this.isLastAnswer});

  final ChatMessage message;
  final bool isLastAnswer;

  @override
  Widget build(BuildContext context) {
    // Текст из одних пробелов и переводов строк тоже пустой: иначе останется пустой блок с кнопкой.
    if (message.text.trim().isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AppMarkdown(data: message.text),
          // Строка с кнопкой занимает место только у последнего ответа. Появление и уход плавные.
          AnimatedSize(
            duration: AppDurations.fast,
            alignment: Alignment.topLeft,
            child: AnimatedSwitcher(
              duration: AppDurations.fast,
              transitionBuilder: (child, animation) =>
                  FadeTransition(opacity: animation, child: child),
              child: isLastAnswer
                  ? Padding(
                      key: const ValueKey('copy'),
                      padding: const EdgeInsets.only(top: AppSpacing.xs),
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: _ActionIcon(
                          tooltip: l10n.commonCopy,
                          icon: Icons.copy_outlined,
                          onPressed: () => _copy(context, message.text, l10n),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(key: ValueKey('none')),
            ),
          ),
        ],
      ),
    );
  }
}

class _EventLine extends StatelessWidget {
  const _EventLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.subdirectory_arrow_right,
            size: 14,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Метка в ленте над сообщениями, которые модель видит только через сводку.
/// Сводку можно раскрыть, чтобы понимать, что именно помнит агент.
class ChatCompactionMarker extends StatefulWidget {
  const ChatCompactionMarker({required this.summary, super.key});

  final String? summary;

  @override
  State<ChatCompactionMarker> createState() => _ChatCompactionMarkerState();
}

class _ChatCompactionMarkerState extends State<ChatCompactionMarker> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final summary = widget.summary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(child: Divider(color: scheme.outlineVariant)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.compress,
                      size: 14,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Text(
                      l10n.compactionMarker,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (summary != null && summary.isNotEmpty)
                      TextButton(
                        onPressed: () => setState(() => _open = !_open),
                        child: Text(
                          _open
                              ? l10n.compactionHideSummary
                              : l10n.compactionShowSummary,
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(child: Divider(color: scheme.outlineVariant)),
            ],
          ),
          if (_open && summary != null && summary.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: AppRadius.mdAll,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: AppMarkdown(data: summary),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Строка действий под сообщением. Видна при наведении мыши или фокусе внутри строки.
/// Действия над сообщением появляются при наведении мыши или фокусе с клавиатуры.
/// Зона реакции — всё сообщение, поэтому кнопки не «прыгают» при движении к ним.
class _HoverActions extends StatefulWidget {
  const _HoverActions({
    required this.child,
    required this.actions,
    required this.crossAxisAlignment,
  });

  final Widget child;
  final List<Widget> actions;
  final CrossAxisAlignment crossAxisAlignment;

  @override
  State<_HoverActions> createState() => _HoverActionsState();
}

class _HoverActionsState extends State<_HoverActions> {
  var _hovered = false;
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final visible = _hovered || _focused;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (focused) => setState(() => _focused = focused),
        child: Column(
          crossAxisAlignment: widget.crossAxisAlignment,
          mainAxisSize: MainAxisSize.min,
          children: [
            widget.child,
            IgnorePointer(
              ignoring: !visible,
              child: AnimatedOpacity(
                opacity: visible ? 1 : 0,
                duration: AppDurations.fast,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: widget.actions,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionIcon extends StatelessWidget {
  const _ActionIcon({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    visualDensity: VisualDensity.compact,
    iconSize: 18,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
    icon: Icon(icon),
    onPressed: onPressed,
  );
}

Future<void> _copy(
  BuildContext context,
  String text,
  AppLocalizations l10n,
) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) AppSnackBar.show(context, l10n.messageCopied);
}

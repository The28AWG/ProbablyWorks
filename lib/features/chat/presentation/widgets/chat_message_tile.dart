import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/core/util/char_substring.dart';
import 'package:pw_agent/core/util/elapsed_format.dart';

/// Сообщение в ленте. Пользователь — нейтральный пузырь справа, ассистент — текст на всю колонку,
/// служебные события — одна приглушённая строка. Копирование и правка видны при наведении и при
/// фокусе с клавиатуры. Нажатие по тексту пузыря тоже открывает правку: лента подменяет его
/// композером. Неотправленная правка остаётся в пузыре и окрашивает его, пока сообщение не отправят.
/// У ответа агента кнопка «Копировать» есть у сообщения, которым закрыт его ход.
class ChatMessageTile extends StatelessWidget {
  const ChatMessageTile({
    required this.message,
    required this.editable,
    this.onEdit,
    this.editText,
    this.isLastAnswer = false,
    this.turnElapsed,
    this.onRegenerate,
    this.onFork,
    super.key,
  });

  final ChatMessage message;

  /// Правка недоступна, пока агент работает: история меняется только между шагами.
  final bool editable;

  /// Открывает правку на месте. Null — ни нажатие по пузырю, ни кнопка «Изменить» правку не начинают.
  final VoidCallback? onEdit;

  /// Текст несохранённой правки. Null — пузырь показывает [ChatMessage.text] обычным цветом.
  /// Пустая строка тоже видна: пользователь мог стереть сообщение и свернуть правку.
  final String? editText;

  /// Закрывающее сообщение законченного хода: у него есть кнопка «Копировать».
  final bool isLastAnswer;

  /// Время всего задания (от сообщения пользователя до конца его хода). Задаётся у финального ответа
  /// законченного задания; у ответа без времени — `null`.
  final Duration? turnElapsed;

  /// Перезапускает последний ход без изменения текста сообщения. Null — действие недоступно.
  final VoidCallback? onRegenerate;

  /// Создаёт новый чат с историей до этого ответа включительно.
  final VoidCallback? onFork;

  @override
  Widget build(BuildContext context) => switch (message.role) {
    MessageRole.user => _UserMessage(
      message: message,
      editable: editable,
      onEdit: onEdit,
      editText: editText,
    ),
    MessageRole.assistant => _AssistantMessage(
      message: message,
      isLastAnswer: isLastAnswer,
      elapsed: turnElapsed,
      onRegenerate: onRegenerate,
      onFork: onFork,
    ),
    MessageRole.event => _EventLine(text: message.text),
    MessageRole.tool => const SizedBox.shrink(),
  };
}

/// Длинное сообщение пользователя сокращается до превью: выделяемый текст раскладывается целиком,
/// и один огромный абзац (лог, вставленный из буфера) стоит десятков миллисекунд на кадр.
const _previewChars = 2000;

class _UserMessage extends StatefulWidget {
  const _UserMessage({
    required this.message,
    required this.editable,
    required this.onEdit,
    required this.editText,
  });

  final ChatMessage message;
  final bool editable;
  final VoidCallback? onEdit;
  final String? editText;

  @override
  State<_UserMessage> createState() => _UserMessageState();
}

class _UserMessageState extends State<_UserMessage> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final editable = widget.editable;
    final edit = widget.onEdit;
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final pending = widget.editText;
    final text = pending ?? message.text;
    final preview = charPrefix(text, _previewChars);
    final long = preview.length < text.length;
    final shown = long && !_expanded ? '$preview…' : text;
    final bubble = DecoratedBox(
      decoration: BoxDecoration(
        color: pending == null
            ? scheme.surfaceContainerHigh
            : scheme.primaryContainer,
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
            _EditOnTap(
              onTap: editable ? edit : null,
              child: SelectableText(
                shown,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: pending == null
                      ? scheme.onSurface
                      : scheme.onPrimaryContainer,
                ),
              ),
            ),
            if (long)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  child: Text(
                    _expanded ? l10n.messageCollapse : l10n.messageShowFull,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Align(
        alignment: AlignmentDirectional.centerEnd,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: pending == null
              ? bubble
              : Semantics(hint: l10n.messageEditDraft, child: bubble),
        ),
      ),
    );
  }
}

/// Короткое нажатие по тексту пузыря открывает правку. Сдвиг дальше [kTouchSlop] — это
/// выделение, его не перехватываем. Долгое нажатие обрабатывает строка действий отдельно.
class _EditOnTap extends StatefulWidget {
  const _EditOnTap({required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  State<_EditOnTap> createState() => _EditOnTapState();
}

class _EditOnTapState extends State<_EditOnTap> {
  var _moved = false;
  var _primary = false;
  Offset? _start;
  DateTime? _downAt;

  void _down(PointerDownEvent event) {
    _moved = false;
    // Правая кнопка открывает меню выделения, это не переход в правку.
    _primary =
        event.kind != PointerDeviceKind.mouse ||
        event.buttons == kPrimaryButton;
    _start = event.position;
    _downAt = DateTime.now();
  }

  void _move(PointerMoveEvent event) {
    final start = _start;
    if (start != null && (event.position - start).distance > kTouchSlop) {
      _moved = true;
    }
  }

  void _up(PointerUpEvent _) {
    final start = _start;
    final at = _downAt;
    _start = null;
    _downAt = null;
    if (!_primary || _moved || start == null || at == null) return;
    // Долгое нажатие уже открыло лист действий: вторым шагом правку не начинаем.
    if (DateTime.now().difference(at) >= kLongPressTimeout) return;
    widget.onTap?.call();
  }

  void _cancel(PointerCancelEvent _) {
    _start = null;
    _downAt = null;
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: widget.onTap == null ? null : _down,
    onPointerMove: widget.onTap == null ? null : _move,
    onPointerUp: widget.onTap == null ? null : _up,
    onPointerCancel: widget.onTap == null ? null : _cancel,
    child: widget.child,
  );
}

class _AssistantMessage extends StatelessWidget {
  const _AssistantMessage({
    required this.message,
    required this.isLastAnswer,
    this.elapsed,
    this.onRegenerate,
    this.onFork,
  });

  final ChatMessage message;
  final bool isLastAnswer;

  /// Время всего задания; `null`, если у этого ответа его не показываем.
  final Duration? elapsed;
  final VoidCallback? onRegenerate;
  final VoidCallback? onFork;

  @override
  Widget build(BuildContext context) {
    // Текст из одних пробелов и переводов строк тоже пустой: иначе останется пустой блок с кнопкой.
    if (message.text.trim().isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AppMarkdown(data: message.text),
          // Строка действий занимает место у ответа, которым закрыт ход (кнопка «Копировать»), и у ответа
          // законченного задания (время). Появление и уход плавные.
          AnimatedSize(
            duration: AppDurations.fast,
            alignment: Alignment.topLeft,
            child: AnimatedSwitcher(
              duration: AppDurations.fast,
              transitionBuilder: (child, animation) =>
                  FadeTransition(opacity: animation, child: child),
              child: isLastAnswer || elapsed != null
                  ? Padding(
                      key: const ValueKey('actions'),
                      padding: const EdgeInsets.only(top: AppSpacing.xs),
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (isLastAnswer)
                              _ActionIcon(
                                tooltip: l10n.commonCopy,
                                icon: Icons.copy_outlined,
                                onPressed: () =>
                                    _copy(context, message.text, l10n),
                              ),
                            if (isLastAnswer && onRegenerate != null)
                              _ActionIcon(
                                tooltip: l10n.messageRegenerate,
                                icon: Icons.refresh,
                                onPressed: onRegenerate!,
                              ),
                            if (onFork != null)
                              _ActionIcon(
                                tooltip: l10n.messageFork,
                                icon: Icons.call_split,
                                onPressed: onFork!,
                              ),
                            if (elapsed case final time?) ...[
                              if (isLastAnswer)
                                const SizedBox(width: AppSpacing.xs),
                              Text(
                                formatElapsed(time),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
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
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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

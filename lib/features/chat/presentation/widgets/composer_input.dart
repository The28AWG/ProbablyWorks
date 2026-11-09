import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/core/platform/app_platform.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_density.dart';

/// Поле ввода сообщения. Enter отправляет, Shift+Enter переносит строку,
/// Ctrl/Cmd+Enter во время работы агента ставит сообщение вперёд очереди (sendNow).
/// Enter во время IME-композиции (например, русская раскладка до выбора слова) не перехватывается.
///
/// На десктопе фокус ставится при появлении поля и повторно, когда закончилась загрузка чата (см. [ComposerInput.loading]).
/// На мобильных фокус при открытии не ставится, чтобы не открывать клавиатуру (см. [AppPlatform.focusesInputOnOpen]).
///
/// [maxLines] — сколько строк поле растёт до прокрутки; значение задаёт [ChatDensity.composerMaxLines].
/// Подсказка всегда одна строка и обрезается многоточием: на узком экране она не должна занимать высоту.
class ComposerInput extends StatefulWidget {
  const ComposerInput({
    required this.controller,
    required this.hint,
    required this.busy,
    required this.loading,
    required this.maxLines,
    required this.onSubmit,
    this.onFocus,
    super.key,
  });

  final TextEditingController controller;
  final String hint;
  final bool busy;

  /// Чат загружается, и родитель исключил композер из фокуса ([ExcludeFocus]). Фокус ставим,
  /// когда загрузка закончилась: запрос, сделанный во время исключения, теряется.
  final bool loading;
  final int maxLines;
  final ValueChanged<bool> onSubmit;

  /// Фокус поля сменился. Нижний композер по этому сигналу сворачивает правку сообщения.
  final ValueChanged<bool>? onFocus;

  @override
  State<ComposerInput> createState() => _ComposerInputState();
}

class _ComposerInputState extends State<ComposerInput> {
  // Собственный FocusNode нужен, чтобы перехватить Enter раньше обработчиков EditableText.
  late final _focusNode = FocusNode(onKeyEvent: _onKey);

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_emitFocus);
    if (!widget.loading) _focusAfterFrame();
  }

  @override
  void didUpdateWidget(ComposerInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Смена чата на месте: композер остаётся, но ждёт загрузку, и фокус должен вернуться после неё.
    if (oldWidget.loading && !widget.loading) _focusAfterFrame();
  }

  @override
  void dispose() {
    _focusNode
      ..removeListener(_emitFocus)
      ..dispose();
    super.dispose();
  }

  void _emitFocus() => widget.onFocus?.call(_focusNode.hasFocus);

  /// Фокус после кадра: на момент initState или didUpdateWidget родитель может ещё не снять [ExcludeFocus].
  /// На мобильных фокус не ставим ([AppPlatform.focusesInputOnOpen]): иначе клавиатура открывалась бы при каждом чате.
  void _focusAfterFrame() {
    if (!AppPlatform.current.focusesInputOnOpen) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final isEnter =
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
    if (!isEnter) return KeyEventResult.ignored;
    if (widget.controller.value.composing.isValid) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isShiftPressed) return KeyEventResult.ignored;
    final withModifier = keyboard.isControlPressed || keyboard.isMetaPressed;
    widget.onSubmit(withModifier && widget.busy);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final density = ChatDensityScope.of(context);
    final lineHeight = density.inputLineHeight;
    return TextField(
      controller: widget.controller,
      focusNode: _focusNode,
      minLines: 1,
      maxLines: widget.maxLines,
      // Широкая область берёт стиль поля из темы без изменений.
      style: lineHeight == null
          ? null
          : Theme.of(context).textTheme.bodyLarge?.copyWith(height: lineHeight),
      decoration: InputDecoration(
        hintText: widget.hint,
        hintMaxLines: 1,
        filled: false,
        isDense: true,
        contentPadding: EdgeInsets.symmetric(
          vertical: density.inputVerticalPadding,
        ),
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
      ),
    );
  }
}

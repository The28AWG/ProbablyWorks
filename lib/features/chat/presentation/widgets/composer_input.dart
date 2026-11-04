import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_density.dart';

/// Поле ввода сообщения. Enter отправляет, Shift+Enter переносит строку,
/// Ctrl/Cmd+Enter во время работы агента ставит сообщение вперёд очереди (sendNow).
/// Enter во время IME-композиции (например, русская раскладка до выбора слова) не перехватывается.
///
/// [maxLines] — сколько строк поле растёт до прокрутки; значение задаёт [ChatDensity.composerMaxLines].
/// Подсказка всегда одна строка и обрезается многоточием: на узком экране она не должна занимать высоту.
class ComposerInput extends StatefulWidget {
  const ComposerInput({
    required this.controller,
    required this.hint,
    required this.busy,
    required this.maxLines,
    required this.onSubmit,
    super.key,
  });

  final TextEditingController controller;
  final String hint;
  final bool busy;
  final int maxLines;
  final ValueChanged<bool> onSubmit;

  @override
  State<ComposerInput> createState() => _ComposerInputState();
}

class _ComposerInputState extends State<ComposerInput> {
  // Собственный FocusNode нужен, чтобы перехватить Enter раньше обработчиков EditableText.
  late final _focusNode = FocusNode(onKeyEvent: _onKey);

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
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

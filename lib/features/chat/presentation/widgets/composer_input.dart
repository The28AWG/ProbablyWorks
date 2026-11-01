import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// Поле ввода сообщения. Enter отправляет, Shift+Enter переносит строку,
/// Ctrl/Cmd+Enter во время работы агента ставит сообщение вперёд очереди (sendNow).
/// Enter во время IME-композиции (например, русская раскладка до выбора слова) не перехватывается.
class ComposerInput extends StatefulWidget {
  const ComposerInput({
    required this.controller,
    required this.hint,
    required this.busy,
    required this.onSubmit,
    super.key,
  });

  final TextEditingController controller;
  final String hint;
  final bool busy;
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
  Widget build(BuildContext context) => TextField(
    controller: widget.controller,
    focusNode: _focusNode,
    minLines: 1,
    maxLines: 8,
    decoration: InputDecoration(
      hintText: widget.hint,
      filled: false,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(vertical: 10),
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
    ),
  );
}

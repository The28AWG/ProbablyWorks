import 'package:material_ui/material_ui.dart';

/// Высота видимой области ленты: окно минус заголовок, композер и блок внимания.
/// Блоки, которые раскрываются на всю высоту, не должны выходить за неё: терминал ограничивается этой высотой.
class ChatViewport extends InheritedWidget {
  const ChatViewport({required this.height, required super.child, super.key});

  final double height;

  /// Высота видимой области, или `null`, если блок стоит вне ленты чата.
  static double? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatViewport>()?.height;

  @override
  bool updateShouldNotify(ChatViewport oldWidget) => height != oldWidget.height;
}

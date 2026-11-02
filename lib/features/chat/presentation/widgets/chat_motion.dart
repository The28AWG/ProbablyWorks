import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/theme/app_tokens.dart';

/// Раскрытие содержимого по высоте. Содержимое плавно раскрывается и сворачивается, а не пропадает
/// мгновенно, поэтому соседние элементы не прыгают. Свёрнутое содержимое не монтируется: скрытый текст
/// не попадает в поиск и не перехватывает нажатия. Обрезка снаружи не даёт тексту выйти за высоту.
class ChatReveal extends StatefulWidget {
  const ChatReveal({required this.open, required this.child, super.key});

  final bool open;
  final Widget child;

  @override
  State<ChatReveal> createState() => _ChatRevealState();
}

class _ChatRevealState extends State<ChatReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppDurations.fast,
    value: widget.open ? 1 : 0,
  );

  /// Содержимое, которое уходит: держим его, пока высота не дошла до нуля. Null — закрыто и смонтировано не будет.
  Widget? _leaving;

  @override
  void initState() {
    super.initState();
    if (widget.open) _leaving = widget.child;
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && mounted) {
        setState(() => _leaving = null);
      }
    });
  }

  @override
  void didUpdateWidget(covariant ChatReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.open) {
      _leaving = widget.child;
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRect(
    child: SizeTransition(
      sizeFactor: CurvedAnimation(
        parent: _controller,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      ),
      alignment: Alignment.topCenter,
      child: widget.open ? widget.child : (_leaving ?? const SizedBox.shrink()),
    ),
  );
}

/// Смена содержимого без рывка: ширина и высота подстраиваются, новое содержимое проявляется.
/// У [child] обязательно должен быть ключ, иначе смены не видно.
class ChatMorph extends StatelessWidget {
  const ChatMorph({
    required this.child,
    this.alignment = Alignment.centerRight,
    super.key,
  });

  final Widget child;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) => ClipRect(
    child: AnimatedSize(
      duration: AppDurations.fast,
      curve: Curves.easeOutCubic,
      alignment: alignment,
      child: AnimatedSwitcher(
        duration: AppDurations.fast,
        transitionBuilder: (child, animation) =>
            FadeTransition(opacity: animation, child: child),
        child: child,
      ),
    ),
  );
}

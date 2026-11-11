import 'package:app_ui/src/theme/app_tokens.dart';
import 'package:app_ui/src/widgets/app_tone.dart';
import 'package:material_ui/material_ui.dart';

/// Точка статуса. [pulse] — мягкое мерцание для активных процессов; отключается при `disableAnimations`.
class StatusDot extends StatefulWidget {
  const StatusDot({
    required this.tone,
    this.pulse = false,
    this.size = 8,
    super.key,
  });

  final AppTone tone;
  final bool pulse;
  final double size;

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppDurations.pulse,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animate = widget.pulse && !MediaQuery.disableAnimationsOf(context);
    if (animate && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!animate && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = toneColors(context, widget.tone).foreground;
    final dot = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    if (!widget.pulse) return dot;
    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 1).animate(_controller),
      child: dot,
    );
  }
}

/// Пилюля с точкой или иконкой и подписью. Используется для статусов запусков, хостов и чатов.
class StatusChip extends StatelessWidget {
  const StatusChip({
    required this.label,
    this.tone = AppTone.neutral,
    this.icon,
    this.pulse = false,
    super.key,
  });

  final String label;
  final AppTone tone;
  final IconData? icon;
  final bool pulse;

  @override
  Widget build(BuildContext context) {
    final colors = toneColors(context, tone);
    final textStyle = Theme.of(context).textTheme.labelMedium
        ?.copyWith(color: colors.foreground);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: AppRadius.smAll,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null)
              Icon(icon, size: 14, color: colors.foreground)
            else
              StatusDot(tone: tone, pulse: pulse, size: 6),
            const SizedBox(width: AppSpacing.xs),
            Flexible(
              child: Text(
                label,
                style: textStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

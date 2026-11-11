import 'package:app_ui/src/theme/app_tokens.dart';
import 'package:material_ui/material_ui.dart';

/// Прогресс мастера: сегменты по числу шагов, текущий подсвечен, рядом подпись «Шаг N из M».
/// Заменяет стандартный `Stepper`, который не умеет компактно показывать текущий шаг.
class OnboardingStepper extends StatelessWidget {
  const OnboardingStepper({
    required this.index,
    required this.total,
    required this.counterLabel,
    super.key,
  });

  /// Индекс текущего шага, начиная с нуля.
  final int index;
  final int total;
  final String counterLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            for (var i = 0; i < total; i++) ...[
              if (i > 0) const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: AnimatedContainer(
                  duration: AppDurations.normal,
                  curve: Curves.easeOut,
                  height: 4,
                  decoration: BoxDecoration(
                    color: i <= index
                        ? scheme.primary
                        : scheme.surfaceContainerHighest,
                    borderRadius: AppRadius.smAll,
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          counterLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

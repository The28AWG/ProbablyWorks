import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/theme/app_tokens.dart';

/// Тонкий индикатор заполнения окна контекста модели. Цвет меняется при приближении к пределу.
class ContextUsageBar extends StatelessWidget {
  const ContextUsageBar({
    required this.label,
    required this.fraction,
    super.key,
  });

  final String label;

  /// Доля от 0 до 1; значения вне диапазона обрезаются.
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = fraction.clamp(0, 1).toDouble();
    final color = value > 0.9
        ? theme.colorScheme.error
        : theme.colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: AppSpacing.xs),
        ClipRRect(
          borderRadius: AppRadius.smAll,
          child: LinearProgressIndicator(
            value: value,
            minHeight: 4,
            color: color,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
      ],
    );
  }
}

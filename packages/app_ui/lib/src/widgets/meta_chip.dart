import 'package:app_ui/src/theme/app_theme.dart';
import 'package:app_ui/src/theme/app_tokens.dart';
import 'package:app_ui/src/widgets/app_tone.dart';
import 'package:material_ui/material_ui.dart';

/// Компактная подпись метаданных: id модели, контекст, цена, возможности.
///
/// В отличие от [StatusChip] не несёт точки состояния: это данные, а не статус.
/// [icon] заменяет поясняющее слово (окно контекста, цена, размышления), а
/// [label] остаётся значением; без [label] чип занимает только значок и
/// объясняется [tooltip]. [mono] включает моноширинный шрифт для id и технических
/// значений, [tone] задаёт смысловой цвет.
class MetaChip extends StatelessWidget {
  const MetaChip({
    this.label,
    this.icon,
    this.tooltip,
    this.mono = false,
    this.tone,
    super.key,
  }) : assert(
         label != null || icon != null,
         'MetaChip без текста и значка не виден',
       );

  /// Значение чипа. Null — чип со значком без текста.
  final String? label;

  /// Значок перед значением: тот же, что у похожего понятия в интерфейсе.
  final IconData? icon;

  /// Пояснение для наведения и чтения с экрана. Обязательно для чипа без текста.
  final String? tooltip;

  final bool mono;
  final AppTone? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tone = this.tone;
    final colors = tone == null
        ? (
            foreground: theme.colorScheme.onSurfaceVariant,
            background: theme.colorScheme.surfaceContainerHighest,
          )
        : toneColors(context, tone);
    final icon = this.icon;
    final label = this.label;
    final chip = DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: AppRadius.smAll,
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: label == null ? AppSpacing.xs : AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) Icon(icon, size: 14, color: colors.foreground),
            if (icon != null && label != null)
              const SizedBox(width: AppSpacing.xs),
            if (label != null)
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontFamily: mono ? AppTheme.monoFamily : null,
                    color: colors.foreground,
                    height: 1.2,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    final tooltip = this.tooltip;
    return tooltip == null ? chip : Tooltip(message: tooltip, child: chip);
  }
}

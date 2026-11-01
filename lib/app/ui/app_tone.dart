import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/theme/app_colors.dart';

/// Смысловой тон элемента: статус агента, предупреждение, ошибка. Цвет берётся только отсюда,
/// поэтому один и тот же смысл всегда выглядит одинаково (см. docs/ui/RULEBOOK.md, раздел «Статусы»).
enum AppTone { neutral, progress, waiting, success, warning, danger, info }

typedef AppToneColors = ({Color foreground, Color background});

AppToneColors toneColors(BuildContext context, AppTone tone) {
  final scheme = Theme.of(context).colorScheme;
  final colors = context.appColors;
  return switch (tone) {
    AppTone.neutral => (
      foreground: scheme.onSurfaceVariant,
      background: scheme.surfaceContainerHighest,
    ),
    AppTone.progress => (
      foreground: colors.running,
      background: scheme.primaryContainer,
    ),
    AppTone.waiting => (
      foreground: colors.waiting,
      background: colors.warningContainer,
    ),
    AppTone.success => (
      foreground: colors.success,
      background: colors.successContainer,
    ),
    AppTone.warning => (
      foreground: colors.warning,
      background: colors.warningContainer,
    ),
    AppTone.danger => (
      foreground: scheme.error,
      background: scheme.errorContainer,
    ),
    AppTone.info => (foreground: colors.info, background: colors.infoContainer),
  };
}

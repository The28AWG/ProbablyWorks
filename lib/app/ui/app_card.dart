import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/theme/app_tokens.dart';

/// Тональная карточка без тени. [accent] — цветная полоса слева для акцента (ожидание, ошибка).
/// С [onTap] карточка кликабельна: получает hover и focus от Material.
class AppCard extends StatelessWidget {
  const AppCard({
    required this.child,
    this.onTap,
    this.accent,
    this.color,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    super.key,
  });

  final Widget child;
  final VoidCallback? onTap;
  final Color? accent;
  final Color? color;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Полоса-акцент рисуется поверх карточки, а не через IntrinsicHeight: внутренние размеры
    // ломают LayoutBuilder в содержимом (например, в выводе команды).
    final body = accent == null
        ? Padding(padding: padding, child: child)
        : Stack(
            children: [
              Padding(
                padding: padding.add(const EdgeInsets.only(left: 3)),
                child: child,
              ),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 3,
                child: ColoredBox(color: accent!),
              ),
            ],
          );
    return Material(
      color: color ?? scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.lgAll,
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      clipBehavior: Clip.antiAlias,
      child: onTap == null ? body : InkWell(onTap: onTap, child: body),
    );
  }
}

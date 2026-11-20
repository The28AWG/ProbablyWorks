import 'package:app_ui/app_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Заглушка на время загрузки отложенного модуля маршрута.
///
/// auto_route показывает её через `DeferredWidget`, пока `loadLibrary()` не
/// завершится. Это не отдельный экран, а содержимое будущей страницы, поэтому
/// здесь нет `Scaffold`: иначе внутри вкладки рабочей области появился бы
/// второй слой каркаса и собственная шапка.
class DeferredRoutePlaceholder extends StatelessWidget {
  const DeferredRoutePlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: Center(
        child: SizedBox(
          width: AppSpacing.xxl,
          height: AppSpacing.xxl,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: theme.colorScheme.primary,
            semanticsLabel: AppLocalizations.of(context).routeLoading,
          ),
        ),
      ),
    );
  }
}

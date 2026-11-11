import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/models/presentation/widgets/model_picker_dialog.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:probably_works/providers/ai/model_catalog.dart';

/// Поле выбора модели в настройках: название, id и предупреждение о статусе. Нажатие открывает
/// [showModelPickerDialog] с поиском и фильтрами, как в композере. Заменяет выпадающий список:
/// список моделей большой, и в нём невозможно искать.
/// [requireTools] — модель должна уметь tool calling (нужно агенту). Для заголовков чатов не нужно.
/// Кнопки закрепления в диалоге нет: закреплённые правятся в отдельном разделе настроек.
class ModelSettingField extends StatelessWidget {
  const ModelSettingField({
    required this.modelId,
    required this.catalog,
    required this.pinned,
    required this.onSelected,
    this.requireTools = true,
    super.key,
  });

  /// Выбранная модель; пустая строка — модель не выбрана.
  final String modelId;

  /// Состояние каталога: из него берутся название, статус и данные о tool calling.
  final ModelCatalogState catalog;

  /// Закреплённые модели показываются в диалоге первыми.
  final List<String> pinned;

  /// Вызывается с id выбранной модели. Не вызывается, если диалог закрыт без выбора или выбрана та же модель.
  final ValueChanged<String> onSelected;

  final bool requireTools;

  Future<void> _open(BuildContext context) async {
    final picked = await showModelPickerDialog(
      context,
      catalog: getIt<ModelCatalogService>(),
      pinned: pinned,
      currentId: modelId,
      requireTools: requireTools,
    );
    if (picked == null || picked.id == modelId) return;
    onSelected(picked.id);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final model = catalog.modelOf(modelId);
    final unavailable = catalog.statusOf(modelId) == ModelStatus.unavailable;
    // Сведения о tool calling: из списка, а если списка ещё нет — из сохранённых деталей выбранной модели.
    final supportsTools =
        model?.supportsTools ?? catalog.saved[modelId]?.supportsTools;
    final noTools =
        requireTools && modelId.isNotEmpty && supportsTools == false;
    final warning = unavailable
        ? l10n.settingsModelUnavailable
        : (noTools ? l10n.settingsNoToolsWarning : null);
    return AppCard(
      onTap: () => _open(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      modelId.isEmpty
                          ? l10n.settingsModelNotSelected
                          : catalog.nameOf(modelId),
                      style: theme.textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (modelId.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        modelId,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontFamily: AppTheme.monoFamily,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              if (catalog.initialLoading)
                const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  Icons.unfold_more,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
            ],
          ),
          if (warning != null) ...[
            const SizedBox(height: AppSpacing.sm),
            AppBanner(
              margin: EdgeInsets.zero,
              tone: AppTone.danger,
              icon: Icons.error_outline,
              message: warning,
            ),
          ],
        ],
      ),
    );
  }
}

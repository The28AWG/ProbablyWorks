import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/models/domain/model_selection.dart';
import 'package:probably_works/features/models/presentation/reasoning_labels.dart';
import 'package:probably_works/features/models/presentation/widgets/model_picker_dialog.dart';
import 'package:probably_works/features/models/presentation/widgets/reasoning_dialog.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';

/// Поле выбора модели в настройках: название, id и предупреждение о статусе. Нажатие открывает
/// [showModelPickerDialog] с поиском и фильтрами, как в композере. Заменяет выпадающий список:
/// список моделей большой, и в нём невозможно искать.
/// [requireTools] — модель должна уметь tool calling (нужно агенту). Для заголовков чатов не нужно.
/// Кнопки закрепления в диалоге нет: закреплённые правятся в отдельном разделе настроек.
class ModelSettingField extends StatelessWidget {
  const ModelSettingField({
    required this.modelId,
    required this.reasoning,
    required this.catalog,
    required this.source,
    required this.pinned,
    required this.onSelected,
    this.onReasoningSelected,
    this.requireTools = true,
    this.showReasoning = true,
    super.key,
  });

  /// Выбранная модель; пустая строка — модель не выбрана.
  final String modelId;

  /// Текущий уровень рассуждений для этой роли модели.
  final ReasoningPreference reasoning;

  /// Состояние каталога: из него берутся название, статус и данные о tool calling.
  final ModelCatalogState catalog;

  /// Источник каталога профиля: локальный сервис или удалённый агент.
  final ModelCatalogSource source;

  /// Закреплённые модели показываются в диалоге первыми.
  final List<String> pinned;

  /// Вызывается с выбранной моделью и уровнем. Для заголовка модели
  /// [showReasoning] выключен, и уровень остаётся прежним.
  final ValueChanged<ModelSelection> onSelected;

  /// Быстрая смена уровня без открытия выбора модели. Null — селектора нет.
  final ValueChanged<ReasoningPreference>? onReasoningSelected;

  final bool requireTools;

  /// Показывать ли селектор рассуждений. Для заголовков чатов он не нужен.
  final bool showReasoning;

  Future<void> _open(BuildContext context) async {
    final picked = await showModelPickerDialog(
      context,
      catalog: source,
      pinned: pinned,
      currentId: modelId,
      requireTools: requireTools,
    );
    if (picked == null) return;
    if (!context.mounted) return;
    final capability = picked.reasoning ?? catalog.saved[picked.id]?.reasoning;
    var nextReasoning = reasoning;
    if (showReasoning && capability?.supported != false) {
      nextReasoning =
          await showReasoningDialog(
            context,
            modelName: picked.name,
            capability: capability,
            initial: reasoning,
            defaultPreference: reasoning,
          ) ??
          reasoning;
    }
    if (picked.id == modelId && nextReasoning == reasoning) return;
    onSelected(ModelSelection(model: picked, reasoning: nextReasoning));
  }

  /// Не вызывает сохранение, если пользователь выбрал тот же уровень.
  void _selectReasoning(
    ReasoningPreference? value,
    ReasoningPreference selected,
  ) {
    if (value == null || value == selected) return;
    onReasoningSelected?.call(value);
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
    final capability = model?.reasoning ?? catalog.saved[modelId]?.reasoning;
    final options = reasoningOptions(capability);
    final selected = options.contains(reasoning)
        ? reasoning
        : ReasoningPreference.auto;
    final notSupported =
        showReasoning && modelId.isNotEmpty && capability?.supported == false;
    final showSelector =
        showReasoning &&
        modelId.isNotEmpty &&
        onReasoningSelected != null &&
        options.length > 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppCard(
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
                            catalog.modelIdForDisplay(modelId),
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
        ),
        if (notSupported) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            l10n.reasoningNotSupported,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ] else if (showSelector) ...[
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.settingsReasoning,
                      style: theme.textTheme.labelLarge,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      l10n.settingsReasoningHint,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              _ReasoningDropdown(
                key: ValueKey('$modelId:${selected.name}:${options.length}'),
                selected: selected,
                options: options,
                onSelected: (value) => _selectReasoning(value, selected),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Выпадающий список уровня рассуждений.
///
/// Без label и hint: подпись уже стоит слева. Поле не получает фокус, поэтому
/// в него нельзя печатать; меню открывается только нажатием.
class _ReasoningDropdown extends StatefulWidget {
  const _ReasoningDropdown({
    required this.selected,
    required this.options,
    required this.onSelected,
    super.key,
  });

  final ReasoningPreference selected;
  final List<ReasoningPreference> options;
  final ValueChanged<ReasoningPreference> onSelected;

  @override
  State<_ReasoningDropdown> createState() => _ReasoningDropdownState();
}

class _ReasoningDropdownState extends State<_ReasoningDropdown> {
  /// Фокус запрещён: иначе DropdownMenu превращается в редактируемое поле.
  late final FocusNode _focus = FocusNode(canRequestFocus: false);

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return DropdownMenu<ReasoningPreference>(
      width: 200,
      initialSelection: widget.selected,
      focusNode: _focus,
      requestFocusOnTap: false,
      enableFilter: false,
      dropdownMenuEntries: [
        for (final option in widget.options)
          DropdownMenuEntry(value: option, label: reasoningLabel(l10n, option)),
      ],
      onSelected: _onSelected,
    );
  }

  void _onSelected(ReasoningPreference? value) {
    if (value == null || value == widget.selected) return;
    widget.onSelected(value);
  }
}

import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/models/presentation/reasoning_labels.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';

/// Второе окно после выбора модели: уровень рассуждений.
///
/// Возвращает выбранный уровень или null, если пользователь закрыл окно.
/// Null означает «оставить прежний выбор»: модель уже выбрана, а уровень можно
/// поменять позже через «+» или настройки.
Future<ReasoningPreference?> showReasoningDialog(
  BuildContext context, {
  required String modelName,
  required LlmReasoningCapability? capability,
  required ReasoningPreference initial,
  required ReasoningPreference defaultPreference,
  bool allowInherit = false,
}) => showDialog<ReasoningPreference>(
  context: context,
  builder: (_) => _ReasoningDialog(
    modelName: modelName,
    capability: capability,
    initial: initial,
    defaultPreference: defaultPreference,
    allowInherit: allowInherit,
  ),
);

class _ReasoningDialog extends StatefulWidget {
  const _ReasoningDialog({
    required this.modelName,
    required this.capability,
    required this.initial,
    required this.defaultPreference,
    required this.allowInherit,
  });

  final String modelName;
  final LlmReasoningCapability? capability;
  final ReasoningPreference initial;
  final ReasoningPreference defaultPreference;
  final bool allowInherit;

  @override
  State<_ReasoningDialog> createState() => _ReasoningDialogState();
}

class _ReasoningDialogState extends State<_ReasoningDialog> {
  late final List<ReasoningPreference> _options = reasoningOptions(
    widget.capability,
    allowInherit: widget.allowInherit,
  );
  late ReasoningPreference _selected = _options.contains(widget.initial)
      ? widget.initial
      : _options.first;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    // Dialog, а не AlertDialog: AppChoiceGroup использует LayoutBuilder,
    // а AlertDialog измеряет intrinsic-размеры и падает на этом.
    return Dialog(
      insetPadding: const EdgeInsets.all(AppSpacing.lg),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: AppLayout.dialogWidth,
          maxHeight: MediaQuery.sizeOf(context).height - 96,
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.reasoningDialogTitle(widget.modelName),
                style: theme.textTheme.titleLarge,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                l10n.reasoningDialogHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Flexible(
                child: SingleChildScrollView(
                  child: AppChoiceGroup<ReasoningPreference>(
                    options: [
                      for (final preference in _options)
                        AppChoiceOption(
                          value: preference,
                          title: reasoningLabel(l10n, preference),
                          subtitle: reasoningHint(
                            l10n,
                            preference,
                            defaultPreference: widget.defaultPreference,
                          ),
                        ),
                    ],
                    selected: _selected,
                    onChanged: (value) => setState(() => _selected = value),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                l10n.reasoningHigherCostHint,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(l10n.commonCancel),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, _selected),
                    child: Text(l10n.commonSave),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

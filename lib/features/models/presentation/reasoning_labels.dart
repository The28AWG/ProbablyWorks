import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';

/// Порядок вариантов в диалоге и подменю: сначала «по умолчанию»/«авто»,
/// затем явные уровни. Для модели без поддержки reasoning остаётся только авто.
List<ReasoningPreference> reasoningOptions(
  LlmReasoningCapability? capability, {
  bool allowInherit = false,
}) {
  final options = <ReasoningPreference>[
    if (allowInherit) ReasoningPreference.inherit,
    ReasoningPreference.auto,
  ];
  if (capability?.supported == false) return options;
  if (capability?.canDisable ?? true) options.add(ReasoningPreference.none);
  for (final effort
      in capability?.selectableEfforts ?? ReasoningEffort.values) {
    final preference = ReasoningPreference.fromEffort(effort);
    if (!options.contains(preference)) options.add(preference);
  }
  return options;
}

/// Подпись уровня для интерфейса.
String reasoningLabel(AppLocalizations l10n, ReasoningPreference preference) =>
    switch (preference) {
      ReasoningPreference.inherit => l10n.reasoningInherit,
      ReasoningPreference.auto => l10n.reasoningAuto,
      ReasoningPreference.none => l10n.reasoningNone,
      ReasoningPreference.minimal => l10n.reasoningMinimal,
      ReasoningPreference.low => l10n.reasoningLow,
      ReasoningPreference.medium => l10n.reasoningMedium,
      ReasoningPreference.high => l10n.reasoningHigh,
      ReasoningPreference.xhigh => l10n.reasoningXhigh,
      ReasoningPreference.max => l10n.reasoningMax,
    };

/// Пояснение к уровню: что изменится при выборе.
String reasoningHint(
  AppLocalizations l10n,
  ReasoningPreference preference, {
  required ReasoningPreference defaultPreference,
}) => switch (preference) {
  ReasoningPreference.inherit => l10n.reasoningInheritHint(
    reasoningLabel(l10n, defaultPreference),
  ),
  ReasoningPreference.auto => l10n.reasoningAutoHint,
  ReasoningPreference.none => l10n.reasoningNoneHint,
  ReasoningPreference.minimal => l10n.reasoningMinimalHint,
  ReasoningPreference.low => l10n.reasoningLowHint,
  ReasoningPreference.medium => l10n.reasoningMediumHint,
  ReasoningPreference.high => l10n.reasoningHighHint,
  ReasoningPreference.xhigh => l10n.reasoningXhighHint,
  ReasoningPreference.max => l10n.reasoningMaxHint,
};

/// Короткая подпись для чипа/бейджа. У `inherit` показываем фактическое
/// значение из настроек, иначе пользователь не видит, что применится.
String reasoningEffectiveLabel(
  AppLocalizations l10n,
  ReasoningPreference preference,
  ReasoningPreference defaultPreference,
) => reasoningLabel(
  l10n,
  preference == ReasoningPreference.inherit ? defaultPreference : preference,
);

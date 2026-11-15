import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/providers/ai/model_runtime.dart';

/// Подпись этапа загрузки. Технические имена провайдера сюда не попадают.
String modelRuntimeStageLabel(AppLocalizations l10n, ModelLoadStage? stage) =>
    switch (stage) {
      ModelLoadStage.weights => l10n.modelRuntimeStageWeights,
      ModelLoadStage.projector => l10n.modelRuntimeStageProjector,
      ModelLoadStage.draft => l10n.modelRuntimeStageDraft,
      ModelLoadStage.other || null => l10n.modelRuntimeStageOther,
    };

/// Подсказка чипа модели. [modelLabel] null — модель ещё не названа.
String modelRuntimeTooltip(
  AppLocalizations l10n,
  String? modelLabel,
  ModelRuntime runtime,
) {
  final name = modelLabel ?? l10n.chatModelLabel;
  final fraction = runtime.progress?.fraction;
  final percent = fraction == null ? null : (fraction * 100).round();
  return switch (runtime.phase) {
    ModelRuntimePhase.loading when percent != null =>
      l10n.modelRuntimeChipLoading(
        name,
        '$percent',
        modelRuntimeStageLabel(l10n, runtime.progress?.stage),
      ),
    ModelRuntimePhase.loading => l10n.modelRuntimeChipLoadingIndeterminate(
      name,
    ),
    ModelRuntimePhase.downloading when percent != null =>
      l10n.modelRuntimeChipDownloading(name, '$percent'),
    ModelRuntimePhase.downloading =>
      l10n.modelRuntimeChipDownloadingIndeterminate(name),
    ModelRuntimePhase.unloading => l10n.modelRuntimeChipUnloading(name),
    ModelRuntimePhase.loaded => l10n.modelRuntimeChipLoaded(name),
    ModelRuntimePhase.sleeping => l10n.modelRuntimeChipSleeping(name),
    ModelRuntimePhase.incomplete => l10n.modelRuntimeChipIncomplete(name),
    ModelRuntimePhase.failed =>
      runtime.error == null
          ? l10n.modelRuntimeChipFailed(name)
          : l10n.modelRuntimeChipFailedWith(name, runtime.error!),
    ModelRuntimePhase.unloaded => l10n.modelRuntimeChipUnloaded(name),
    ModelRuntimePhase.unknown => l10n.chatModelTooltip(name),
  };
}

/// Короткая подпись состояния без имени модели. Нужна спискам в настройках.
String modelRuntimeStatusLabel(AppLocalizations l10n, ModelRuntime runtime) {
  final fraction = runtime.progress?.fraction;
  final percent = fraction == null ? null : (fraction * 100).round();
  return switch (runtime.phase) {
    ModelRuntimePhase.loading when percent != null =>
      l10n.modelRuntimeStatusLoading(
        '$percent',
        modelRuntimeStageLabel(l10n, runtime.progress?.stage),
      ),
    ModelRuntimePhase.loading => l10n.modelRuntimeBadgeLoading,
    ModelRuntimePhase.unloading => l10n.modelRuntimeBadgeUnloading,
    ModelRuntimePhase.downloading when percent != null =>
      l10n.modelRuntimeStatusDownloading('$percent'),
    ModelRuntimePhase.downloading => l10n.modelRuntimeBadgeDownloading,
    ModelRuntimePhase.loaded => l10n.modelRuntimeBadgeLoaded,
    ModelRuntimePhase.sleeping => l10n.modelRuntimeBadgeSleeping,
    ModelRuntimePhase.failed => l10n.modelRuntimeBadgeFailed,
    ModelRuntimePhase.incomplete => l10n.modelRuntimeBadgeIncomplete,
    ModelRuntimePhase.unloaded => l10n.modelRuntimeBadgeUnloaded,
    ModelRuntimePhase.unknown => l10n.modelRuntimeBadgeUnknown,
  };
}

/// Сообщение баннера в доке: что грузится и сколько осталось.
String modelRuntimeBannerMessage(
  AppLocalizations l10n,
  String modelName,
  ModelRuntime runtime,
) {
  final fraction = runtime.progress?.fraction;
  if (fraction == null) {
    return l10n.modelRuntimeBannerMessageNoPercent(modelName);
  }
  return l10n.modelRuntimeBannerMessage(
    modelName,
    '${(fraction * 100).round()}',
    modelRuntimeStageLabel(l10n, runtime.progress?.stage),
  );
}

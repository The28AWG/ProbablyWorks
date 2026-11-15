import 'package:app_ui/app_ui.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/core/platform/app_platform.dart';
import 'package:probably_works/features/models/presentation/model_runtime_labels.dart';
import 'package:probably_works/features/settings/presentation/bloc/local_models_cubit.dart';
import 'package:probably_works/features/settings/presentation/widgets/local_model_dialogs.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/providers/ai/local_models.dart';
import 'package:pw_agent/providers/ai/model_runtime.dart';

/// Раздел «Локальные модели»: файлы среды выполнения и их параметры.
///
/// Раздел живёт отдельно от карточки провайдера: при выключенном провайдере
/// файлы всё равно можно скачать, настроить и удалить.
class LocalModelsSection extends StatefulWidget {
  const LocalModelsSection({
    required this.source,
    required this.runtime,
    super.key,
  });

  final LocalModelsSource source;
  final ModelRuntimeSource runtime;

  @override
  State<LocalModelsSection> createState() => _LocalModelsSectionState();
}

class _LocalModelsSectionState extends State<LocalModelsSection> {
  late final LocalModelsCubit _cubit;

  @override
  void initState() {
    super.initState();
    _cubit = LocalModelsCubit(widget.source, widget.runtime)..load();
  }

  @override
  void dispose() {
    _cubit.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return BlocProvider.value(
      value: _cubit,
      child: BlocBuilder<LocalModelsCubit, LocalModelsViewState>(
        builder: (context, state) => AppSection(
          title: l10n.localModelsTitle,
          description: l10n.localModelsDescription,
          children: [
            if (!state.models.supported)
              AppBanner(
                margin: EdgeInsets.zero,
                tone: AppTone.info,
                icon: Icons.info_outline,
                message: l10n.localModelsUnsupported,
              )
            else ...[
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  FilledButton.icon(
                    onPressed: state.busy ? null : () => _install(context),
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: Text(
                      l10n.localModelsInstall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (!AppPlatform.current.isWeb &&
                      AppPlatform.current.supportsDirectoryPicker)
                    OutlinedButton.icon(
                      onPressed: state.busy ? null : _import,
                      icon: const Icon(Icons.folder_open, size: 18),
                      label: Text(
                        l10n.localModelsImport,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
              if (state.error case final error?)
                AppBanner(
                  margin: EdgeInsets.zero,
                  tone: AppTone.danger,
                  icon: Icons.error_outline,
                  message: l10n.commonError(error),
                  action: TextButton(
                    onPressed: state.busy ? null : _cubit.dismissError,
                    child: Text(
                      l10n.commonClose,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              _StorageCard(state: state, cubit: _cubit),
              for (final download in state.models.downloads)
                _DownloadCard(
                  download: download,
                  onCancel: () => _cubit.cancelInstall(download.id),
                ),
              if (state.loading && state.models.models.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(AppSpacing.lg),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (state.models.models.isEmpty)
                AppEmptyState(
                  icon: Icons.memory,
                  title: l10n.localModelsEmptyTitle,
                  message: l10n.localModelsEmptyMessage,
                )
              else
                for (final model in state.models.models)
                  _ModelCard(
                    model: model,
                    runtime: state.runtimeOf(model.id),
                    busy: state.busy,
                    onLoad: () => _cubit.loadModel(model.id),
                    onUnload: () => _unload(context, model),
                    onSettings: () => _settings(context, model),
                    onDelete: () => _delete(context, model),
                  ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _install(BuildContext context) async {
    final request = await showDialog<LocalModelInstallRequest>(
      context: context,
      builder: (_) => const LocalModelInstallDialog(),
    );
    if (request == null || !mounted) return;
    await _cubit.install(
      request.source,
      name: request.name,
      sha256: request.sha256,
    );
  }

  Future<void> _import() async {
    final file = await openFile();
    if (file == null || !mounted) return;
    await _cubit.importPath(file.path);
  }

  Future<void> _unload(BuildContext context, LocalModelFile model) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await ConfirmDialog.confirm(
      context,
      title: l10n.localModelsUnloadTitle(model.name),
      message: l10n.localModelsUnloadMessage,
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.modelRuntimeUnload,
    );
    if (confirmed) await _cubit.unloadModel(model.id);
  }

  Future<void> _delete(BuildContext context, LocalModelFile model) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await ConfirmDialog.confirm(
      context,
      title: l10n.localModelsDeleteTitle(model.name),
      message: model.cacheKey == null
          ? l10n.localModelsDeleteImported
          : l10n.localModelsDeleteMessage,
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.commonDelete,
      destructive: true,
    );
    if (confirmed) await _cubit.delete(model.id);
  }

  Future<void> _settings(BuildContext context, LocalModelFile model) async {
    final settings = await showDialog<LocalModelSettings>(
      context: context,
      builder: (_) => LocalModelSettingsDialog(
        modelName: model.name,
        initial: model.settings,
      ),
    );
    if (settings == null || !mounted) return;
    await _cubit.updateSettings(model.id, settings);
  }
}

/// Занятое место, авто-выгрузка и очистка кэша.
class _StorageCard extends StatelessWidget {
  const _StorageCard({required this.state, required this.cubit});

  final LocalModelsViewState state;
  final LocalModelsCubit cubit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.localModelsStorage(
                    _formatBytes(state.models.totalBytes),
                  ),
                  style: theme.textTheme.titleSmall,
                ),
              ),
              Flexible(
                child: TextButton.icon(
                  onPressed:
                      state.busy ||
                          state.models.hasDownloads ||
                          !_hasCacheFiles(state)
                      ? null
                      : () => _clear(context),
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: Text(
                    l10n.localModelsClearCache,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            l10n.localModelsStorageHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Material(
            type: MaterialType.transparency,
            child: DropdownMenu<int>(
              initialSelection: state.models.autoUnloadMinutes,
              expandedInsets: EdgeInsets.zero,
              requestFocusOnTap: false,
              label: Text(
                l10n.localModelsAutoUnload,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              dropdownMenuEntries: [
                for (final minutes in const [0, 10, 30, 60])
                  DropdownMenuEntry(
                    value: minutes,
                    label: minutes == 0
                        ? l10n.localModelsAutoUnloadNever
                        : l10n.localModelsAutoUnloadMinutes('$minutes'),
                  ),
              ],
              onSelected: state.busy
                  ? null
                  : (value) {
                      if (value != null) cubit.saveAutoUnload(value);
                    },
            ),
          ),
        ],
      ),
    );
  }

  /// Есть ли что удалять: импортированные файлы очистка не трогает.
  static bool _hasCacheFiles(LocalModelsViewState state) =>
      state.models.models.any((model) => model.cacheKey != null);

  Future<void> _clear(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await ConfirmDialog.confirm(
      context,
      title: l10n.localModelsClearTitle,
      message: l10n.localModelsClearMessage,
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.localModelsClearCache,
      destructive: true,
    );
    if (confirmed) await cubit.clearCache();
  }
}

/// Активное скачивание с прогрессом и отменой.
class _DownloadCard extends StatelessWidget {
  const _DownloadCard({required this.download, required this.onCancel});

  final LocalModelDownload download;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  download.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              TextButton(
                onPressed: onCancel,
                child: Text(
                  l10n.commonCancel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          LinearProgressIndicator(value: download.fraction),
          const SizedBox(height: AppSpacing.xs),
          Text(
            download.receivedBytes == null || download.totalBytes == null
                ? l10n.localModelsDownloadPreparing
                : l10n.localModelsDownloadProgress(
                    _formatBytes(download.receivedBytes!),
                    _formatBytes(download.totalBytes!),
                  ),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// Установленный файл: состояние памяти, параметры и действия.
class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.model,
    required this.runtime,
    required this.busy,
    required this.onLoad,
    required this.onUnload,
    required this.onSettings,
    required this.onDelete,
  });

  final LocalModelFile model;
  final ModelRuntime? runtime;
  final bool busy;
  final VoidCallback onLoad;
  final VoidCallback onUnload;
  final VoidCallback onSettings;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final phase = runtime?.phase ?? ModelRuntimePhase.unloaded;
    final transitional =
        phase == ModelRuntimePhase.loading ||
        phase == ModelRuntimePhase.unloading;
    final tone = !model.available
        ? AppTone.warning
        : switch (phase) {
            ModelRuntimePhase.loaded => AppTone.success,
            ModelRuntimePhase.loading ||
            ModelRuntimePhase.unloading => AppTone.progress,
            ModelRuntimePhase.failed => AppTone.warning,
            _ => AppTone.neutral,
          };
    final settings = model.settings;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusDot(tone: tone, pulse: transitional),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      model.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    Text(
                      model.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                _formatBytes(model.sizeBytes ?? 0),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(width: AppSpacing.sm),
              if (busy || transitional)
                const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (phase == ModelRuntimePhase.loaded)
                IconButton(
                  tooltip: l10n.modelRuntimeUnload,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.power_settings_new, size: 18),
                  onPressed: onUnload,
                )
              else
                IconButton(
                  tooltip: l10n.modelRuntimeLoad,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.play_arrow_outlined, size: 20),
                  onPressed: model.available ? onLoad : null,
                ),
              IconButton(
                tooltip: l10n.localModelsSettings,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.tune, size: 18),
                onPressed: busy ? null : onSettings,
              ),
              IconButton(
                tooltip: l10n.commonDelete,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: busy ? null : onDelete,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              _MetaChip(
                label: l10n.localModelsContextValue('${settings.contextSize}'),
              ),
              _MetaChip(
                label: settings.gpuLayers < 0
                    ? l10n.localModelsGpuAll
                    : l10n.localModelsGpuValue('${settings.gpuLayers}'),
              ),
              if (!settings.supportsTools)
                _MetaChip(label: l10n.localModelsNoTools),
              if (settings.projectorSource != null)
                _MetaChip(label: l10n.localModelsProjectorChip),
              if (phase != ModelRuntimePhase.unloaded)
                StatusChip(
                  label: modelRuntimeStatusLabel(
                    l10n,
                    runtime ??
                        ModelRuntime(
                          modelId: model.id,
                          phase: ModelRuntimePhase.unloaded,
                        ),
                  ),
                  tone: tone,
                  pulse: transitional,
                ),
            ],
          ),
          if (!model.available) ...[
            const SizedBox(height: AppSpacing.sm),
            AppBanner(
              margin: EdgeInsets.zero,
              tone: AppTone.warning,
              icon: Icons.report_outlined,
              message: l10n.localModelsMissingFile,
            ),
          ],
          if (runtime?.error case final error?) ...[
            const SizedBox(height: AppSpacing.sm),
            AppBanner(
              margin: EdgeInsets.zero,
              tone: AppTone.danger,
              icon: Icons.error_outline,
              message: l10n.commonError(error),
            ),
          ],
        ],
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: 2,
        ),
        child: Text(label, style: theme.textTheme.labelSmall),
      ),
    );
  }
}

/// Размер в человекочитаемом виде: `1.5 GB`, `420 MB`.
String _formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = unit == 0
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(value >= 100 ? 0 : 1);
  return '$text ${units[unit]}';
}

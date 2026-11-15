/// Runtime-адаптер llama.cpp server.
///
/// В router-режиме (`--models-dir` или `--models-preset`) сервер отдаёт
/// состояние каждой модели в `GET /models`, прогресс — в `GET /models/sse`,
/// а загрузкой и выгрузкой управляют `POST /models/load|unload`.
///
/// В single-model режиме (`llama-server -m model.gguf`) доступно только
/// состояние сервера: `/health` отвечает 503, пока модель загружается.
/// Процентов и управления там нет, поэтому возможности адаптера честно
/// ограничены.
library;

import 'dart:async';

import 'package:llama_cpp/llama_cpp.dart' hide llamaCppDefaultBaseUrl;
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/providers/ai/llama_cpp/llama_cpp_connection.dart';
import 'package:pw_agent/providers/ai/llm_provider_meta.dart';
import 'package:pw_agent/providers/ai/model_runtime.dart';

/// Сколько ждать между опросами single-model сервера.
const _singlePollInterval = Duration(seconds: 10);

/// Сколько ждать между опросами router-сервера, если SSE недоступен.
const _routerIdlePollInterval = Duration(seconds: 15);
const _routerLoadingPollInterval = Duration(seconds: 1);

/// Наблюдение за моделями llama.cpp server.
class LlamaCppModelRuntime {
  LlamaCppModelRuntime({
    required this.readConfig,
    this.requestTimeout = const Duration(seconds: 60),
  });

  final Future<LlmProviderConfig> Function() readConfig;
  final Duration requestTimeout;

  List<LlmProviderDescriptor> get providers => const [llamaCppDescriptor];

  Future<bool> get runtimeEnabled async => (await readConfig()).enabled;

  LlamaCpp _client(LlmProviderConfig config) => LlamaCpp(
    baseUrl: config.baseUrl ?? llamaCppDefaultBaseUrl,
    requestTimeout: requestTimeout,
    apiKey: config.apiKey,
  );

  LlamaCppOpenAi _openAi(LlmProviderConfig config) => LlamaCppOpenAi(
    baseUrl: config.baseUrl ?? llamaCppDefaultBaseUrl,
    requestTimeout: requestTimeout,
    apiKey: config.apiKey,
  );

  Future<ProviderRuntimeState> snapshotRuntime() async {
    final config = await readConfig();
    if (!config.enabled) {
      return const ProviderRuntimeState(providerId: llamaCppProviderId);
    }
    final client = _client(config);
    try {
      final listed = await client.listModels();
      final models = listed.data ?? const <LlamaCppModelInfo>[];
      if (_isRouter(models)) {
        return _routerState(
          _modelsFromList(models),
          ModelRuntimeCapabilities.full,
        );
      }
    } on LlamaCppException catch (error, stack) {
      // Single-model сервер не знает router `/models`; это нормальный путь.
      if (error.statusCode != 404 && error.statusCode != 405) {
        Error.throwWithStackTrace(llamaCppFailureOf(error), stack);
      }
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(_networkFailure(error), stack);
    }
    return _singleState(config, client);
  }

  Stream<ProviderRuntimeState> watchRuntime() async* {
    final config = await readConfig();
    if (!config.enabled) return;
    final client = _client(config);
    try {
      final listed = await client.listModels();
      final models = listed.data ?? const <LlamaCppModelInfo>[];
      if (_isRouter(models)) {
        yield* _watchRouter(client, models);
        return;
      }
    } on LlamaCppException catch (error, stack) {
      if (error.statusCode != 404 && error.statusCode != 405) {
        Error.throwWithStackTrace(llamaCppFailureOf(error), stack);
      }
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(_networkFailure(error), stack);
    }
    yield* _watchSingle(config, client);
  }

  Future<void> loadRuntimeModel(String localModelId) async {
    final config = await readConfig();
    final client = _client(config);
    try {
      await client.loadModel(localModelId);
    } on LlamaCppException catch (error, stack) {
      // Повторная загрузка уже запущенной модели — не ошибка для UI.
      if (error.body.toLowerCase().contains('already running')) return;
      Error.throwWithStackTrace(llamaCppFailureOf(error), stack);
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(_networkFailure(error), stack);
    }
  }

  Future<void> unloadRuntimeModel(String localModelId) async {
    final config = await readConfig();
    final client = _client(config);
    try {
      await client.unloadModel(localModelId);
    } on LlamaCppException catch (error, stack) {
      // Выгрузка уже выгруженной модели идемпотентна.
      if (error.body.toLowerCase().contains('not running')) return;
      Error.throwWithStackTrace(llamaCppFailureOf(error), stack);
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(_networkFailure(error), stack);
    }
  }

  Stream<ProviderRuntimeState> _watchRouter(
    LlamaCpp client,
    List<LlamaCppModelInfo> initial,
  ) async* {
    final models = _modelsFromList(initial);
    yield _routerState(models, ModelRuntimeCapabilities.full);
    try {
      await for (final event in client.modelsEvents()) {
        if (event is LlamaCppModelsReloadEvent) {
          final listed = await client.listModels();
          models
            ..clear()
            ..addAll(_modelsFromList(listed.data ?? const []));
        } else if (event is LlamaCppModelsModelRemoveEvent) {
          models.remove(llamaCppDescriptor.globalModelId(event.model));
        } else {
          _applyEvent(models, event);
        }
        yield _routerState(models, ModelRuntimeCapabilities.full);
      }
    } on LlamaCppException catch (error) {
      // Старые сборки без SSE: остаёмся с опросом, а не теряем состояние.
      if (error.statusCode != 404 && error.statusCode != 405) rethrow;
      yield* _pollRouter(client, models);
    }
  }

  Stream<ProviderRuntimeState> _pollRouter(
    LlamaCpp client,
    Map<String, ModelRuntime> models,
  ) async* {
    while (true) {
      final loading = models.values.any(
        (model) =>
            model.phase == ModelRuntimePhase.loading ||
            model.phase == ModelRuntimePhase.unloading,
      );
      await Future<void>.delayed(
        loading ? _routerLoadingPollInterval : _routerIdlePollInterval,
      );
      final listed = await client.listModels();
      final next = _modelsFromList(listed.data ?? const []);
      final merged = <String, ModelRuntime>{};
      for (final entry in next.entries) {
        final previous = models[entry.key];
        merged[entry.key] =
            previous?.phase == ModelRuntimePhase.loading &&
                entry.value.phase == ModelRuntimePhase.loading
            ? entry.value.copyWith(
                progress: previous?.progress,
                startedAt: previous?.startedAt,
              )
            : entry.value;
      }
      models
        ..clear()
        ..addAll(merged);
      yield _routerState(models, ModelRuntimeCapabilities.full);
    }
  }

  Stream<ProviderRuntimeState> _watchSingle(
    LlmProviderConfig config,
    LlamaCpp client,
  ) async* {
    final known = <String>{};
    while (true) {
      var phase = ModelRuntimePhase.unknown;
      String? error;
      try {
        await client.health();
        phase = ModelRuntimePhase.loaded;
        final listed = await _openAi(config).listModels();
        for (final model
            in listed.data ?? const <LlamaCppOpenAiModelSummary>[]) {
          if (model.id != null && model.id!.isNotEmpty) known.add(model.id!);
        }
      } on LlamaCppException catch (failure) {
        if (failure.statusCode == 503) {
          phase = ModelRuntimePhase.loading;
        } else {
          error = llamaCppFailureOf(failure).message;
        }
      } on Object catch (failure) {
        error = _networkFailure(failure).message;
      }
      yield ProviderRuntimeState(
        providerId: llamaCppProviderId,
        capabilities: const ModelRuntimeCapabilities(reportsState: true),
        models: {
          for (final id in known)
            llamaCppDescriptor.globalModelId(id): ModelRuntime(
              modelId: llamaCppDescriptor.globalModelId(id),
              phase: phase,
              error: error,
              updatedAt: DateTime.now().toUtc(),
              loadedAt: phase == ModelRuntimePhase.loaded
                  ? DateTime.now().toUtc()
                  : null,
              reported: true,
            ),
        },
        error: error,
        updatedAt: DateTime.now().toUtc(),
      );
      await Future<void>.delayed(_singlePollInterval);
    }
  }

  Future<ProviderRuntimeState> _singleState(
    LlmProviderConfig config,
    LlamaCpp client,
  ) async {
    final known = <String>{};
    ModelRuntimePhase phase;
    try {
      await client.health();
      phase = ModelRuntimePhase.loaded;
      final listed = await _openAi(config).listModels();
      for (final model in listed.data ?? const <LlamaCppOpenAiModelSummary>[]) {
        if (model.id != null && model.id!.isNotEmpty) known.add(model.id!);
      }
    } on LlamaCppException catch (failure, stack) {
      phase = failure.statusCode == 503
          ? ModelRuntimePhase.loading
          : ModelRuntimePhase.unknown;
      if (phase == ModelRuntimePhase.unknown) {
        Error.throwWithStackTrace(llamaCppFailureOf(failure), stack);
      }
    } on Object catch (failure, stack) {
      Error.throwWithStackTrace(_networkFailure(failure), stack);
    }
    final now = DateTime.now().toUtc();
    return ProviderRuntimeState(
      providerId: llamaCppProviderId,
      capabilities: const ModelRuntimeCapabilities(reportsState: true),
      models: {
        for (final id in known)
          llamaCppDescriptor.globalModelId(id): ModelRuntime(
            modelId: llamaCppDescriptor.globalModelId(id),
            phase: phase,
            updatedAt: now,
            loadedAt: phase == ModelRuntimePhase.loaded ? now : null,
            reported: true,
          ),
      },
      updatedAt: now,
    );
  }

  bool _isRouter(List<LlamaCppModelInfo> models) => models.any(
    (model) => model.status?.value != null || model.status?.rawValue != null,
  );

  Map<String, ModelRuntime> _modelsFromList(List<LlamaCppModelInfo> models) {
    final now = DateTime.now().toUtc();
    return {
      for (final model in models)
        if (model.id != null && model.id!.isNotEmpty)
          llamaCppDescriptor.globalModelId(model.id!): _fromStatus(
            model.id!,
            model.status,
            now,
          ),
    };
  }

  ModelRuntime _fromStatus(
    String localId,
    LlamaCppModelStatus? status,
    DateTime now,
  ) {
    final value = status?.value;
    final raw = status?.rawValue;
    final phase = switch (value) {
      LlamaCppModelStatusValue.unloaded =>
        status?.failed == true
            ? ModelRuntimePhase.failed
            : ModelRuntimePhase.unloaded,
      LlamaCppModelStatusValue.loading => ModelRuntimePhase.loading,
      LlamaCppModelStatusValue.loaded => ModelRuntimePhase.loaded,
      LlamaCppModelStatusValue.sleeping => ModelRuntimePhase.sleeping,
      LlamaCppModelStatusValue.downloading => ModelRuntimePhase.downloading,
      null when raw == 'incomplete' => ModelRuntimePhase.incomplete,
      null => ModelRuntimePhase.unknown,
    };
    return ModelRuntime(
      modelId: llamaCppDescriptor.globalModelId(localId),
      phase: phase,
      progress: phase == ModelRuntimePhase.downloading
          ? _downloadProgress(status?.progress)
          : null,
      error: phase == ModelRuntimePhase.failed
          ? _failedMessage(status?.exitCode)
          : null,
      updatedAt: now,
      startedAt: phase == ModelRuntimePhase.loading ? now : null,
      loadedAt: phase == ModelRuntimePhase.loaded ? now : null,
      reported: true,
    );
  }

  void _applyEvent(
    Map<String, ModelRuntime> models,
    LlamaCppModelsSseEvent event,
  ) {
    final now = DateTime.now().toUtc();
    if (event is LlamaCppModelsDownloadProgressEvent) {
      final key = llamaCppDescriptor.globalModelId(event.model);
      final current = models[key];
      models[key] = ModelRuntime(
        modelId: key,
        phase: ModelRuntimePhase.downloading,
        progress: _downloadProgress(event.progress),
        updatedAt: now,
        startedAt: current?.phase == ModelRuntimePhase.downloading
            ? current?.startedAt
            : now,
        reported: true,
      );
      return;
    }
    if (event is! LlamaCppModelsModelStatusEvent) return;
    final key = llamaCppDescriptor.globalModelId(event.model);
    final current = models[key];
    final status = event.status;
    final raw = event.rawStatus;
    final loaded = status == LlamaCppModelStatusValue.loaded;
    final loading = status == LlamaCppModelStatusValue.loading;
    final failed =
        event.data?['failed'] == true ||
        (status == LlamaCppModelStatusValue.unloaded &&
            event.data?['exit_code'] != null);
    final phase = switch (status) {
      LlamaCppModelStatusValue.unloaded =>
        failed ? ModelRuntimePhase.failed : ModelRuntimePhase.unloaded,
      LlamaCppModelStatusValue.loading => ModelRuntimePhase.loading,
      LlamaCppModelStatusValue.loaded => ModelRuntimePhase.loaded,
      LlamaCppModelStatusValue.sleeping => ModelRuntimePhase.sleeping,
      LlamaCppModelStatusValue.downloading => ModelRuntimePhase.downloading,
      null when raw == 'incomplete' => ModelRuntimePhase.incomplete,
      null => ModelRuntimePhase.unknown,
    };
    final progress = loading
        ? _loadProgress(event.loadProgress, current?.progress)
        : null;
    models[key] = ModelRuntime(
      modelId: key,
      phase: phase,
      progress: progress,
      error: phase == ModelRuntimePhase.failed
          ? _failedMessage(_intOf(event.data?['exit_code']))
          : null,
      updatedAt: now,
      startedAt: loading
          ? (current?.phase == ModelRuntimePhase.loading
                ? current?.startedAt
                : now)
          : null,
      loadedAt: loaded ? now : null,
      reported: true,
    );
  }

  ModelLoadProgress? _loadProgress(
    LlamaCppModelLoadProgress? progress,
    ModelLoadProgress? previous,
  ) {
    if (progress == null) return previous;
    final value = progress.value;
    if (value == null) return previous;
    final stages = progress.stages ?? const <String>[];
    final current = progress.current;
    final index = current == null ? -1 : stages.indexOf(current);
    final fraction = index >= 0 && stages.isNotEmpty
        ? ((index + value.clamp(0, 1)) / stages.length).clamp(0, 1).toDouble()
        : value.clamp(0, 1).toDouble();
    // Прогресс не должен откатываться во время одной загрузки: разные этапы
    // могут присылать value независимо.
    final next = previous?.fraction != null && fraction < previous!.fraction!
        ? previous.fraction
        : fraction;
    return ModelLoadProgress(
      fraction: next,
      stage: _stageOf(current),
      stageIndex: index >= 0 ? index : null,
      stageCount: stages.isEmpty ? null : stages.length,
    );
  }

  ModelLoadProgress? _downloadProgress(
    Map<String, LlamaCppModelDownloadProgress>? progress,
  ) {
    if (progress == null || progress.isEmpty) return null;
    var done = 0;
    var total = 0;
    for (final file in progress.values) {
      done += file.done ?? 0;
      total += file.total ?? 0;
    }
    return ModelLoadProgress(
      fraction: total > 0 ? (done / total).clamp(0, 1) : null,
    );
  }

  ModelLoadStage _stageOf(String? stage) => switch (stage) {
    'text_model' => ModelLoadStage.weights,
    'mmproj_model' => ModelLoadStage.projector,
    'spec_model' => ModelLoadStage.draft,
    _ => ModelLoadStage.other,
  };

  String? _failedMessage(int? exitCode) =>
      exitCode == null ? null : 'exit code $exitCode';

  int? _intOf(Object? value) => value is int
      ? value
      : value is num
      ? value.toInt()
      : int.tryParse('$value');

  ProviderRuntimeState _routerState(
    Map<String, ModelRuntime> models,
    ModelRuntimeCapabilities capabilities,
  ) => ProviderRuntimeState(
    providerId: llamaCppProviderId,
    capabilities: capabilities,
    models: Map.unmodifiable(models),
    updatedAt: DateTime.now().toUtc(),
  );

  LlmFailure _networkFailure(Object error) {
    if (error is LlmFailure) return error;
    return LlmFailure('llama.cpp runtime error: $error', retryable: true);
  }
}

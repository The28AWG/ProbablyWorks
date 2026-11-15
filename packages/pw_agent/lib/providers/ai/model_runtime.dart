/// Универсальное наблюдение за состоянием моделей у LLM-провайдеров.
///
/// Каталог моделей отвечает на вопрос «какие модели существуют», а этот слой —
/// «что с моделью сейчас»: загружена ли она в память, идёт ли загрузка, можно ли
/// ей управлять. Состояние эфемерно: в БД оно не пишется и после перезапуска
/// запрашивается у провайдера заново.
///
/// Провайдеры, которые ничего не сообщают (например, OpenRouter), просто не
/// реализуют [LlmModelRuntimeProvider]. UI в этом случае не показывает runtime
/// и работает как раньше.
library;

import 'package:equatable/equatable.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';

/// Фаза жизни модели в памяти провайдера.
enum ModelRuntimePhase {
  /// Провайдер ещё не ответил или состояние неизвестно.
  unknown,

  /// Модель не загружена и загрузится по запросу (если провайдер это умеет).
  unloaded,

  /// Модель загружается в память.
  loading,

  /// Модель готова принимать запросы.
  loaded,

  /// Модель выгружается.
  unloading,

  /// Модель спит: память освобождена, но состояние экземпляра сохранено.
  sleeping,

  /// Скачиваются файлы модели (это не загрузка в память).
  downloading,

  /// Скачивание было прервано и может быть продолжено.
  incomplete,

  /// Последняя попытка загрузки завершилась ошибкой.
  failed,
}

/// Этап загрузки в памяти, приведённый к общему словарю.
///
/// llama.cpp сообщает технические имена (`text_model`, `mmproj_model`,
/// `spec_model`), но UI не должен знать их. Неизвестные этапы попадают в
/// [other] и не мешают показывать общий прогресс.
enum ModelLoadStage { weights, projector, draft, other }

/// Прогресс одного действия: загрузки, выгрузки или скачивания.
class ModelLoadProgress extends Equatable {
  const ModelLoadProgress({
    this.fraction,
    this.stage,
    this.stageIndex,
    this.stageCount,
  });

  /// Общая доля от 0 до 1. Null — провайдер не сообщил числовой прогресс.
  final double? fraction;

  /// Текущий этап; null — провайдер не делит загрузку на этапы.
  final ModelLoadStage? stage;
  final int? stageIndex;
  final int? stageCount;

  ModelLoadProgress copyWith({
    double? fraction,
    ModelLoadStage? stage,
    int? stageIndex,
    int? stageCount,
    bool clearFraction = false,
  }) => ModelLoadProgress(
    fraction: clearFraction ? null : (fraction ?? this.fraction),
    stage: stage ?? this.stage,
    stageIndex: stageIndex ?? this.stageIndex,
    stageCount: stageCount ?? this.stageCount,
  );

  Map<String, Object?> toJson() => {
    'fraction': fraction,
    'stage': stage?.name,
    'stageIndex': stageIndex,
    'stageCount': stageCount,
  };

  static ModelLoadProgress? fromJson(Object? json) {
    if (json is! Map) return null;
    final value = json['fraction'];
    return ModelLoadProgress(
      fraction: value is num ? value.toDouble() : null,
      stage: _enumByName(ModelLoadStage.values, json['stage']),
      stageIndex: json['stageIndex'] is int ? json['stageIndex'] as int : null,
      stageCount: json['stageCount'] is int ? json['stageCount'] as int : null,
    );
  }

  @override
  List<Object?> get props => [fraction, stage, stageIndex, stageCount];
}

/// Что провайдер умеет в отношении runtime.
class ModelRuntimeCapabilities extends Equatable {
  const ModelRuntimeCapabilities({
    this.reportsState = false,
    this.reportsProgress = false,
    this.canLoad = false,
    this.canUnload = false,
    this.canSleep = false,
  });

  factory ModelRuntimeCapabilities.fromJson(Object? json) {
    if (json is! Map) return none;
    return ModelRuntimeCapabilities(
      reportsState: json['reportsState'] == true,
      reportsProgress: json['reportsProgress'] == true,
      canLoad: json['canLoad'] == true,
      canUnload: json['canUnload'] == true,
      canSleep: json['canSleep'] == true,
    );
  }

  /// Провайдер сообщает, загружена ли модель.
  final bool reportsState;

  /// Провайдер сообщает числовой прогресс загрузки.
  final bool reportsProgress;

  /// Модель можно загрузить принудительно.
  final bool canLoad;

  /// Модель можно выгрузить принудительно.
  final bool canUnload;

  /// Модель можно усыпить/разбудить (например, vLLM sleep mode).
  final bool canSleep;

  bool get isSupported =>
      reportsState || reportsProgress || canLoad || canUnload || canSleep;

  static const none = ModelRuntimeCapabilities();

  static const full = ModelRuntimeCapabilities(
    reportsState: true,
    reportsProgress: true,
    canLoad: true,
    canUnload: true,
  );

  Map<String, Object?> toJson() => {
    'reportsState': reportsState,
    'reportsProgress': reportsProgress,
    'canLoad': canLoad,
    'canUnload': canUnload,
    'canSleep': canSleep,
  };

  @override
  List<Object?> get props => [
    reportsState,
    reportsProgress,
    canLoad,
    canUnload,
    canSleep,
  ];
}

/// Состояние одной модели у одного провайдера.
class ModelRuntime extends Equatable {
  const ModelRuntime({
    required this.modelId,
    required this.phase,
    this.progress,
    this.error,
    this.updatedAt,
    this.startedAt,
    this.loadedAt,
    this.expiresAt,
    this.reported = true,
  });

  factory ModelRuntime.fromJson(Map<String, dynamic> json) => ModelRuntime(
    modelId: '${json['modelId'] ?? ''}',
    phase:
        _enumByName(ModelRuntimePhase.values, json['phase']) ??
        ModelRuntimePhase.unknown,
    progress: ModelLoadProgress.fromJson(json['progress']),
    error: json['error'] as String?,
    updatedAt: _date(json['updatedAt']),
    startedAt: _date(json['startedAt']),
    loadedAt: _date(json['loadedAt']),
    expiresAt: _date(json['expiresAt']),
    reported: json['reported'] != false,
  );

  /// Глобальный id модели (с префиксом провайдера).
  final String modelId;
  final ModelRuntimePhase phase;

  /// Прогресс текущего переходного состояния. Null — индикатор без процента.
  final ModelLoadProgress? progress;

  /// Причина последней ошибки; секреты вырезаны адаптером.
  final String? error;

  /// Время последнего обновления записи.
  final DateTime? updatedAt;

  /// Когда началось текущее переходное состояние. Нужен для дебаунса баннера.
  final DateTime? startedAt;

  /// Когда модель стала доступна. Null — не загружена.
  final DateTime? loadedAt;

  /// Когда провайдер сам выгрузит модель (например, Ollama `keep_alive`).
  final DateTime? expiresAt;

  /// true — состояние сообщил провайдер; false — выведено по запросу.
  final bool reported;

  bool get isTransitional =>
      phase == ModelRuntimePhase.loading ||
      phase == ModelRuntimePhase.unloading ||
      phase == ModelRuntimePhase.downloading;

  ModelRuntime copyWith({
    String? modelId,
    ModelRuntimePhase? phase,
    ModelLoadProgress? progress,
    String? error,
    DateTime? updatedAt,
    DateTime? startedAt,
    DateTime? loadedAt,
    DateTime? expiresAt,
    bool? reported,
    bool clearProgress = false,
    bool clearError = false,
    bool clearStartedAt = false,
    bool clearLoadedAt = false,
    bool clearExpiresAt = false,
  }) => ModelRuntime(
    modelId: modelId ?? this.modelId,
    phase: phase ?? this.phase,
    progress: clearProgress ? null : (progress ?? this.progress),
    error: clearError ? null : (error ?? this.error),
    updatedAt: updatedAt ?? this.updatedAt,
    startedAt: clearStartedAt ? null : (startedAt ?? this.startedAt),
    loadedAt: clearLoadedAt ? null : (loadedAt ?? this.loadedAt),
    expiresAt: clearExpiresAt ? null : (expiresAt ?? this.expiresAt),
    reported: reported ?? this.reported,
  );

  Map<String, Object?> toJson() => {
    'modelId': modelId,
    'phase': phase.name,
    'progress': progress?.toJson(),
    'error': error,
    'updatedAt': updatedAt?.toUtc().toIso8601String(),
    'startedAt': startedAt?.toUtc().toIso8601String(),
    'loadedAt': loadedAt?.toUtc().toIso8601String(),
    'expiresAt': expiresAt?.toUtc().toIso8601String(),
    'reported': reported,
  };

  @override
  List<Object?> get props => [
    modelId,
    phase,
    progress,
    error,
    updatedAt,
    startedAt,
    loadedAt,
    expiresAt,
    reported,
  ];
}

/// Runtime одного провайдера: возможности и модели.
class ProviderRuntimeState extends Equatable {
  const ProviderRuntimeState({
    required this.providerId,
    this.capabilities = ModelRuntimeCapabilities.none,
    this.models = const {},
    this.error,
    this.updatedAt,
  });

  factory ProviderRuntimeState.fromJson(Map<String, dynamic> json) =>
      ProviderRuntimeState(
        providerId: '${json['providerId'] ?? ''}',
        capabilities: ModelRuntimeCapabilities.fromJson(json['capabilities']),
        models: {
          for (final entry in (json['models'] as Map? ?? const {}).entries)
            '${entry.key}': ModelRuntime.fromJson(
              Map<String, dynamic>.from(entry.value as Map),
            ),
        },
        error: json['error'] as String?,
        updatedAt: _date(json['updatedAt']),
      );

  final String providerId;
  final ModelRuntimeCapabilities capabilities;

  /// Модели провайдера по глобальному id.
  final Map<String, ModelRuntime> models;

  /// Ошибка наблюдения (сервер не отвечает, SSE недоступен). Не путать с
  /// ошибкой загрузки конкретной модели в [ModelRuntime.error].
  final String? error;
  final DateTime? updatedAt;

  ProviderRuntimeState copyWith({
    String? providerId,
    ModelRuntimeCapabilities? capabilities,
    Map<String, ModelRuntime>? models,
    String? error,
    DateTime? updatedAt,
    bool clearError = false,
  }) => ProviderRuntimeState(
    providerId: providerId ?? this.providerId,
    capabilities: capabilities ?? this.capabilities,
    models: models ?? this.models,
    error: clearError ? null : (error ?? this.error),
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, Object?> toJson() => {
    'providerId': providerId,
    'capabilities': capabilities.toJson(),
    'models': {
      for (final entry in models.entries) entry.key: entry.value.toJson(),
    },
    'error': error,
    'updatedAt': updatedAt?.toUtc().toIso8601String(),
  };

  @override
  List<Object?> get props => [
    providerId,
    capabilities,
    models,
    error,
    updatedAt,
  ];
}

/// Снимок runtime всех провайдеров.
class ModelRuntimeState extends Equatable {
  const ModelRuntimeState({this.providers = const {}});

  factory ModelRuntimeState.fromJson(Object? json) {
    if (json is! Map) return const ModelRuntimeState();
    return ModelRuntimeState(
      providers: {
        for (final entry in (json['providers'] as Map? ?? const {}).entries)
          '${entry.key}': ProviderRuntimeState.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          ),
      },
    );
  }

  /// Состояния провайдеров по id.
  final Map<String, ProviderRuntimeState> providers;

  Iterable<ModelRuntime> get allModels sync* {
    for (final provider in providers.values) {
      yield* provider.models.values;
    }
  }

  ModelRuntime? modelOf(String? modelId) {
    if (modelId == null || modelId.isEmpty) return null;
    for (final provider in providers.values) {
      final model = provider.models[modelId];
      if (model != null) return model;
    }
    return null;
  }

  ModelRuntimeCapabilities? capabilitiesOf(String? providerId) =>
      providerId == null ? null : providers[providerId]?.capabilities;

  List<ModelRuntime> modelsOfProvider(String providerId) =>
      providers[providerId]?.models.values.toList(growable: false) ?? const [];

  bool get hasTransitional => allModels.any((model) => model.isTransitional);

  bool get isEmpty => providers.isEmpty;

  Map<String, Object?> toJson() => {
    'providers': {
      for (final entry in providers.entries) entry.key: entry.value.toJson(),
    },
  };

  @override
  List<Object?> get props => [providers];
}

/// Источник runtime для UI. Локально — сервис, удалённо — HTTP/SSE клиент.
abstract interface class ModelRuntimeSource {
  /// Последний известный снимок.
  ModelRuntimeState get runtime;

  /// Текущее состояние и все последующие изменения.
  Stream<ModelRuntimeState> watchRuntime();

  /// Перезапрашивает состояние у провайдеров.
  Future<void> refreshRuntime();

  /// Загружает модель принудительно. Id — глобальный.
  Future<void> loadModel(String modelId);

  /// Выгружает модель принудительно. Id — глобальный.
  Future<void> unloadModel(String modelId);
}

/// Необязательная возможность адаптера LLM-провайдера.
///
/// Если адаптер её не реализует, модель считается «без runtime»: UI не
/// показывает прогресс и не даёт управлять загрузкой.
abstract interface class LlmModelRuntimeProvider implements LlmProvider {
  /// Включён ли провайдер в настройках. Выключенный не опрашивается.
  Future<bool> get runtimeEnabled;

  /// Снимок состояния без подписки.
  Future<ProviderRuntimeState> snapshotRuntime();

  /// Снимок, затем поток изменений. Ошибки пробрасываются наружу: сервис
  /// сам решает, когда переподключаться.
  Stream<ProviderRuntimeState> watchRuntime();

  /// Загрузить модель по локальному id (без префикса провайдера).
  Future<void> loadRuntimeModel(String localModelId);

  /// Выгрузить модель по локальному id (без префикса провайдера).
  Future<void> unloadRuntimeModel(String localModelId);
}

T? _enumByName<T extends Enum>(List<T> values, Object? name) {
  if (name is! String) return null;
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

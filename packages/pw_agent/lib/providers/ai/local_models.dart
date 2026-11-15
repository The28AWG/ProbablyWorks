/// Локальные модели: файлы среды выполнения и их параметры.
///
/// Здесь два разных понятия, которые нельзя смешивать:
///
/// * **модель среды выполнения** — файл (`GGUF`) на диске: его скачивают,
///   импортируют, удаляют и настраивают (контекст, GPU-слои, сэмплирование);
/// * **модель провайдера** — нейросеть из общего каталога (`llamadart:<id>`),
///   которая выполняет работу агента и состояние которой в памяти отдаёт
///   [LlmModelRuntimeProvider].
///
/// Файл может существовать без модели провайдера (например, файл эмбеддингов)
/// и наоборот — провайдер может отдавать модели, файлами которых мы не
/// управляем (llama.cpp server). Поэтому среда выполнения живёт отдельно от
/// провайдера: её можно настраивать и чистить при выключенном провайдере.
library;

import 'package:equatable/equatable.dart';
import 'package:pw_agent/core/util/char_substring.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/model_runtime.dart';

/// Откуда взялся файл модели.
enum LocalModelSourceKind {
  /// Ссылка Hugging Face (`hf://owner/repo/file.gguf`).
  huggingFace,

  /// Прямая HTTP(S)-ссылка.
  url,

  /// Путь на диске, выбранный пользователем.
  path,
}

/// Параметры запуска и генерации одного файла модели.
///
/// Это настройки среды выполнения, а не провайдера: они применяются к файлу
/// и переживают выключение провайдера. Значения по умолчанию рассчитаны на
/// небольшую instruct-модель: контекст 4096, все слои на GPU при наличии,
/// сэмплирование llama.cpp по умолчанию.
class LocalModelSettings extends Equatable {
  const LocalModelSettings({
    this.contextSize = defaultContextSize,
    this.gpuLayers = defaultGpuLayers,
    this.threads = 0,
    this.batchSize = 0,
    this.useMmap = true,
    this.maxTokens = defaultMaxTokens,
    this.temperature = 0.8,
    this.topK = 40,
    this.topP = 0.9,
    this.minP = 0.0,
    this.penalty = 1.1,
    this.presencePenalty = 0.0,
    this.supportsTools = true,
    this.projectorSource,
    this.projectorAudio = false,
    this.thinkingBudget,
    this.stopSequences = const [],
  });

  /// Разбирает JSON из БД или API. Неизвестные поля игнорируются, битые
  /// значения заменяются значениями по умолчанию: настройки не должны
  /// ломать запуск модели.
  factory LocalModelSettings.fromJson(Object? json) {
    if (json is! Map) return const LocalModelSettings();
    int intOf(String key, int fallback) {
      final value = json[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
      return int.tryParse('${value ?? ''}') ?? fallback;
    }

    double doubleOf(String key, double fallback) {
      final value = json[key];
      if (value is num) return value.toDouble();
      return double.tryParse('${value ?? ''}') ?? fallback;
    }

    final stop = json['stopSequences'];
    return LocalModelSettings(
      contextSize: intOf('contextSize', defaultContextSize),
      gpuLayers: intOf('gpuLayers', defaultGpuLayers),
      threads: intOf('threads', 0),
      batchSize: intOf('batchSize', 0),
      useMmap: json['useMmap'] != false,
      maxTokens: intOf('maxTokens', defaultMaxTokens),
      temperature: doubleOf('temperature', 0.8),
      topK: intOf('topK', 40),
      topP: doubleOf('topP', 0.9),
      minP: doubleOf('minP', 0.0),
      penalty: doubleOf('penalty', 1.1),
      presencePenalty: doubleOf('presencePenalty', 0.0),
      supportsTools: json['supportsTools'] != false,
      projectorSource: switch (json['projectorSource']) {
        final String value when value.trim().isNotEmpty => value.trim(),
        _ => null,
      },
      projectorAudio: json['projectorAudio'] == true,
      thinkingBudget: json['thinkingBudget'] == null
          ? null
          : intOf('thinkingBudget', 0),
      stopSequences: stop is List
          ? [
              for (final value in stop)
                if (value is String && value.isNotEmpty) value,
            ]
          : const [],
    );
  }

  /// Контекст по умолчанию: компромисс между памятью и длиной истории.
  static const defaultContextSize = 4096;

  /// Все слои на GPU, как в llama.cpp (`-1`). На CPU-хосте это обычное
  /// значение: рантайм сам оставит модель на CPU, если GPU нет.
  static const defaultGpuLayers = -1;

  static const defaultMaxTokens = 4096;

  /// Размер контекстного окна в токенах.
  final int contextSize;

  /// Сколько слоёв выгружать на GPU. `-1` — все, `0` — только CPU.
  final int gpuLayers;

  /// Число потоков CPU. `0` — выбрать автоматически.
  final int threads;

  /// Размер батча при загрузке. `0` — значение рантайма.
  final int batchSize;

  /// Использовать memory-mapped файл модели: экономит RAM при загрузке.
  final bool useMmap;

  /// Лимит токенов ответа, если агент не задал свой.
  final int maxTokens;
  final double temperature;
  final int topK;
  final double topP;
  final double minP;
  final double penalty;
  final double presencePenalty;

  /// Может ли модель вызывать инструменты. Агент проверяет это до запроса,
  /// поэтому для моделей без шаблона инструментов значение выключают вручную.
  final bool supportsTools;

  /// Мультимодальный проектор (`mmproj.gguf`): путь, `hf://` или HTTP(S).
  ///
  /// Без проектора модель текстовая. С проектором провайдер объявляет
  /// модальность `image`, а llamadart подключает его при загрузке.
  final String? projectorSource;

  /// Умеет ли проектор аудио. По умолчанию только зрение: большинство
  /// `mmproj` — визуальные, а лишняя модальность приводит к ошибке генерации.
  final bool projectorAudio;

  /// Лимит токенов рассуждений. Null — не ограничивать.
  final int? thinkingBudget;

  /// Последовательности остановки. Пусто — только штатные стоп-токены модели.
  final List<String> stopSequences;

  /// Проверяет диапазоны. Возвращает текст ошибки или null.
  String? validate() {
    if (contextSize < 256 || contextSize > 1048576) {
      return 'contextSize must be between 256 and 1048576';
    }
    if (gpuLayers < -1 || gpuLayers > 1000) {
      return 'gpuLayers must be -1 or between 0 and 1000';
    }
    if (threads < 0 || threads > 512) {
      return 'threads must be between 0 and 512';
    }
    if (batchSize < 0 || batchSize > 8192) {
      return 'batchSize must be between 0 and 8192';
    }
    if (maxTokens < 1 || maxTokens > 131072) {
      return 'maxTokens must be between 1 and 131072';
    }
    if (temperature < 0 || temperature > 2) {
      return 'temperature must be between 0 and 2';
    }
    if (topK < 0 || topK > 1000) {
      return 'topK must be between 0 and 1000';
    }
    if (topP < 0 || topP > 1) return 'topP must be between 0 and 1';
    if (minP < 0 || minP > 1) return 'minP must be between 0 and 1';
    if (penalty < 0.5 || penalty > 2) {
      return 'penalty must be between 0.5 and 2';
    }
    if (presencePenalty < -2 || presencePenalty > 2) {
      return 'presencePenalty must be between -2 and 2';
    }
    final budget = thinkingBudget;
    if (budget != null && (budget < 0 || budget > 65536)) {
      return 'thinkingBudget must be between 0 and 65536';
    }
    return null;
  }

  LocalModelSettings copyWith({
    int? contextSize,
    int? gpuLayers,
    int? threads,
    int? batchSize,
    bool? useMmap,
    int? maxTokens,
    double? temperature,
    int? topK,
    double? topP,
    double? minP,
    double? penalty,
    double? presencePenalty,
    bool? supportsTools,
    String? projectorSource,
    bool? projectorAudio,
    bool clearProjector = false,
    int? thinkingBudget,
    bool clearThinkingBudget = false,
    List<String>? stopSequences,
  }) => LocalModelSettings(
    contextSize: contextSize ?? this.contextSize,
    gpuLayers: gpuLayers ?? this.gpuLayers,
    threads: threads ?? this.threads,
    batchSize: batchSize ?? this.batchSize,
    useMmap: useMmap ?? this.useMmap,
    maxTokens: maxTokens ?? this.maxTokens,
    temperature: temperature ?? this.temperature,
    topK: topK ?? this.topK,
    topP: topP ?? this.topP,
    minP: minP ?? this.minP,
    penalty: penalty ?? this.penalty,
    presencePenalty: presencePenalty ?? this.presencePenalty,
    supportsTools: supportsTools ?? this.supportsTools,
    projectorSource: clearProjector
        ? null
        : (projectorSource ?? this.projectorSource),
    projectorAudio: projectorAudio ?? this.projectorAudio,
    thinkingBudget: clearThinkingBudget
        ? null
        : (thinkingBudget ?? this.thinkingBudget),
    stopSequences: stopSequences ?? this.stopSequences,
  );

  Map<String, Object?> toJson() => {
    'contextSize': contextSize,
    'gpuLayers': gpuLayers,
    'threads': threads,
    'batchSize': batchSize,
    'useMmap': useMmap,
    'maxTokens': maxTokens,
    'temperature': temperature,
    'topK': topK,
    'topP': topP,
    'minP': minP,
    'penalty': penalty,
    'presencePenalty': presencePenalty,
    'supportsTools': supportsTools,
    if (projectorSource != null) 'projectorSource': projectorSource,
    if (projectorAudio) 'projectorAudio': projectorAudio,
    if (thinkingBudget != null) 'thinkingBudget': thinkingBudget,
    if (stopSequences.isNotEmpty) 'stopSequences': stopSequences,
  };

  @override
  List<Object?> get props => [
    contextSize,
    gpuLayers,
    threads,
    batchSize,
    useMmap,
    maxTokens,
    temperature,
    topK,
    topP,
    minP,
    penalty,
    presencePenalty,
    supportsTools,
    projectorSource,
    projectorAudio,
    thinkingBudget,
    stopSequences,
  ];
}

/// Файл модели среды выполнения.
///
/// [id] стабилен и не зависит от пути: он выводится из источника, поэтому
/// переезд контейнера приложения на iOS не меняет id модели в чатах.
class LocalModelFile extends Equatable {
  const LocalModelFile({
    required this.id,
    required this.name,
    required this.source,
    required this.sourceKind,
    required this.settings,
    required this.createdAt,
    this.cacheKey,
    this.path,
    this.sizeBytes,
    this.sha256,
    this.available = true,
    this.lastUsedAt,
  });

  /// Разбирает JSON из API/SSE. Битые значения заменяются безопасными.
  factory LocalModelFile.fromJson(Map<String, dynamic> json) {
    final kindName = json['sourceKind'];
    return LocalModelFile(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      source: '${json['source'] ?? ''}',
      sourceKind: kindName is String
          ? LocalModelSourceKind.values.asNameMap()[kindName] ??
                LocalModelSourceKind.path
          : LocalModelSourceKind.path,
      cacheKey: json['cacheKey'] as String?,
      path: json['path'] as String?,
      sizeBytes: json['sizeBytes'] is int ? json['sizeBytes'] as int : null,
      sha256: json['sha256'] as String?,
      available: json['available'] != false,
      settings: LocalModelSettings.fromJson(json['settings']),
      createdAt:
          _dateOf(json['createdAt']) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      lastUsedAt: _dateOf(json['lastUsedAt']),
    );
  }

  /// Короткий стабильный id (первые 16 символов хеша источника).
  final String id;

  /// Человекочитаемое имя. По умолчанию — имя файла без `.gguf`.
  final String name;

  /// Исходная ссылка или путь, как их ввёл пользователь.
  final String source;
  final LocalModelSourceKind sourceKind;

  /// Ключ кэша llamadart. Null — файл импортирован и принадлежит пользователю.
  final String? cacheKey;

  /// Текущий путь к файлу. Null — файл не найден (кэш очистили снаружи).
  final String? path;
  final int? sizeBytes;
  final String? sha256;
  final bool available;
  final LocalModelSettings settings;
  final DateTime createdAt;
  final DateTime? lastUsedAt;

  /// Имя файла для подписи: последний сегмент пути.
  String get fileName {
    final value = path;
    if (value == null || value.isEmpty) return name;
    final index = value.lastIndexOf(RegExp(r'[/\\]'));
    return index < 0 ? value : charFrom(value, index + 1);
  }

  LocalModelFile copyWith({
    String? id,
    String? name,
    String? source,
    LocalModelSourceKind? sourceKind,
    String? cacheKey,
    String? path,
    int? sizeBytes,
    String? sha256,
    bool? available,
    LocalModelSettings? settings,
    DateTime? createdAt,
    DateTime? lastUsedAt,
    bool clearPath = false,
    bool clearCacheKey = false,
    bool clearLastUsedAt = false,
  }) => LocalModelFile(
    id: id ?? this.id,
    name: name ?? this.name,
    source: source ?? this.source,
    sourceKind: sourceKind ?? this.sourceKind,
    cacheKey: clearCacheKey ? null : (cacheKey ?? this.cacheKey),
    path: clearPath ? null : (path ?? this.path),
    sizeBytes: sizeBytes ?? this.sizeBytes,
    sha256: sha256 ?? this.sha256,
    available: available ?? this.available,
    settings: settings ?? this.settings,
    createdAt: createdAt ?? this.createdAt,
    lastUsedAt: clearLastUsedAt ? null : (lastUsedAt ?? this.lastUsedAt),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'source': source,
    'sourceKind': sourceKind.name,
    'cacheKey': cacheKey,
    'path': path,
    'sizeBytes': sizeBytes,
    'sha256': sha256,
    'available': available,
    'settings': settings.toJson(),
    'createdAt': createdAt.toUtc().toIso8601String(),
    'lastUsedAt': lastUsedAt?.toUtc().toIso8601String(),
  };

  @override
  List<Object?> get props => [
    id,
    name,
    source,
    sourceKind,
    cacheKey,
    path,
    sizeBytes,
    sha256,
    available,
    settings,
    createdAt,
    lastUsedAt,
  ];
}

/// Идущее скачивание файла модели.
class LocalModelDownload extends Equatable {
  const LocalModelDownload({
    required this.id,
    required this.name,
    required this.source,
    this.receivedBytes,
    this.totalBytes,
    this.error,
  });

  factory LocalModelDownload.fromJson(Map<String, dynamic> json) =>
      LocalModelDownload(
        id: '${json['id'] ?? ''}',
        name: '${json['name'] ?? ''}',
        source: '${json['source'] ?? ''}',
        receivedBytes: json['receivedBytes'] is int
            ? json['receivedBytes'] as int
            : null,
        totalBytes: json['totalBytes'] is int
            ? json['totalBytes'] as int
            : null,
        error: json['error'] as String?,
      );

  final String id;
  final String name;
  final String source;
  final int? receivedBytes;
  final int? totalBytes;
  final String? error;

  /// Доля 0..1, если известен общий размер.
  double? get fraction {
    final total = totalBytes;
    final received = receivedBytes;
    if (total == null || received == null || total <= 0) return null;
    return (received / total).clamp(0, 1).toDouble();
  }

  LocalModelDownload copyWith({
    String? id,
    String? name,
    String? source,
    int? receivedBytes,
    int? totalBytes,
    String? error,
    bool clearError = false,
  }) => LocalModelDownload(
    id: id ?? this.id,
    name: name ?? this.name,
    source: source ?? this.source,
    receivedBytes: receivedBytes ?? this.receivedBytes,
    totalBytes: totalBytes ?? this.totalBytes,
    error: clearError ? null : (error ?? this.error),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'source': source,
    'receivedBytes': receivedBytes,
    'totalBytes': totalBytes,
    'error': error,
  };

  @override
  List<Object?> get props => [
    id,
    name,
    source,
    receivedBytes,
    totalBytes,
    error,
  ];
}

/// Задание на скачивание, переживающее перезапуск процесса.
///
/// Токены и заголовки здесь не хранятся: ими владеет платформенная задача
/// загрузчика (или Dart-менеджер), а не наша БД.
class LocalModelDownloadJob extends Equatable {
  const LocalModelDownloadJob({
    required this.id,
    required this.source,
    required this.name,
    required this.createdAt,
    this.sha256,
  });

  final String id;
  final String source;
  final String name;
  final String? sha256;
  final DateTime createdAt;

  @override
  List<Object?> get props => [id, source, name, sha256, createdAt];
}

/// Снимок среды выполнения: файлы, скачивания и занятое место.
class LocalModelsState extends Equatable {
  const LocalModelsState({
    this.supported = true,
    this.models = const [],
    this.downloads = const [],
    this.autoUnloadMinutes = 0,
    this.error,
    this.updatedAt,
  });

  /// Разбирает снимок из API/SSE. Неизвестный формат — пустое состояние.
  factory LocalModelsState.fromJson(Object? json) {
    if (json is! Map) return const LocalModelsState();
    final models = json['models'];
    final downloads = json['downloads'];
    return LocalModelsState(
      supported: json['supported'] != false,
      models: models is List
          ? [
              for (final value in models)
                if (value is Map)
                  LocalModelFile.fromJson(Map<String, dynamic>.from(value)),
            ]
          : const [],
      downloads: downloads is List
          ? [
              for (final value in downloads)
                if (value is Map)
                  LocalModelDownload.fromJson(Map<String, dynamic>.from(value)),
            ]
          : const [],
      autoUnloadMinutes: json['autoUnloadMinutes'] is int
          ? json['autoUnloadMinutes'] as int
          : 0,
      error: json['error'] as String?,
      updatedAt: _dateOf(json['updatedAt']),
    );
  }

  /// Поддерживает ли текущий агент локальные модели. false — удалённый
  /// демон старой версии или сборка без llamadart.
  final bool supported;

  /// Установленные файлы, отсортированные по имени.
  final List<LocalModelFile> models;

  /// Активные скачивания.
  final List<LocalModelDownload> downloads;

  /// Через сколько минут простоя выгружать модель из памяти. 0 — никогда.
  final int autoUnloadMinutes;

  /// Ошибка последней операции или наблюдения.
  final String? error;
  final DateTime? updatedAt;

  /// Суммарный размер установленных файлов.
  int get totalBytes =>
      models.fold(0, (sum, model) => sum + (model.sizeBytes ?? 0));

  /// Ищет файл по id.
  LocalModelFile? modelOf(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final model in models) {
      if (model.id == id) return model;
    }
    return null;
  }

  bool get hasDownloads => downloads.isNotEmpty;

  LocalModelsState copyWith({
    bool? supported,
    List<LocalModelFile>? models,
    List<LocalModelDownload>? downloads,
    int? autoUnloadMinutes,
    String? error,
    bool clearError = false,
    DateTime? updatedAt,
  }) => LocalModelsState(
    supported: supported ?? this.supported,
    models: models ?? this.models,
    downloads: downloads ?? this.downloads,
    autoUnloadMinutes: autoUnloadMinutes ?? this.autoUnloadMinutes,
    error: clearError ? null : (error ?? this.error),
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, Object?> toJson() => {
    'supported': supported,
    'models': [for (final model in models) model.toJson()],
    'downloads': [for (final download in downloads) download.toJson()],
    'autoUnloadMinutes': autoUnloadMinutes,
    'error': error,
    'updatedAt': updatedAt?.toUtc().toIso8601String(),
  };

  @override
  List<Object?> get props => [
    supported,
    models,
    downloads,
    autoUnloadMinutes,
    error,
    updatedAt,
  ];
}

/// Управление файлами среды выполнения. Доступно и при выключенном
/// провайдере: скачивание, настройки и очистка не зависят от чата.
abstract interface class LocalModelsSource {
  /// Последний известный снимок.
  LocalModelsState get state;

  /// Снимок и все последующие изменения.
  Stream<LocalModelsState> watch();

  /// Перечитывает список файлов с диска.
  Future<void> refresh();

  /// Запускает скачивание и сразу возвращает id.
  ///
  /// [name] задаёт отображаемое имя, [sha256] — ожидаемую контрольную сумму.
  /// Запрос не висит минуты: прогресс, завершение и ошибки приходят через
  /// [watch]. Локальный путь импортируется без скачивания.
  Future<String> startInstall(String source, {String? name, String? sha256});

  /// Отменяет активное скачивание по id.
  Future<void> cancelInstall(String id);

  /// Добавляет уже лежащий на диске файл, не копируя его.
  Future<String> importPath(String path, {String? name});

  /// Удаляет запись и, для скачанных файлов, сам файл.
  ///
  /// Импортированный пользователем файл никогда не удаляется с диска:
  /// приложение не владеет этим путём.
  Future<void> delete(String id);

  /// Сохраняет параметры файла. Применяются при следующей загрузке в память.
  Future<void> updateSettings(String id, LocalModelSettings settings);

  /// Удаляет все скачанные файлы и записи о них. Импортированные остаются.
  Future<void> clearCache();

  /// Через сколько минут простоя выгружать модель из памяти (0 — никогда).
  Future<void> saveAutoUnload(int minutes);
}

/// Часть среды выполнения, нужная провайдеру: установленные файлы, загрузка
/// в память и генерация.
abstract interface class LocalModelRuntime {
  /// Файлы, которые могут быть моделями провайдера.
  Future<List<LocalModelFile>> installedModels();

  /// Файл по локальному id (без префикса провайдера).
  Future<LocalModelFile?> find(String localModelId);

  /// Запускает генерацию. Файл загружается в память автоматически.
  Stream<LlmEvent> generate(LlmRequest request, {required String localModelId});

  /// Загружает файл в память. Ошибки — [LlmFailure].
  Future<void> loadIntoMemory(String localModelId);

  /// Выгружает файл из памяти. Идемпотентно.
  Future<void> unloadFromMemory(String localModelId);

  /// Состояние памяти всех установленных файлов.
  Future<ProviderRuntimeState> snapshotMemory();

  /// Снимок, затем поток изменений состояния памяти.
  Stream<ProviderRuntimeState> watchMemory();
}

/// Дата из JSON-строки; null, если значение не дата.
DateTime? _dateOf(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

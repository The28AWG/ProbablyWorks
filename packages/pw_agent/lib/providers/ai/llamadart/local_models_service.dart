/// Среда выполнения локальных моделей (llamadart).
///
/// Среда владеет тремя вещами, которые нельзя смешивать:
///
/// * файлами на диске — скачивание, импорт, удаление, занятое место;
/// * параметрами файла — контекст, GPU-слои, сэмплирование;
/// * движком в памяти — одна модель за раз, FIFO-очередь запросов,
///   авто-выгрузка по простою.
///
/// Провайдер `llamadart` читает отсюда список моделей и просит загрузить файл
/// в память; выключение провайдера не мешает управлять файлами.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:pw_agent/core/config/app_paths.dart';
import 'package:pw_agent/core/data/local_model_download_repository.dart';
import 'package:pw_agent/core/data/local_model_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/core/util/cancel_token.dart';
import 'package:pw_agent/core/util/char_substring.dart';
import 'package:pw_agent/core/util/home_path.dart';
import 'package:pw_agent/providers/ai/llamadart/llamadart_connection.dart';
import 'package:pw_agent/providers/ai/llamadart/local_engine.dart';
import 'package:pw_agent/providers/ai/llamadart/local_storage.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/local_models.dart';
import 'package:pw_agent/providers/ai/model_runtime.dart';

/// Активное скачивание: токен отмены и последняя ошибка.
final class _Download {
  _Download({
    required this.id,
    required this.name,
    required this.source,
    required this.token,
  });

  final String id;
  final String name;
  final String source;
  final CancelToken token;

  /// Завершение скачивания: `install` ждёт его, `startInstall` — нет.
  final Completer<void> completer = Completer<void>();

  int? receivedBytes;
  int? totalBytes;
  String? error;

  LocalModelDownload get view => LocalModelDownload(
    id: id,
    name: name,
    source: source,
    receivedBytes: receivedBytes,
    totalBytes: totalBytes,
    error: error,
  );
}

/// Среда выполнения локальных моделей.
final class LocalModelsService implements LocalModelsSource, LocalModelRuntime {
  LocalModelsService(
    this._paths,
    this._repository,
    this._downloadJobs,
    this._settings,
    this._storage, {
    LocalEngine Function()? engineFactory,
    this.keepalive = const Duration(seconds: 20),
  }) : _engineFactory = engineFactory ?? LlamadartLocalEngine.new;

  static final _log = Logger('LocalModels');

  /// Как часто пустой дельтой сбрасывать watchdog агента, пока запрос ждёт
  /// очереди. Меньше `AppLimits.streamWatchdog` (60 с) с запасом.
  final Duration keepalive;

  final AppPaths _paths;
  final LocalModelRepository _repository;
  final LocalModelDownloadRepository _downloadJobs;
  final SettingsRepository _settings;
  final LocalModelStorage _storage;
  final LocalEngine Function() _engineFactory;

  final _changes = StreamController<LocalModelsState>.broadcast();
  final _memoryChanges = StreamController<ProviderRuntimeState>.broadcast();

  LocalModelsState _state = const LocalModelsState();
  final _downloads = <String, _Download>{};
  final _progressAt = <String, DateTime>{};
  final _errors = <String, String>{};
  final _loadProgress = <String, double>{};

  LocalEngine? _engine;
  String? _loadedId;
  LocalModelSettings? _loadedSettings;
  String? _loadingId;
  String? _unloadingId;
  DateTime? _loadedAt;
  Timer? _autoUnloadTimer;
  Timer? _progressTimer;

  Future<void> _lock = Future<void>.value();
  var _started = false;
  Future<void>? _starting;

  @override
  LocalModelsState get state {
    unawaited(_ensureStarted());
    return _state;
  }

  @override
  Stream<LocalModelsState> watch() {
    unawaited(_ensureStarted());
    return Stream.multi((controller) {
      controller.add(_state);
      final sub = _changes.stream.listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
      );
      controller.onCancel = sub.cancel;
    });
  }

  @override
  Future<void> refresh() async {
    await _ensureStarted();
    await _reload();
  }

  /// Запускает чтение состояния один раз. Повторные вызовы безопасны.
  Future<void> _ensureStarted() {
    if (_started) return Future<void>.value();
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<void> _start() async {
    _started = true;
    try {
      await _paths.models.create(recursive: true);
    } on Object catch (error) {
      _log.warning('cannot create models directory', error);
    }
    final minutes =
        int.tryParse(
          await _settings.read(SettingsRepository.keyLocalModelsAutoUnload) ??
              '',
        ) ??
        0;
    _state = _state.copyWith(autoUnloadMinutes: minutes);
    try {
      await _reload();
    } on Object catch (error) {
      _log.warning('cannot load local models', error);
      _state = _state.copyWith(
        error: _messageOf(error),
        updatedAt: DateTime.now().toUtc(),
      );
      _emit();
    }
    await _resumeDownloads();
  }

  /// Подхватывает задания, пережившие перезапуск процесса.
  Future<void> _resumeDownloads() async {
    try {
      for (final job in await _downloadJobs.all()) {
        if (_state.modelOf(job.id) != null) {
          // Модель успели установить, а задание осталось: чистим.
          await _downloadJobs.delete(job.id);
          continue;
        }
        if (_downloads.containsKey(job.id)) continue;
        final download = _Download(
          id: job.id,
          name: job.name,
          source: job.source,
          token: CancelToken(),
        );
        _downloads[job.id] = download;
        _emit();
        unawaited(_runDownload(download, job.sha256));
      }
    } on Object catch (error) {
      _log.warning('cannot resume model downloads', error);
    }
  }

  /// Перечитывает записи БД и сверяет их с файлами кэша.
  Future<void> _reload() async {
    final rows = await _repository.all();
    final cached = <String, LocalModelStorageFile>{};
    String? error;
    try {
      for (final file in await _storage.list()) {
        cached[file.cacheKey] = file;
      }
    } on Object catch (failure) {
      error = _messageOf(failure);
      _log.warning('cannot list model cache', failure);
    }
    final models = <LocalModelFile>[];
    for (final row in rows) {
      models.add(await _resolve(row, cached[row.cacheKey]));
    }
    models.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    _state = _state.copyWith(
      models: models,
      downloads: [for (final item in _downloads.values) item.view],
      error: error,
      clearError: error == null,
      updatedAt: DateTime.now().toUtc(),
    );
    _emit();
    _emitMemory();
  }

  /// Дополняет запись актуальным путём и размером.
  Future<LocalModelFile> _resolve(
    LocalModelFile row,
    LocalModelStorageFile? cached,
  ) async {
    final key = row.cacheKey;
    if (key != null) {
      if (cached == null) {
        return row.copyWith(available: false, clearPath: true);
      }
      return row.copyWith(
        path: cached.path,
        sizeBytes: cached.sizeBytes ?? row.sizeBytes,
        sha256: cached.sha256 ?? row.sha256,
        available: true,
      );
    }
    final file = File(expandHomePath(row.source));
    if (!file.existsSync()) {
      return row.copyWith(available: false, clearPath: true);
    }
    final stat = file.statSync();
    return row.copyWith(path: file.path, sizeBytes: stat.size, available: true);
  }

  /// Скачивает файл и ждёт завершения. Тесты и CLI; UI использует
  /// [startInstall] и следит за прогрессом через [watch].
  Future<String> install(String source, {String? name, String? sha256}) async {
    final trimmed = source.trim();
    if (_kindOf(trimmed) == LocalModelSourceKind.path) {
      return importPath(expandHomePath(trimmed), name: name);
    }
    final download = await _startDownload(trimmed, name: name, sha256: sha256);
    await download.completer.future;
    final error = download.error;
    if (error != null) throw LlmFailure(error);
    return download.id;
  }

  @override
  Future<String> startInstall(
    String source, {
    String? name,
    String? sha256,
  }) async {
    final trimmed = source.trim();
    if (_kindOf(trimmed) == LocalModelSourceKind.path) {
      return importPath(expandHomePath(trimmed), name: name);
    }
    final download = await _startDownload(trimmed, name: name, sha256: sha256);
    return download.id;
  }

  /// Регистрирует скачивание и запускает его в фоне.
  ///
  /// HTTP-запрос установки не должен висеть минуты: сервер отвечает id сразу,
  /// а прогресс и ошибки уходят подписчикам через [watch].
  Future<_Download> _startDownload(
    String source, {
    String? name,
    String? sha256,
  }) async {
    await _ensureStarted();
    if (source.isEmpty) throw const LlmFailure('Model source is empty');
    final id = _idOf(source);
    if (_state.modelOf(id) != null || _downloads.containsKey(id)) {
      throw const LlmFailure('This model is already installed');
    }
    final download = _Download(
      id: id,
      name: _displayName(name, source),
      source: source,
      token: CancelToken(),
    );
    _downloads[id] = download;
    await _downloadJobs.upsert(
      LocalModelDownloadJob(
        id: id,
        source: source,
        name: download.name,
        sha256: sha256,
        createdAt: DateTime.now().toUtc(),
      ),
    );
    _emit();
    unawaited(_runDownload(download, sha256));
    return download;
  }

  /// Скачивает файл и обновляет снимок. Ошибка остаётся в состоянии, чтобы
  /// её увидели и локальный клиент, и подписчик SSE.
  Future<void> _runDownload(_Download download, String? sha256) async {
    final id = download.id;
    try {
      final file = await _storage.ensure(
        download.source,
        key: id,
        displayName: download.name,
        sha256: sha256,
        cancel: download.token,
        onProgress: (received, total) => _onProgress(id, received, total),
      );
      final model = LocalModelFile(
        id: id,
        name: download.name,
        source: download.source,
        sourceKind: _kindOf(download.source),
        cacheKey: file.cacheKey,
        path: file.path,
        sizeBytes: file.sizeBytes,
        sha256: file.sha256,
        settings: const LocalModelSettings(),
        createdAt: DateTime.now().toUtc(),
      );
      await _repository.upsert(file: model);
      _downloads.remove(id);
      _progressAt.remove(id);
      await _reload();
    } on Object catch (error) {
      _downloads.remove(id);
      _progressAt.remove(id);
      if (!download.token.isCancelled) {
        download.error = _messageOf(error);
        _state = _state.copyWith(
          error: download.error,
          updatedAt: DateTime.now().toUtc(),
        );
      }
      _emit();
    } finally {
      try {
        await _downloadJobs.delete(id);
      } on Object catch (error) {
        _log.warning('cannot delete download job $id', error);
      }
      if (!download.completer.isCompleted) download.completer.complete();
    }
  }

  /// Обновляет прогресс не чаще раза в 150 мс: скачивание шлёт байты часто,
  /// а перерисовывать список на каждый чанк незачем.
  void _onProgress(String id, int? received, int? total) {
    final download = _downloads[id];
    if (download == null) return;
    download
      ..receivedBytes = received
      ..totalBytes = total;
    final now = DateTime.now();
    final previous = _progressAt[id];
    if (previous != null &&
        now.difference(previous) < const Duration(milliseconds: 150)) {
      _progressTimer ??= Timer(const Duration(milliseconds: 150), () {
        _progressTimer = null;
        _emit();
      });
      return;
    }
    _progressAt[id] = now;
    _emit();
  }

  @override
  Future<void> cancelInstall(String id) async {
    _downloads[id]?.token.cancel();
  }

  @override
  Future<String> importPath(String path, {String? name}) async {
    await _ensureStarted();
    final file = File(expandHomePath(path.trim()));
    if (!file.existsSync()) {
      throw LlmFailure('Model file not found: ${file.path}');
    }
    final id = _idOf('path:${file.path}');
    if (_state.modelOf(id) != null) {
      throw const LlmFailure('This model is already installed');
    }
    final stat = file.statSync();
    final model = LocalModelFile(
      id: id,
      name: _displayName(name, file.path),
      source: file.path,
      sourceKind: LocalModelSourceKind.path,
      path: file.path,
      sizeBytes: stat.size,
      settings: const LocalModelSettings(),
      createdAt: DateTime.now().toUtc(),
    );
    await _repository.upsert(file: model);
    await _reload();
    return id;
  }

  @override
  Future<void> delete(String id) async {
    await _ensureStarted();
    final model = _state.modelOf(id);
    if (model == null) throw LlmFailure('Unknown model file: $id');
    await _exclusive(() async {
      if (_loadedId == id) await _unloadLocked();
      final key = model.cacheKey;
      if (key != null) await _storage.remove(key);
      await _downloadJobs.delete(id);
      await _repository.delete(id);
      _errors.remove(id);
    });
    await _reload();
  }

  @override
  Future<void> updateSettings(String id, LocalModelSettings settings) async {
    await _ensureStarted();
    final error = settings.validate();
    if (error != null) throw LlmFailure('Model settings are invalid: $error');
    if (_state.modelOf(id) == null) {
      throw LlmFailure('Unknown model file: $id');
    }
    await _repository.saveSettings(id, settings);
    _state = _state.copyWith(
      models: [
        for (final model in _state.models)
          model.id == id ? model.copyWith(settings: settings) : model,
      ],
      updatedAt: DateTime.now().toUtc(),
    );
    // Параметры загрузки нельзя применить на ходу: выгружаем модель, чтобы
    // следующий запрос загрузил её уже с новыми значениями.
    if (_loadedId == id) {
      await _exclusive(() async {
        if (_loadedId == id) await _unloadLocked();
      });
    }
    _emit();
    _emitMemory();
  }

  @override
  Future<void> clearCache() async {
    await _ensureStarted();
    await _exclusive(() async {
      for (final download in _downloads.values) {
        download.token.cancel();
      }
      _downloads.clear();
      await _downloadJobs.deleteAll();
      if (_loadedId case final id? when _state.modelOf(id)?.cacheKey != null) {
        await _unloadLocked();
      }
      await _storage.clear();
      await _repository.deleteCacheBacked();
    });
    await _reload();
  }

  @override
  Future<void> saveAutoUnload(int minutes) async {
    await _ensureStarted();
    final value = minutes < 0 ? 0 : minutes;
    await _settings.write(
      SettingsRepository.keyLocalModelsAutoUnload,
      '$value',
    );
    _state = _state.copyWith(autoUnloadMinutes: value);
    _emit();
    _scheduleAutoUnload();
  }

  @override
  Future<List<LocalModelFile>> installedModels() async {
    await _ensureStarted();
    return [
      for (final model in _state.models)
        if (model.available) model,
    ];
  }

  @override
  Future<LocalModelFile?> find(String localModelId) async {
    await _ensureStarted();
    return _state.modelOf(localModelId);
  }

  @override
  Stream<LlmEvent> generate(
    LlmRequest request, {
    required String localModelId,
  }) {
    final job = _GenerationJob(localModelId);
    late final StreamController<LlmEvent> controller;
    Timer? timer;
    var closed = false;

    Future<void> run() async {
      try {
        await _exclusive(() async {
          job.started = true;
          if (job.cancelled) return;
          await _loadLocked(localModelId);
          if (job.cancelled) return;
          final model = _state.modelOf(localModelId);
          if (model == null) {
            throw const LlmFailure(
              'Model file is missing',
              modelNotFound: true,
            );
          }
          job.generating = true;
          timer?.cancel();
          await for (final event in _engineOrCreate().generate(
            request,
            model.settings,
          )) {
            if (job.cancelled) break;
            if (!closed) controller.add(event);
          }
        });
      } on Object catch (error, stack) {
        if (!job.cancelled && !closed) {
          controller.addError(_failureOf(error), stack);
        }
      } finally {
        timer?.cancel();
        job.finished = true;
        if (!closed) await controller.close();
        unawaited(_touch(localModelId));
        _scheduleAutoUnload();
      }
    }

    controller = StreamController<LlmEvent>(
      onListen: () {
        timer = Timer.periodic(keepalive, (_) {
          if (!job.generating && !closed) {
            // Пустая дельта — сигнал «запрос жив, но ждёт очереди»:
            // агент сбрасывает на ней watchdog.
            controller.add(const LlmTextDelta(''));
          }
        });
        unawaited(run());
      },
      onCancel: () {
        job.cancelled = true;
        closed = true;
        timer?.cancel();
        if (job.generating && !job.finished) unawaited(_engine?.cancel());
      },
    );
    return controller.stream;
  }

  @override
  Future<void> loadIntoMemory(String localModelId) async {
    await _ensureStarted();
    await _exclusive(() => _loadLocked(localModelId));
    _scheduleAutoUnload();
  }

  @override
  Future<void> unloadFromMemory(String localModelId) async {
    await _ensureStarted();
    await _exclusive(() async {
      if (_loadedId == localModelId) await _unloadLocked();
    });
  }

  @override
  Future<ProviderRuntimeState> snapshotMemory() async {
    await _ensureStarted();
    return _memoryState();
  }

  @override
  Stream<ProviderRuntimeState> watchMemory() {
    unawaited(_ensureStarted());
    return Stream.multi((controller) {
      controller.add(_memoryState());
      final sub = _memoryChanges.stream.listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
      );
      controller.onCancel = sub.cancel;
    });
  }

  /// Освобождает движок при остановке процесса. Без этого на macOS Metal
  /// ggml аварийно завершает процесс с загруженной моделью.
  Future<void> shutdown() async {
    _autoUnloadTimer?.cancel();
    _progressTimer?.cancel();
    final engine = _engine;
    _engine = null;
    _loadedId = null;
    _loadedSettings = null;
    _loadingId = null;
    _unloadingId = null;
    if (engine != null) {
      try {
        await engine.dispose();
      } on Object catch (error) {
        _log.warning('cannot dispose local engine', error);
      }
    }
    await _changes.close();
    await _memoryChanges.close();
  }

  /// Загружает файл в память. Вызывается только под [_lock].
  Future<void> _loadLocked(String localModelId) async {
    final model = _state.modelOf(localModelId);
    if (model == null) {
      throw LlmFailure(
        'Model $localModelId is not installed',
        modelNotFound: true,
      );
    }
    final path = model.path;
    if (!model.available || path == null) {
      throw LlmFailure(
        'Model file is missing: ${model.name}',
        modelNotFound: true,
      );
    }
    if (_loadedId == localModelId && _loadedSettings == model.settings) return;
    _loadingId = localModelId;
    _errors.remove(localModelId);
    _emitMemory();
    try {
      final projectorPath = await _resolveProjector(localModelId, model);
      await _engineOrCreate().load(
        path: path,
        settings: model.settings,
        projectorPath: projectorPath,
      );
      _loadedId = localModelId;
      _loadedSettings = model.settings;
      _loadedAt = DateTime.now().toUtc();
    } on Object catch (error) {
      _errors[localModelId] = _messageOf(error);
      rethrow;
    } finally {
      _loadingId = null;
      _loadProgress.remove(localModelId);
      _emitMemory();
    }
  }

  /// Скачивает проектор, если он задан, и возвращает локальный путь.
  Future<String?> _resolveProjector(
    String localModelId,
    LocalModelFile model,
  ) async {
    final source = model.settings.projectorSource;
    if (source == null || source.isEmpty) return null;
    final resolved = _kindOf(source) == LocalModelSourceKind.path
        ? expandHomePath(source)
        : source;
    try {
      final entry = await _storage.ensure(
        resolved,
        key: '$localModelId-projector',
        displayName: '${model.name} (mmproj)',
        onProgress: (received, total) {
          if (received == null || total == null || total <= 0) return;
          _loadProgress[localModelId] = (received / total)
              .clamp(0, 1)
              .toDouble();
          _emitMemory();
        },
      );
      return entry.path;
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(
        LlmFailure('Model projector failed: ${_messageOf(error)}'),
        stack,
      );
    }
  }

  /// Выгружает текущую модель. Вызывается только под [_lock].
  Future<void> _unloadLocked() async {
    final id = _loadedId;
    if (id == null) return;
    _unloadingId = id;
    _emitMemory();
    try {
      await _engineOrCreate().unload();
      _loadedId = null;
      _loadedSettings = null;
      _loadedAt = null;
    } on Object catch (error) {
      _errors[id] = _messageOf(error);
      rethrow;
    } finally {
      _unloadingId = null;
      _emitMemory();
    }
  }

  LocalEngine _engineOrCreate() => _engine ??= _engineFactory();

  /// Выполняет действие, не пересекаясь с генерацией и другой загрузкой.
  ///
  /// Очередь FIFO: `then` на цепочке фьючеров вызывается в порядке подписки.
  Future<T> _exclusive<T>(Future<T> Function() action) async {
    final previous = _lock;
    final done = Completer<void>();
    _lock = done.future;
    await previous;
    try {
      return await action();
    } finally {
      done.complete();
    }
  }

  Future<void> _touch(String id) async {
    final at = DateTime.now().toUtc();
    try {
      await _repository.touch(id, at);
      _state = _state.copyWith(
        models: [
          for (final model in _state.models)
            model.id == id ? model.copyWith(lastUsedAt: at) : model,
        ],
      );
      _emit();
    } on Object catch (error) {
      _log.warning('cannot update last use for $id', error);
    }
  }

  void _scheduleAutoUnload() {
    _autoUnloadTimer?.cancel();
    final minutes = _state.autoUnloadMinutes;
    if (minutes <= 0) return;
    _autoUnloadTimer = Timer(Duration(minutes: minutes), () {
      if (_loadedId == null) return;
      unawaited(
        _exclusive(() async {
          if (_loadedId != null) await _unloadLocked();
        }).catchError((Object error) {
          _log.warning('auto-unload failed', error);
        }),
      );
    });
  }

  ProviderRuntimeState _memoryState() {
    final now = DateTime.now().toUtc();
    return ProviderRuntimeState(
      providerId: llamadartProviderId,
      capabilities: const ModelRuntimeCapabilities(
        reportsState: true,
        reportsProgress: true,
        canLoad: true,
        canUnload: true,
      ),
      models: {
        for (final model in _state.models)
          llamadartDescriptor.globalModelId(model.id): ModelRuntime(
            modelId: llamadartDescriptor.globalModelId(model.id),
            phase: _phaseOf(model.id),
            progress: _loadProgress[model.id] == null
                ? null
                : ModelLoadProgress(fraction: _loadProgress[model.id]),
            error: _errors[model.id],
            updatedAt: now,
            loadedAt: _loadedId == model.id ? _loadedAt : null,
          ),
      },
      updatedAt: now,
    );
  }

  ModelRuntimePhase _phaseOf(String id) {
    if (_loadedId == id) return ModelRuntimePhase.loaded;
    if (_loadingId == id) return ModelRuntimePhase.loading;
    if (_unloadingId == id) return ModelRuntimePhase.unloading;
    if (_errors[id] != null) return ModelRuntimePhase.failed;
    return ModelRuntimePhase.unloaded;
  }

  void _emit() {
    if (_changes.isClosed) return;
    // Снимок всегда собирается из живых скачиваний: установка и прогресс
    // меняют `_downloads`, а не `_state`, и без этого наружу уходил старый
    // список — карточка появлялась только после переоткрытия раздела.
    _state = _state.copyWith(
      downloads: [for (final item in _downloads.values) item.view],
      updatedAt: DateTime.now().toUtc(),
    );
    _changes.add(_state);
  }

  void _emitMemory() {
    if (!_memoryChanges.isClosed) _memoryChanges.add(_memoryState());
  }

  /// Стабильный id файла: 16 символов SHA-256 источника.
  static String _idOf(String source) =>
      charPrefix(sha256.convert(utf8.encode(source)).toString(), 16);

  static LocalModelSourceKind _kindOf(String source) {
    if (source.startsWith('hf://')) return LocalModelSourceKind.huggingFace;
    final uri = Uri.tryParse(source);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      return LocalModelSourceKind.url;
    }
    return LocalModelSourceKind.path;
  }

  /// Имя модели: заданное пользователем, иначе имя файла без `.gguf`.
  static String _displayName(String? name, String source) {
    final explicit = name?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final kind = _kindOf(source);
    final uri = Uri.tryParse(source);
    final segment = kind == LocalModelSourceKind.path
        ? p.basename(source)
        : uri == null || uri.pathSegments.isEmpty
        ? source
        : uri.pathSegments.last;
    final decoded = Uri.decodeComponent(segment);
    final lower = decoded.toLowerCase();
    return lower.endsWith('.gguf')
        ? charRange(decoded, 0, decoded.length - 5)
        : decoded;
  }

  static String _messageOf(Object error) =>
      error is AppFailure ? error.message : '$error';

  static LlmFailure _failureOf(Object error) =>
      error is LlmFailure ? error : LlmFailure('$error');
}

/// Один запрос генерации: флаги для отмены и keepalive.
final class _GenerationJob {
  _GenerationJob(this.modelId);

  final String modelId;
  var started = false;
  var generating = false;
  var finished = false;
  var cancelled = false;
}

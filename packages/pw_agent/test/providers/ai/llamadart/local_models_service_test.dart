import 'dart:async';
import 'dart:io';

import 'package:pw_agent/core/config/app_paths.dart';
import 'package:pw_agent/core/data/local_model_download_repository.dart';
import 'package:pw_agent/core/data/local_model_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/core/util/cancel_token.dart';
import 'package:pw_agent/providers/ai/llamadart/local_engine.dart';
import 'package:pw_agent/providers/ai/llamadart/local_models_service.dart';
import 'package:pw_agent/providers/ai/llamadart/local_storage.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/local_models.dart';
import 'package:pw_agent/providers/ai/model_runtime.dart';
import 'package:test/test.dart';

/// Хранилище в памяти: не трогает ни сеть, ни диск.
final class _FakeStorage implements LocalModelStorage {
  final files = <String, LocalModelStorageFile>{};
  final ensuredSources = <String>[];
  final ensuredKeys = <String?>[];
  final removed = <String>[];
  var cleared = 0;
  var nextKey = 'cache-1';

  @override
  Future<LocalModelStorageFile> ensure(
    String source, {
    String? key,
    String? displayName,
    String? sha256,
    void Function(int? received, int? total)? onProgress,
    CancelToken? cancel,
  }) async {
    ensuredSources.add(source);
    ensuredKeys.add(key);
    onProgress?.call(50, 100);
    onProgress?.call(100, 100);
    final file = LocalModelStorageFile(
      cacheKey: nextKey,
      path: '/models/$nextKey.gguf',
      sizeBytes: 100,
      sha256: sha256,
    );
    files[file.cacheKey] = file;
    return file;
  }

  @override
  Future<List<LocalModelStorageFile>> list() async =>
      files.values.toList(growable: false);

  @override
  Future<void> remove(String cacheKey) async {
    removed.add(cacheKey);
    files.remove(cacheKey);
  }

  @override
  Future<void> clear() async {
    cleared++;
    files.clear();
  }
}

/// Движок без нативных вызовов: записывает загрузки и генерации.
final class _FakeEngine implements LocalEngine {
  final loads = <String>[];
  final projectors = <String?>[];
  final generated = <String>[];
  var unloads = 0;
  var disposed = 0;
  var cancels = 0;
  var concurrent = 0;
  var maxConcurrent = 0;
  Completer<void>? gate;

  @override
  bool isLoaded = false;

  @override
  String? loadedPath;

  @override
  Future<void> load({
    required String path,
    required LocalModelSettings settings,
    String? projectorPath,
  }) async {
    loads.add(path);
    projectors.add(projectorPath);
    loadedPath = path;
    isLoaded = true;
  }

  @override
  Future<void> unload() async {
    unloads++;
    loadedPath = null;
    isLoaded = false;
  }

  @override
  Future<void> dispose() async => disposed++;

  @override
  Future<void> cancel() async => cancels++;

  @override
  Stream<LlmEvent> generate(
    LlmRequest request,
    LocalModelSettings settings,
  ) async* {
    generated.add(request.model);
    concurrent++;
    maxConcurrent = concurrent > maxConcurrent ? concurrent : maxConcurrent;
    try {
      await gate?.future;
      yield const LlmTextDelta('reply');
      yield const LlmCompleted(
        finishReason: 'stop',
        usage: LlmUsage(promptTokens: 3, completionTokens: 2),
      );
    } finally {
      concurrent--;
    }
  }
}

void main() {
  late AppDatabase db;
  late Directory support;
  late _FakeStorage storage;
  late _FakeEngine engine;
  late LocalModelsService service;

  LocalModelsService build({Duration keepalive = const Duration(days: 1)}) =>
      LocalModelsService(
        AppPaths.forSupport(support),
        LocalModelRepository(db),
        LocalModelDownloadRepository(db),
        SettingsRepository(db),
        storage,
        engineFactory: () => engine,
        keepalive: keepalive,
      );

  setUp(() async {
    db = openInMemoryDatabase();
    support = Directory.systemTemp.createTempSync('pw_local_models_');
    storage = _FakeStorage();
    engine = _FakeEngine();
    service = build();
  });

  tearDown(() async {
    await service.shutdown();
    await db.close();
    if (support.existsSync()) support.deleteSync(recursive: true);
  });

  test('install downloads a file and exposes it to the provider', () async {
    final id = await service.install('hf://owner/repo/model.gguf');

    expect(id, hasLength(16));
    final state = service.state;
    expect(state.models.single.name, 'model');
    expect(state.models.single.cacheKey, 'cache-1');
    expect(state.models.single.settings.contextSize, greaterThan(0));
    expect(state.models.single.available, isTrue);
    expect(storage.files, contains('cache-1'));
  });

  test('install publishes download progress to watch', () async {
    final events = <LocalModelsState>[];
    final sub = service.watch().listen(events.add);
    addTearDown(sub.cancel);
    await service.refresh();

    await service.install('hf://owner/repo/model.gguf');
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(
      events.any(
        (state) =>
            state.downloads.isNotEmpty &&
            state.downloads.first.receivedBytes == 50,
      ),
      isTrue,
    );
    expect(service.state.downloads, isEmpty);
  });

  test('resumes a persisted download on start', () async {
    final jobs = LocalModelDownloadRepository(db);
    await jobs.upsert(
      LocalModelDownloadJob(
        id: 'job-1',
        source: 'hf://owner/repo/model.gguf',
        name: 'Model',
        createdAt: DateTime.utc(2026),
      ),
    );

    await service.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(storage.ensuredSources, ['hf://owner/repo/model.gguf']);
    expect(storage.ensuredKeys, ['job-1']);
    expect(service.state.modelOf('job-1'), isNotNull);
    expect(await jobs.all(), isEmpty);
  });

  test('install rejects the same source twice', () async {
    await service.install('hf://owner/repo/model.gguf');

    expect(
      () => service.install('hf://owner/repo/model.gguf'),
      throwsA(isA<LlmFailure>()),
    );
  });

  test('import path records the file without copying it', () async {
    final file = File('${support.path}/imported.gguf')..writeAsBytesSync([1]);
    final id = await service.importPath(file.path, name: 'Импорт');

    final model = service.state.models.single;
    expect(model.id, id);
    expect(model.name, 'Импорт');
    expect(model.path, file.path);
    expect(model.sizeBytes, 1);
    expect(storage.files, isEmpty);
  });

  test('delete removes the cache entry and the record', () async {
    final id = await service.install('hf://owner/repo/model.gguf');

    await service.delete(id);

    expect(storage.removed, ['cache-1']);
    expect(service.state.models, isEmpty);
  });

  test('clearCache keeps imported files', () async {
    await service.install('hf://owner/repo/model.gguf');
    final file = File('${support.path}/imported.gguf')..writeAsBytesSync([1]);
    await service.importPath(file.path);

    await service.clearCache();

    expect(storage.cleared, 1);
    expect(service.state.models.single.source, file.path);
  });

  test('updateSettings persists parameters', () async {
    final id = await service.install('hf://owner/repo/model.gguf');

    await service.updateSettings(
      id,
      const LocalModelSettings(contextSize: 8192, supportsTools: false),
    );

    final model = service.state.models.single;
    expect(model.settings.contextSize, 8192);
    expect(model.settings.supportsTools, isFalse);
    final stored = await LocalModelRepository(db).byId(id);
    expect(stored?.settings.contextSize, 8192);
  });

  test('generate loads the file once and maps events', () async {
    final id = await service.install('hf://owner/repo/model.gguf');
    final request = LlmRequest(
      model: 'llamadart:$id',
      messages: const [LlmMessage.user('hi')],
    );

    final events = await service.generate(request, localModelId: id).toList();

    expect(events.whereType<LlmTextDelta>().single.text, 'reply');
    final done = events.whereType<LlmCompleted>().single;
    expect(done.usage?.completionTokens, 2);
    expect(engine.loads, ['/models/cache-1.gguf']);
  });

  test('generate serializes requests through the queue', () async {
    final id = await service.install('hf://owner/repo/model.gguf');
    final request = LlmRequest(
      model: 'llamadart:$id',
      messages: const [LlmMessage.user('hi')],
    );
    engine.gate = Completer<void>();

    final first = service.generate(request, localModelId: id).toList();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final second = service.generate(request, localModelId: id).toList();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(engine.generated, hasLength(1));
    engine.gate!.complete();
    await Future.wait([first, second]);
    expect(engine.generated, hasLength(2));
    expect(engine.maxConcurrent, 1);
  });

  test('cancelling a queued request does not cancel the active one', () async {
    final id = await service.install('hf://owner/repo/model.gguf');
    final request = LlmRequest(
      model: 'llamadart:$id',
      messages: const [LlmMessage.user('hi')],
    );
    engine.gate = Completer<void>();

    final first = service.generate(request, localModelId: id).toList();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final queued = <LlmEvent>[];
    final sub = service.generate(request, localModelId: id).listen(queued.add);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await sub.cancel();

    expect(engine.cancels, 0);
    engine.gate!.complete();
    await first;
  });

  test('projector is downloaded and passed to the engine', () async {
    final id = await service.install('hf://owner/repo/model.gguf');
    await service.updateSettings(
      id,
      const LocalModelSettings(projectorSource: 'hf://owner/repo/mmproj.gguf'),
    );
    storage.nextKey = 'projector-1';

    await service.loadIntoMemory(id);

    expect(engine.projectors.single, '/models/projector-1.gguf');
  });

  test('changing settings unloads the model so they apply next time', () async {
    final id = await service.install('hf://owner/repo/model.gguf');
    await service.loadIntoMemory(id);

    await service.updateSettings(
      id,
      const LocalModelSettings(contextSize: 8192),
    );

    final state = await service.snapshotMemory();
    expect(state.models['llamadart:$id']?.phase, ModelRuntimePhase.unloaded);
    expect(engine.unloads, 1);
  });

  test('loading the same model twice keeps one engine load', () async {
    final id = await service.install('hf://owner/repo/model.gguf');

    await service.loadIntoMemory(id);
    await service.loadIntoMemory(id);

    expect(engine.loads, hasLength(1));
  });

  test('load and unload report memory state', () async {
    final id = await service.install('hf://owner/repo/model.gguf');

    await service.loadIntoMemory(id);
    var state = await service.snapshotMemory();
    expect(state.models['llamadart:$id']?.phase, ModelRuntimePhase.loaded);

    await service.unloadFromMemory(id);
    state = await service.snapshotMemory();
    expect(state.models['llamadart:$id']?.phase, ModelRuntimePhase.unloaded);
    expect(engine.unloads, 1);
  });

  test('shutdown disposes the engine', () async {
    final id = await service.install('hf://owner/repo/model.gguf');
    await service.loadIntoMemory(id);

    await service.shutdown();

    expect(engine.disposed, 1);
  });
}

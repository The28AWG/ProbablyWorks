import 'dart:async';

import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/providers/ai/llamadart/llamadart_connection.dart';
import 'package:pw_agent/providers/ai/llamadart/llamadart_llm_provider.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/local_models.dart';
import 'package:pw_agent/providers/ai/model_runtime.dart';
import 'package:test/test.dart';

final class _FakeRuntime implements LocalModelRuntime {
  _FakeRuntime(this.models);

  final List<LocalModelFile> models;
  final generated = <String>[];
  final loaded = <String>[];
  final unloaded = <String>[];
  var failList = false;
  final changes = StreamController<ProviderRuntimeState>.broadcast();

  @override
  Future<List<LocalModelFile>> installedModels() async {
    if (failList) throw const LlmFailure('disk is unreadable');
    return models;
  }

  @override
  Future<LocalModelFile?> find(String localModelId) async {
    for (final model in models) {
      if (model.id == localModelId) return model;
    }
    return null;
  }

  @override
  Stream<LlmEvent> generate(
    LlmRequest request, {
    required String localModelId,
  }) async* {
    generated.add(localModelId);
    yield const LlmTextDelta('ok');
    yield const LlmCompleted(finishReason: 'stop');
  }

  @override
  Future<void> loadIntoMemory(String localModelId) async =>
      loaded.add(localModelId);

  @override
  Future<void> unloadFromMemory(String localModelId) async =>
      unloaded.add(localModelId);

  @override
  Future<ProviderRuntimeState> snapshotMemory() async =>
      ProviderRuntimeState(providerId: llamadartProviderId);

  @override
  Stream<ProviderRuntimeState> watchMemory() => changes.stream;
}

LocalModelFile _model({
  bool available = true,
  LocalModelSettings settings = const LocalModelSettings(contextSize: 8192),
}) => LocalModelFile(
  id: 'qwen',
  name: 'Qwen',
  source: 'hf://owner/repo/qwen.gguf',
  sourceKind: LocalModelSourceKind.huggingFace,
  cacheKey: 'cache',
  path: available ? '/models/qwen.gguf' : null,
  available: available,
  settings: settings,
  createdAt: DateTime.utc(2026),
);

LlamadartLlmProvider _provider(_FakeRuntime runtime, {bool enabled = true}) =>
    LlamadartLlmProvider(
      runtime: runtime,
      readConfig: () async => LlmProviderConfig(enabled: enabled),
    );

void main() {
  test('descriptor uses the llamadart prefix', () {
    expect(llamadartDescriptor.id, 'llamadart');
    expect(llamadartDescriptor.modelPrefix, 'llamadart:');
    expect(llamadartDescriptor.localModelId('llamadart:qwen'), 'qwen');
    expect(llamadartDescriptor.globalModelId('qwen'), 'llamadart:qwen');
  });

  test('listModels returns installed files with their settings', () async {
    final provider = _provider(_FakeRuntime([_model()]));

    final models = await provider.listModels();

    expect(models.single.id, 'qwen');
    expect(models.single.name, 'Qwen');
    expect(models.single.contextLength, 8192);
    expect(models.single.supportsTools, isTrue);
    expect(models.single.inputModalities, ['text']);
  });

  test('projector adds image and audio modalities', () async {
    final provider = _provider(
      _FakeRuntime([
        _model(
          settings: const LocalModelSettings(
            projectorSource: 'hf://owner/repo/mmproj.gguf',
          ),
        ),
      ]),
    );

    final models = await provider.listModels();

    expect(models.single.inputModalities, ['text', 'image']);
  });

  test('audio modality requires the projector audio flag', () async {
    final provider = _provider(
      _FakeRuntime([
        _model(
          settings: const LocalModelSettings(
            projectorSource: 'hf://owner/repo/mmproj.gguf',
            projectorAudio: true,
          ),
        ),
      ]),
    );

    final models = await provider.listModels();

    expect(models.single.inputModalities, ['text', 'image', 'audio']);
  });

  test('disabled provider serves no models', () async {
    final provider = _provider(_FakeRuntime([_model()]), enabled: false);

    expect(await provider.listModels(), isEmpty);
    await expectLater(
      provider
          .stream(const LlmRequest(model: 'llamadart:qwen', messages: []))
          .toList(),
      throwsA(isA<LlmFailure>()),
    );
  });

  test('stream strips the prefix and delegates to the runtime', () async {
    final runtime = _FakeRuntime([_model()]);
    final provider = _provider(runtime);

    final events = await provider
        .stream(
          const LlmRequest(
            model: 'llamadart:qwen',
            messages: [LlmMessage.user('hi')],
          ),
        )
        .toList();

    expect(runtime.generated, ['qwen']);
    expect(events.whereType<LlmTextDelta>().single.text, 'ok');
  });

  test('unknown model fails with modelNotFound', () async {
    final provider = _provider(_FakeRuntime([_model()]));

    expect(
      () => provider
          .stream(const LlmRequest(model: 'llamadart:other', messages: []))
          .toList(),
      throwsA(
        isA<LlmFailure>().having(
          (failure) => failure.modelNotFound,
          'modelNotFound',
          isTrue,
        ),
      ),
    );
  });

  test('statuses never throw and report the model count', () async {
    final runtime = _FakeRuntime([_model()]);
    final provider = _provider(runtime);

    var status = (await provider.statuses()).single;
    expect(status.available, isTrue);
    expect(status.modelCount, 1);

    runtime.failList = true;
    status = (await provider.statuses()).single;
    expect(status.available, isFalse);
    expect(status.error, contains('disk'));
  });

  test('runtime calls delegate to the environment', () async {
    final runtime = _FakeRuntime([_model()]);
    final provider = _provider(runtime);

    await provider.loadRuntimeModel('qwen');
    await provider.unloadRuntimeModel('qwen');
    expect(runtime.loaded, ['qwen']);
    expect(runtime.unloaded, ['qwen']);
    expect(await provider.runtimeEnabled, isTrue);
  });
}

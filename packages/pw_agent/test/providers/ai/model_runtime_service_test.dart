import 'dart:async';

import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/llm_provider_registry.dart';
import 'package:pw_agent/providers/ai/model_runtime.dart';
import 'package:pw_agent/providers/ai/model_runtime_service.dart';
import 'package:test/test.dart';

const _descriptor = LlmProviderDescriptor(
  id: 'test',
  label: 'Test',
  modelPrefix: 'test:',
);
const _modelId = 'test:model';

/// Адаптер с управляемым потоком runtime.
final class _FakeRuntime extends LlmProviderBase
    implements LlmModelRuntimeProvider {
  _FakeRuntime() : super(_descriptor);

  final events = StreamController<ProviderRuntimeState>.broadcast();
  final loads = <String>[];
  final unloads = <String>[];
  var enabled = true;

  @override
  Future<bool> get runtimeEnabled async => enabled;

  @override
  Future<ProviderRuntimeState> snapshotRuntime() async => _loaded('s');

  @override
  Stream<ProviderRuntimeState> watchRuntime() async* {
    yield _loaded('a');
    yield* events.stream;
  }

  @override
  Future<void> loadRuntimeModel(String localModelId) async {
    loads.add(localModelId);
    events.add(_state(ModelRuntimePhase.loaded));
  }

  @override
  Future<void> unloadRuntimeModel(String localModelId) async {
    unloads.add(localModelId);
    events.add(_state(ModelRuntimePhase.unloaded));
  }

  @override
  Stream<LlmEvent> stream(LlmRequest request) => const Stream.empty();

  @override
  Future<List<LlmModelInfo>> listModels() async => const [];

  ProviderRuntimeState _state(ModelRuntimePhase phase) => ProviderRuntimeState(
    providerId: _descriptor.id,
    capabilities: ModelRuntimeCapabilities.full,
    models: {
      _modelId: ModelRuntime(
        modelId: _modelId,
        phase: phase,
        updatedAt: DateTime.utc(2026, 11, 15),
      ),
    },
    updatedAt: DateTime.utc(2026, 11, 15),
  );

  ProviderRuntimeState _loaded(String marker) {
    // marker оставлен, чтобы состояния в тесте были различимы по времени.
    final now = DateTime.utc(2026, 11, 15, 12, marker == 'a' ? 0 : 1);
    return ProviderRuntimeState(
      providerId: _descriptor.id,
      capabilities: ModelRuntimeCapabilities.full,
      models: {
        _modelId: ModelRuntime(
          modelId: _modelId,
          phase: ModelRuntimePhase.loaded,
          updatedAt: now,
        ),
      },
      updatedAt: now,
    );
  }
}

void main() {
  test('aggregates runtime and routes load/unload by global id', () async {
    final adapter = _FakeRuntime();
    final service = ModelRuntimeService(LlmProviderRegistry([adapter]));
    addTearDown(adapter.events.close);

    final states = <ModelRuntimeState>[];
    final sub = service.watchRuntime().listen(states.add);
    addTearDown(sub.cancel);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(states.last.modelOf(_modelId)?.phase, ModelRuntimePhase.loaded);

    await service.loadModel(_modelId);
    expect(adapter.loads, ['model']);
    expect(service.runtime.modelOf(_modelId)?.phase, ModelRuntimePhase.loaded);

    await service.unloadModel(_modelId);
    expect(adapter.unloads, ['model']);
    expect(
      service.runtime.modelOf(_modelId)?.phase,
      ModelRuntimePhase.unloaded,
    );
  });

  test('round-trips runtime state through JSON', () {
    final state = ModelRuntimeState(
      providers: {
        'test': ProviderRuntimeState(
          providerId: 'test',
          capabilities: ModelRuntimeCapabilities.full,
          models: {
            _modelId: ModelRuntime(
              modelId: _modelId,
              phase: ModelRuntimePhase.loading,
              progress: const ModelLoadProgress(
                fraction: 0.5,
                stage: ModelLoadStage.weights,
                stageIndex: 0,
                stageCount: 2,
              ),
              startedAt: DateTime.utc(2026, 11, 15),
            ),
          },
        ),
      },
    );

    expect(ModelRuntimeState.fromJson(state.toJson()), state);
  });

  test('clears the stale snapshot when the provider stream fails', () async {
    final adapter = _FakeRuntime();
    final service = ModelRuntimeService(LlmProviderRegistry([adapter]));
    addTearDown(adapter.events.close);

    final states = <ModelRuntimeState>[];
    final sub = service.watchRuntime().listen(states.add);
    addTearDown(sub.cancel);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(service.runtime.modelOf(_modelId), isNotNull);

    adapter.events.addError(const LlmFailure('server is offline'));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(service.runtime.modelOf(_modelId), isNull);
    expect(
      service.runtime.providers['test']?.error,
      contains('server is offline'),
    );
    expect(states, isNotEmpty);
  });

  test(
    'clears the snapshot when the provider is disabled after start',
    () async {
      final adapter = _FakeRuntime();
      final service = ModelRuntimeService(LlmProviderRegistry([adapter]));
      addTearDown(adapter.events.close);

      final states = <ModelRuntimeState>[];
      final sub = service.watchRuntime().listen(states.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(service.runtime.modelOf(_modelId), isNotNull);

      adapter.enabled = false;
      await service.restartProvider('test');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(service.runtime.isEmpty, isTrue);
      expect(states, isNotEmpty);
    },
  );

  test('clears provider runtime when it is disabled', () async {
    final adapter = _FakeRuntime()..enabled = false;
    final service = ModelRuntimeService(LlmProviderRegistry([adapter]));
    addTearDown(adapter.events.close);

    final states = <ModelRuntimeState>[];
    final sub = service.watchRuntime().listen(states.add);
    addTearDown(sub.cancel);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(service.runtime.isEmpty, isTrue);
    expect(states, isNotEmpty);
  });
}

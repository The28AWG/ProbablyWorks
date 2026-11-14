import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/llm_provider_registry.dart';
import 'package:test/test.dart';

const _openRouter = LlmProviderDescriptor(
  id: 'openrouter',
  label: 'OpenRouter',
  requiresApiKey: true,
);

const _llamaCpp = LlmProviderDescriptor(
  id: 'llamacpp',
  label: 'llama.cpp',
  modelPrefix: 'llamacpp:',
);

/// Провайдер с настраиваемыми моделями и ошибкой списка.
class _FakeProvider extends LlmProviderBase {
  _FakeProvider(
    super.descriptor, {
    this.models = const [],
    this.configured = true,
    this.fail = false,
  });

  final List<LlmModelInfo> models;
  bool configured;
  bool fail;
  LlmRequest? lastRequest;

  @override
  Future<List<LlmProviderStatus>> configStatuses() async => [
    LlmProviderStatus(
      id: descriptor.id,
      enabled: configured,
      apiKeySet: configured,
    ),
  ];

  @override
  Future<List<LlmProviderStatus>> statuses() async => [
    LlmProviderStatus(
      id: descriptor.id,
      enabled: configured,
      available: !fail,
      checkedAt: DateTime.utc(2026, 11, 14),
    ),
  ];

  @override
  Future<List<LlmModelInfo>> listModels() async {
    if (fail) throw const LlmFailure('boom');
    return models;
  }

  @override
  Stream<LlmEvent> stream(LlmRequest request) {
    lastRequest = request;
    return Stream.value(const LlmCompleted());
  }
}

void main() {
  test('aggregates models with provider prefixes', () async {
    final openRouter = _FakeProvider(
      _openRouter,
      models: const [LlmModelInfo(id: 'openai/gpt-4o', name: 'GPT-4o')],
    );
    final llama = _FakeProvider(
      _llamaCpp,
      models: const [LlmModelInfo(id: 'qwen3', name: 'Qwen 3')],
    );

    final registry = LlmProviderRegistry([openRouter, llama]);

    expect(registry.providers, [_openRouter, _llamaCpp]);
    final models = await registry.listModels();
    expect(models.map((model) => model.id), [
      'openai/gpt-4o',
      'llamacpp:qwen3',
    ]);
  });

  test('routes a model to its provider by prefix', () async {
    final openRouter = _FakeProvider(_openRouter);
    final llama = _FakeProvider(_llamaCpp);
    final registry = LlmProviderRegistry([openRouter, llama]);

    await registry
        .stream(const LlmRequest(model: 'llamacpp:qwen3', messages: []))
        .drain<void>();
    expect(llama.lastRequest?.model, 'llamacpp:qwen3');
    expect(openRouter.lastRequest, isNull);

    await registry
        .stream(const LlmRequest(model: 'openai/gpt-4o', messages: []))
        .drain<void>();
    expect(openRouter.lastRequest?.model, 'openai/gpt-4o');
  });

  test('an error of one provider does not hide another', () async {
    final openRouter = _FakeProvider(_openRouter, fail: true);
    final llama = _FakeProvider(
      _llamaCpp,
      models: const [LlmModelInfo(id: 'qwen3', name: 'Qwen 3')],
    );

    final models = await LlmProviderRegistry([openRouter, llama]).listModels();

    expect(models.single.id, 'llamacpp:qwen3');
  });

  test('no configured provider means no model list', () async {
    final openRouter = _FakeProvider(_openRouter, configured: false);
    final llama = _FakeProvider(_llamaCpp, configured: false);

    await expectLater(
      LlmProviderRegistry([openRouter, llama]).listModels(),
      throwsA(isA<LlmFailure>()),
    );
  });

  test('a provider requiring a key needs it to be configured', () async {
    final keyless = _KeylessProvider();

    expect(await LlmProviderRegistry([keyless]).hasUsableProvider, isFalse);

    keyless.keyPresent = true;
    expect(await LlmProviderRegistry([keyless]).hasUsableProvider, isTrue);
  });

  test('statuses of all providers are merged', () async {
    final registry = LlmProviderRegistry([
      _FakeProvider(_openRouter),
      _FakeProvider(_llamaCpp),
    ]);

    final statuses = await registry.statuses();

    expect(statuses.map((status) => status.id), ['openrouter', 'llamacpp']);
    expect(statuses.every((status) => status.available), isTrue);
  });
}

/// Провайдер с обязательным ключом: включён, но без ключа не настроен.
class _KeylessProvider extends LlmProviderBase {
  _KeylessProvider() : super(_openRouter);

  bool keyPresent = false;

  @override
  Future<List<LlmProviderStatus>> configStatuses() async => [
    LlmProviderStatus(id: descriptor.id, apiKeySet: keyPresent),
  ];

  @override
  Future<List<LlmModelInfo>> listModels() async => const [];

  @override
  Stream<LlmEvent> stream(LlmRequest request) => Stream<LlmEvent>.empty();
}

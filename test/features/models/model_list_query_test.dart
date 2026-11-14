import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/features/models/domain/model_list_query.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';

LlmModelInfo _model(
  String id, {
  String? name,
  bool tools = true,
  int? context,
  String? prompt = '0.000001',
  String? completion = '0.000002',
  int? created,
}) => LlmModelInfo(
  id: id,
  name: name ?? id,
  supportsTools: tools,
  contextLength: context,
  promptPrice: prompt,
  completionPrice: completion,
  created: created,
);

List<String> _ids(List<LlmModelInfo> models) => [for (final m in models) m.id];

void main() {
  final models = [
    _model('openai/gpt-4o', name: 'GPT-4o', context: 128000, created: 30),
    _model(
      'google/gemini-free',
      name: 'Gemini Free',
      context: 32000,
      prompt: '0',
      completion: '0',
      created: 10,
    ),
    _model(
      'anthropic/claude',
      name: 'Claude',
      context: 200000,
      created: 20,
      tools: false,
    ),
    _model('meta/llama', name: 'Llama', prompt: null, created: 40),
  ];

  group('filters', () {
    test('tool calling is required by default', () {
      final result = applyModelQuery(models, const ModelListQuery());
      expect(
        _ids(result),
        unorderedEquals(['openai/gpt-4o', 'google/gemini-free', 'meta/llama']),
      );
    });

    test('turning tool calling off shows models without it', () {
      final result = applyModelQuery(
        models,
        const ModelListQuery(toolsOnly: false),
      );
      expect(_ids(result), contains('anthropic/claude'));
    });

    test('free only keeps models with zero price', () {
      final result = applyModelQuery(
        models,
        const ModelListQuery(freeOnly: true),
      );
      expect(_ids(result), ['google/gemini-free']);
    });

    test('a model without a known price is not free', () {
      expect(isFreeModel(_model('meta/llama', prompt: null)), isFalse);
    });

    test('provider filter matches the id prefix', () {
      final result = applyModelQuery(
        models,
        const ModelListQuery(provider: 'openai'),
      );
      expect(_ids(result), ['openai/gpt-4o']);
    });

    test('search matches name and id, case-insensitively', () {
      expect(
        _ids(
          applyModelQuery(models, const ModelListQuery(search: '  GEMINI ')),
        ),
        ['google/gemini-free'],
      );
      expect(
        _ids(applyModelQuery(models, const ModelListQuery(search: 'meta/'))),
        ['meta/llama'],
      );
    });
  });

  group('sort', () {
    test('by name ignores case', () {
      final result = applyModelQuery(
        models,
        const ModelListQuery(sort: ModelSort.name),
      );
      expect(_ids(result), [
        'google/gemini-free',
        'openai/gpt-4o',
        'meta/llama',
      ]);
    });

    test('by context puts the largest first and unknown last', () {
      final result = applyModelQuery(
        models,
        const ModelListQuery(toolsOnly: false, sort: ModelSort.context),
      );
      expect(_ids(result), [
        'anthropic/claude',
        'openai/gpt-4o',
        'google/gemini-free',
        'meta/llama',
      ]);
    });

    test('by price puts the cheapest first and unknown last', () {
      final result = applyModelQuery(
        models,
        const ModelListQuery(sort: ModelSort.price),
      );
      expect(_ids(result), [
        'google/gemini-free',
        'openai/gpt-4o',
        'meta/llama',
      ]);
    });

    test('newest first, unknown dates last', () {
      final result = applyModelQuery(
        models,
        const ModelListQuery(sort: ModelSort.newest),
      );
      expect(_ids(result), [
        'meta/llama',
        'openai/gpt-4o',
        'google/gemini-free',
      ]);
    });

    test('provider sort keeps the catalog order', () {
      final result = applyModelQuery(
        models,
        const ModelListQuery(sort: ModelSort.provider),
      );
      expect(_ids(result), _ids(models.where((m) => m.supportsTools).toList()));
    });
  });

  test('providersOf lists providers, sorted', () {
    expect(providersOf(models), ['anthropic', 'google', 'meta', 'openai']);
  });

  test('llama.cpp models share one provider', () {
    expect(providerOf('llamacpp:Hy-MT2-1.8B-Q4_K_M'), 'llama.cpp');
    expect(
      providersOf([
        _model('llamacpp:Hy-MT2-1.8B-Q4_K_M'),
        _model('llamacpp:Qwen3-Embedding-8B-Q4_K_M'),
        _model('openai/gpt-4o'),
      ]),
      ['llama.cpp', 'openai'],
    );
  });

  test('provider filter accepts llama.cpp models', () {
    final result = applyModelQuery([
      _model('llamacpp:Hy-MT2-1.8B-Q4_K_M'),
      _model('openai/gpt-4o'),
    ], const ModelListQuery(provider: 'llama.cpp'));
    expect(_ids(result), ['llamacpp:Hy-MT2-1.8B-Q4_K_M']);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/providers/ai/llm_port.dart';
import 'package:probably_works/providers/ai/model_catalog.dart';

Chat _chat({String? model}) => Chat(
  id: 'c',
  hostId: 'local',
  title: '',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  model: model,
);

ModelCatalogState _loaded(List<LlmModelInfo> models) =>
    ModelCatalogState(models: models, syncedAt: DateTime(2026));

const _gpt = LlmModelInfo(id: 'openai/gpt-4o', name: 'GPT-4o');

void main() {
  test('chat without its own model uses the default model', () {
    final state = ChatState(chat: _chat(), defaultModelId: 'openai/gpt-4o');
    expect(state.effectiveModelId, 'openai/gpt-4o');
  });

  test('chat model wins over the default', () {
    final state = ChatState(
      chat: _chat(model: 'anthropic/claude'),
      defaultModelId: 'openai/gpt-4o',
    );
    expect(state.effectiveModelId, 'anthropic/claude');
  });

  test('a model missing from the loaded list is unavailable', () {
    final state = ChatState(
      chat: _chat(model: 'anthropic/claude'),
      catalog: _loaded([_gpt]),
    );
    expect(state.modelUnavailable, isTrue);
  });

  test('a listed model is available', () {
    final state = ChatState(
      chat: _chat(model: 'openai/gpt-4o'),
      catalog: _loaded([_gpt]),
    );
    expect(state.modelUnavailable, isFalse);
    expect(state.modelStatus, ModelStatus.available);
  });

  test('before the list is loaded nothing is flagged', () {
    expect(
      ChatState(chat: _chat(model: 'openai/gpt-4o')).modelUnavailable,
      isFalse,
    );
  });

  test('the default model is checked when the chat has none', () {
    final state = ChatState(
      chat: _chat(),
      defaultModelId: 'openai/gone',
      catalog: _loaded([_gpt]),
    );
    expect(state.modelUnavailable, isTrue);
  });

  test('a departed model keeps its saved name', () {
    const saved = SavedModel(id: 'anthropic/claude', name: 'Claude');
    final state = ChatState(
      chat: _chat(model: 'anthropic/claude'),
      catalog: ModelCatalogState(
        models: const [_gpt],
        syncedAt: DateTime(2026),
        saved: const {'anthropic/claude': saved},
      ),
    );
    expect(state.catalog.nameOf('anthropic/claude'), 'Claude');
    expect(state.modelUnavailable, isTrue);
  });

  test('the first load shows a spinner, later refreshes do not', () {
    expect(const ModelCatalogState(loading: true).initialLoading, isTrue);
    expect(
      ModelCatalogState(loading: true, syncedAt: DateTime(2026)).initialLoading,
      isFalse,
    );
  });

  test('no chat model and empty default means nothing is selected', () {
    expect(
      ChatState(chat: _chat(), defaultModelId: '').effectiveModelId,
      isNull,
    );
    expect(
      ChatState(chat: _chat(model: ''), defaultModelId: null).effectiveModelId,
      isNull,
    );
  });

  test('while the chat loads, a missing model is pending, not a problem', () {
    final state = ChatState(chat: _chat(), defaultModelId: null, loading: true);
    expect(state.modelPending, isTrue);
  });

  test('after loading, a missing model is a real problem', () {
    final state = ChatState(chat: _chat(), defaultModelId: null);
    expect(state.modelPending, isFalse);
  });

  test('a chat with its own model is never pending', () {
    final state = ChatState(chat: _chat(model: 'openai/gpt-4o'), loading: true);
    expect(state.modelPending, isFalse);
  });

  test('a missing-model failure is shown as a model problem, not raw text', () {
    final state = ChatState(
      chat: _chat(model: 'anthropic/claude'),
      failure: 'No endpoints found',
      failureModelMissing: true,
    );
    expect(state.failureIsModelMissing, isTrue);
    expect(ChatState(failure: 'network down').failureIsModelMissing, isFalse);
    expect(ChatState(failureModelMissing: true).failureIsModelMissing, isFalse);
  });
}

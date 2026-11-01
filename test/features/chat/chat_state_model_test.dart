import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';

Chat _chat({String? model}) => Chat(
  id: 'c',
  hostId: 'local',
  title: '',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  model: model,
);

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
}

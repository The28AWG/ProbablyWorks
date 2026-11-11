import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';

void main() {
  test('reasoning survives the payload round trip', () {
    final original = ChatMessage(
      id: 'm1',
      chatId: 'c',
      seq: 2,
      role: MessageRole.assistant,
      createdAt: DateTime(2026),
      text: 'Готово',
      reasoning: 'Сначала проверю каталог',
    );

    final decoded = ChatMessage.decode(
      id: original.id,
      chatId: original.chatId,
      seq: original.seq,
      role: original.role.name,
      payload: original.encodePayload(),
      createdAt: original.createdAt,
    );

    expect(decoded.reasoning, 'Сначала проверю каталог');
    expect(decoded.text, 'Готово');
  });

  test(
    'payloads written before reasoning existed decode to empty reasoning',
    () {
      final decoded = ChatMessage.decode(
        id: 'm1',
        chatId: 'c',
        seq: 1,
        role: 'assistant',
        payload: '{"text":"старый ответ","toolCalls":[],"toolCallId":null,"attachments":[]}',
        createdAt: DateTime(2026),
      );

      expect(decoded.reasoning, isEmpty);
      expect(decoded.text, 'старый ответ');
    },
  );
}

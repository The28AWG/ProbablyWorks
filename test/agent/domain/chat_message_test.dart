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

  test('mentions survive the payload round trip', () {
    final original = ChatMessage(
      id: 'm1',
      chatId: 'c',
      seq: 1,
      role: MessageRole.user,
      createdAt: DateTime(2026),
      text: 'смотри @app.dart',
      mentions: const [
        MentionRef(
          kind: MentionKind.file,
          path: 'src/app.dart',
          start: 7,
          end: 16,
        ),
      ],
    );
    final decoded = ChatMessage.decode(
      id: original.id,
      chatId: original.chatId,
      seq: original.seq,
      role: original.role.name,
      payload: original.encodePayload(),
      createdAt: original.createdAt,
    );
    expect(decoded.mentions.single.path, 'src/app.dart');
    expect(decoded.mentions.single.kind, MentionKind.file);
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

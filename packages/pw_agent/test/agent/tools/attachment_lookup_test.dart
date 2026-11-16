import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/tools/attachment_lookup.dart';
import 'package:test/test.dart';

/// Вложение, которое не должно утекать из своего чата.
AttachmentRef _attachment(String name, {String content = 'text'}) =>
    AttachmentRef(
      name: name,
      mode: AttachmentMode.attach,
      content: content,
      sizeBytes: content.length,
    );

ChatMessage _message({
  required String id,
  required String chatId,
  required int seq,
  required List<AttachmentRef> attachments,
}) => ChatMessage(
  id: id,
  chatId: chatId,
  seq: seq,
  role: MessageRole.user,
  createdAt: DateTime(2026),
  attachments: attachments,
);

void main() {
  // Инструмент получает только сообщения своего чата: это и есть изоляция.
  final ownChat = [
    _message(
      id: 'm1',
      chatId: 'c1',
      seq: 1,
      attachments: [_attachment('report.txt')],
    ),
  ];
  final otherChat = [
    _message(
      id: 'm9',
      chatId: 'c2',
      seq: 1,
      attachments: [_attachment('secret.txt')],
    ),
  ];

  group('findAttachment', () {
    test('finds an attachment of its own chat', () {
      final found = findAttachment(ownChat, 'report.txt');

      expect(found, isNotNull);
      expect(found!.message.id, 'm1');
      expect(found.attachment.content, 'text');
    });

    test('a message id from another chat opens nothing', () {
      expect(findAttachment(ownChat, 'secret.txt', messageId: 'm9'), isNull);
      expect(findAttachment(ownChat, 'report.txt', messageId: 'm9'), isNull);
    });

    test('a name that only exists in another chat is not found', () {
      expect(findAttachment(ownChat, 'secret.txt'), isNull);
      // Фикстура действительно есть в соседнем чате: скрывает её именно граница
      // чата, а не опечатка в имени.
      expect(findAttachment(otherChat, 'secret.txt'), isNotNull);
    });

    test('the newest message wins when a name repeats', () {
      final messages = [
        _message(
          id: 'old',
          chatId: 'c1',
          seq: 1,
          attachments: [_attachment('log.txt', content: 'old')],
        ),
        _message(
          id: 'new',
          chatId: 'c1',
          seq: 2,
          attachments: [_attachment('log.txt', content: 'new')],
        ),
      ];

      expect(findAttachment(messages, 'log.txt')!.attachment.content, 'new');
      expect(
        findAttachment(
          messages,
          'log.txt',
          messageId: 'old',
        )!.attachment.content,
        'old',
      );
    });

    test('an unknown name is null even when other names exist', () {
      expect(findAttachment(ownChat, 'missing.txt'), isNull);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/core/data/chat_repository.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/security/secret_store.dart';

void main() {
  late AppDatabase db;
  late ChatRepository chats;
  final now = DateTime(2026, 11, 26, 12);

  setUp(() async {
    db = openInMemoryDatabase();
    chats = ChatRepository(db);
    await HostRepository(db, MemorySecretStore()).ensureLocalHost(now);
    await chats.saveChat(
      Chat(
        id: 'c1',
        hostId: 'local',
        title: 'Чат',
        createdAt: now,
        updatedAt: now,
      ),
    );
  });

  tearDown(() => db.close());

  ChatMessage message(
    String id, {
    required int seq,
    required MessageRole role,
  }) => ChatMessage(
    id: id,
    chatId: 'c1',
    seq: seq,
    role: role,
    createdAt: now,
    text: id,
  );

  test('unread counts agent and service messages, not the user', () async {
    await chats.insertMessage(message('u1', seq: 1, role: MessageRole.user));
    await chats.insertMessage(
      message('a2', seq: 2, role: MessageRole.assistant),
    );
    await chats.insertMessage(message('e3', seq: 3, role: MessageRole.event));

    final chat = (await chats.chat('c1'))!;
    expect(chat.lastMessageSeq, 3);
    expect(chat.lastReadSeq, 0);
    expect(chat.unreadCount, 2);
    expect(chat.hasUnread, isTrue);
  });

  test(
    'read cursor moves forward and is clamped to the last message',
    () async {
      await chats.insertMessage(
        message('a1', seq: 1, role: MessageRole.assistant),
      );
      await chats.insertMessage(
        message('a2', seq: 2, role: MessageRole.assistant),
      );
      await chats.insertMessage(
        message('a3', seq: 3, role: MessageRole.assistant),
      );

      final first = await chats.markRead('c1', seq: 2);
      expect(first.lastReadSeq, 2);
      expect(first.unreadCount, 1);
      expect(first.readRevision, 1);

      // Поздний запрос с меньшим seq не возвращает непрочитанное.
      final stale = await chats.markRead('c1', seq: 1);
      expect(stale.lastReadSeq, 2);
      expect(stale.unreadCount, 1);
      expect(stale.readRevision, 1);

      // Больше последнего сообщения прочитать нельзя.
      final all = await chats.markRead('c1', seq: 99);
      expect(all.lastReadSeq, 3);
      expect(all.unreadCount, 0);
      expect(all.readRevision, 2);

      final stored = (await chats.chat('c1'))!;
      expect(stored.lastReadSeq, 3);
      expect(stored.lastMessageSeq, 3);
      expect(stored.unreadCount, 0);
    },
  );

  test(
    'rewriting history reopens the cursor for reused sequence numbers',
    () async {
      await chats.insertMessage(
        message('a1', seq: 1, role: MessageRole.assistant),
      );
      await chats.insertMessage(
        message('a2', seq: 2, role: MessageRole.assistant),
      );
      await chats.markRead('c1', seq: 2);

      await chats.deleteMessagesFrom('c1', 2);
      final rewritten = (await chats.chat('c1'))!;
      expect(rewritten.lastReadSeq, 1);
      expect(rewritten.lastMessageSeq, 1);

      // Новая история может снова занять seq 2. Она обязана быть непрочитанной,
      // иначе пользователь пропустит перегенерированный ответ.
      await chats.insertMessage(
        message('a2-new', seq: 2, role: MessageRole.assistant),
      );
      final after = (await chats.chat('c1'))!;
      expect(after.lastMessageSeq, 2);
      expect(after.unreadCount, 1);
    },
  );

  test('read cursor rejects a stale expected revision', () async {
    await chats.insertMessage(
      message('a1', seq: 1, role: MessageRole.assistant),
    );
    await chats.markRead('c1', seq: 1);

    await expectLater(
      chats.markRead('c1', seq: 1, expectedRevision: 0),
      throwsA(
        isA<Object>().having(
          (error) => error.toString(),
          'message',
          contains('read cursor revision changed'),
        ),
      ),
    );
  });

  test(
    'deleting a message below the cursor keeps later messages read',
    () async {
      await chats.insertMessage(
        message('a1', seq: 1, role: MessageRole.assistant),
      );
      await chats.insertMessage(
        message('a2', seq: 2, role: MessageRole.assistant),
      );
      await chats.insertMessage(
        message('a3', seq: 3, role: MessageRole.assistant),
      );
      await chats.markRead('c1', seq: 3);

      await chats.deleteMessage('a2');

      // Дырка в нумерации не повод перечитывать: номера 1 и 3 не заняты заново.
      final chat = (await chats.chat('c1'))!;
      expect(chat.lastReadSeq, 3);
      expect(chat.lastMessageSeq, 3);
      expect(chat.unreadCount, 0);
    },
  );

  test('deleting the last message releases its seq for a new unread', () async {
    await chats.insertMessage(
      message('a1', seq: 1, role: MessageRole.assistant),
    );
    await chats.insertMessage(
      message('a2', seq: 2, role: MessageRole.assistant),
    );
    await chats.markRead('c1', seq: 2);

    await chats.deleteMessage('a2');
    // Курсор не должен остаться на освободившемся seq 2: новое сообщение
    // займёт его же и обязано быть непрочитанным.
    final released = (await chats.chat('c1'))!;
    expect(released.lastReadSeq, 1);
    expect(released.lastMessageSeq, 1);

    await chats.insertMessage(
      message('a2-new', seq: 2, role: MessageRole.assistant),
    );
    final after = (await chats.chat('c1'))!;
    expect(after.lastMessageSeq, 2);
    expect(after.unreadCount, 1);
  });
}

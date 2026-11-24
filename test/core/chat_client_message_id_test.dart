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
  final now = DateTime(2026, 11, 25, 12);

  setUp(() async {
    db = openInMemoryDatabase();
    chats = ChatRepository(db);
    await HostRepository(db, MemorySecretStore()).ensureLocalHost(now);
    for (final id in ['c1', 'c2']) {
      await chats.saveChat(
        Chat(
          id: id,
          hostId: 'local',
          title: id,
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
  });

  tearDown(() => db.close());

  ChatMessage message(
    String chatId, {
    required String id,
    required String clientMessageId,
    int seq = 1,
  }) => ChatMessage(
    id: id,
    chatId: chatId,
    seq: seq,
    role: MessageRole.user,
    createdAt: now,
    text: 'hi',
    clientMessageId: clientMessageId,
  );

  test('the same client message id is allowed in different chats', () async {
    await chats.insertMessage(
      message('c1', id: 'm1', clientMessageId: 'client-1'),
    );
    await chats.insertMessage(
      message('c2', id: 'm2', clientMessageId: 'client-1'),
    );

    expect(await chats.hasClientMessage('c1', 'client-1'), isTrue);
    expect(await chats.hasClientMessage('c2', 'client-1'), isTrue);
  });

  test('the same client message id is rejected inside one chat', () async {
    await chats.insertMessage(
      message('c1', id: 'm1', clientMessageId: 'client-1'),
    );

    await expectLater(
      chats.insertMessage(
        message('c1', id: 'm2', clientMessageId: 'client-1', seq: 2),
      ),
      throwsA(anything),
    );
  });
}

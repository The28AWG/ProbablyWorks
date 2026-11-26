import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/agent/attention/chat_attention_service.dart';
import 'package:pw_agent/agent/domain/chat_attention.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/core/data/chat_repository.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/security/secret_store.dart';

void main() {
  late AppDatabase db;
  late ChatRepository chats;
  late InteractionBroker broker;
  late ChatAttentionService attention;
  final now = DateTime.utc(2026, 11, 27, 12);

  setUp(() async {
    db = openInMemoryDatabase();
    chats = ChatRepository(db);
    broker = InteractionBroker();
    await HostRepository(db, MemorySecretStore()).ensureLocalHost(now);
    attention = ChatAttentionService(chats, broker);
  });

  tearDown(() async {
    await attention.dispose();
    await db.close();
  });

  Future<void> chat(String id, {ChatKind kind = ChatKind.main}) =>
      chats.saveChat(
        Chat(
          id: id,
          hostId: 'local',
          kind: kind,
          title: 'Чат $id',
          createdAt: now,
          updatedAt: now,
        ),
      );

  Future<void> reply(String chatId, {int seq = 1}) => chats.insertMessage(
    ChatMessage(
      id: '$chatId-$seq',
      chatId: chatId,
      seq: seq,
      role: MessageRole.assistant,
      text: 'ответ',
      createdAt: now,
    ),
  );

  ChatAttention item(String chatId) =>
      attention.snapshot.items.firstWhere((item) => item.chatId == chatId);

  test(
    'collects unread, approvals and a failed turn into one snapshot',
    () async {
      await chat('c1');
      await reply('c1');
      await pumpEventQueue();

      expect(item('c1').reasons, {ChatAttentionReason.unread});
      expect(item('c1').unreadCount, 1);

      unawaited(
        broker.requestApproval(
          ApprovalRequest(
            id: 'a1',
            chatId: 'c1',
            toolName: 'run_command',
            summary: 'rm -rf build',
            reason: 'нужно подтверждение',
          ),
        ),
      );
      await pumpEventQueue();

      final withApproval = item('c1');
      expect(
        withApproval.reasons,
        containsAll([ChatAttentionReason.approval, ChatAttentionReason.unread]),
      );
      expect(withApproval.actionableCount, 1);
      expect(withApproval.approvals.single.id, 'a1');

      broker.resolveApproval('a1', const ApprovalDecision.deny());
      await pumpEventQueue();
      expect(item('c1').approvals, isEmpty);

      await attention.turnFinished('c1', TurnEnd.failed);
      await pumpEventQueue();
      expect(item('c1').reasons, contains(ChatAttentionReason.failed));
      expect(item('c1').actionableCount, 1);
      expect(item('c1').turnAt, isNotNull);

      // Новый ход снимает проблему, но не прочитанное сообщение.
      attention.turnStarted('c1');
      await pumpEventQueue();
      expect(item('c1').hasProblem, isFalse);
      expect(item('c1').actionableCount, 0);

      // Успешный ход снимает сохранённую проблему полностью.
      await attention.turnFinished('c1', TurnEnd.completed);
      await pumpEventQueue();
      expect(await chats.watchAttentionStates().first, isEmpty);
    },
  );

  test(
    'a successful turn does not briefly return the previous problem',
    () async {
      await chat('c1');
      await reply('c1');
      await pumpEventQueue();

      await attention.turnFinished('c1', TurnEnd.stepLimit);
      await pumpEventQueue();
      expect(item('c1').hasProblem, isTrue);

      // Новый ход скрывает старую проблему, но запись в базе остаётся.
      attention.turnStarted('c1');
      await pumpEventQueue();
      expect(item('c1').hasProblem, isFalse);

      final seen = <ChatAttentionReason>[];
      final sub = attention.changes.listen(
        (snapshot) =>
            seen.addAll([for (final item in snapshot.items) ...item.reasons]),
      );
      addTearDown(sub.cancel);

      await attention.turnFinished('c1', TurnEnd.completed);
      await pumpEventQueue();

      // Между записью обычного завершения и обновлением потока базы снимок не
      // должен успеть вернуть уже снятую проблему.
      expect(seen, isNot(contains(ChatAttentionReason.stepLimit)));
      expect(item('c1').reasons, {ChatAttentionReason.unread});
    },
  );

  test('sorts decisions before problems and unread replies', () async {
    await chat('c1');
    await chat('c2');
    await reply('c1');
    await pumpEventQueue();
    expect(attention.snapshot.items.single.chatId, 'c1');

    unawaited(
      broker.requestApproval(
        ApprovalRequest(
          id: 'a1',
          chatId: 'c2',
          toolName: 'run_command',
          summary: 'ls',
          reason: 'подтверждение',
        ),
      ),
    );
    await pumpEventQueue();

    expect(attention.snapshot.items.map((item) => item.chatId), ['c2', 'c1']);

    await attention.turnFinished('c1', TurnEnd.stepLimit);
    await pumpEventQueue();
    expect(item('c1').hasProblem, isTrue);
  });

  test('ignores subagent chats and dismisses a stored problem', () async {
    await chat('sub', kind: ChatKind.subagent);
    await reply('sub');
    await chat('main');
    await attention.turnFinished('main', TurnEnd.budget);
    await pumpEventQueue();

    expect(attention.snapshot.items.map((item) => item.chatId), ['main']);
    expect(item('main').reasons, {ChatAttentionReason.budget});

    await attention.dismiss('main');
    await pumpEventQueue();
    expect(attention.snapshot.items, isEmpty);
  });
}

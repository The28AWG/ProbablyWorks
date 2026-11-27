import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/attention/chat_attention_service.dart';
import 'package:pw_agent/agent/domain/attention_digest.dart';
import 'package:pw_agent/agent/domain/chat_attention.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/notification_pause.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/core/data/chat_repository.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/notify/app_notifier.dart';
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
    attention = ChatAttentionService(chats, broker, now: () => now);
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
      // Сумма для бейджа считается по всем чатам, а не только по входящим.
      expect(attention.snapshot.unreadTotal, 1);

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

  test('builds a digest from the shared read cursor', () async {
    await chat('c1');
    await reply('c1', seq: 1);
    // Промежуточный шаг с вызовом инструмента — не завершённый ход.
    await chats.insertMessage(
      ChatMessage(
        id: 'c1-2',
        chatId: 'c1',
        seq: 2,
        role: MessageRole.assistant,
        toolCalls: const [
          ToolCallRef(id: 'call-1', name: 'run_command', arguments: '{}'),
        ],
        createdAt: now,
      ),
    );
    await chat('c2');
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
    await attention.turnFinished('c2', TurnEnd.failed);
    await pumpEventQueue();

    final digest = await attention.digest();
    final first = digest.items.firstWhere((item) => item.chatId == 'c1');
    final second = digest.items.firstWhere((item) => item.chatId == 'c2');
    expect(first.unreadMessages, 2);
    expect(first.finishedTurns, 1);
    expect(second.approvals, 1);
    expect(second.problems, 1);
    expect(digest.newMessages, 2);
    expect(digest.finishedTurns, 1);
    expect(digest.decisions, 1);
    expect(digest.problems, 1);

    // Прочитанное на любом устройстве исчезает из дайджеста на всех.
    await chats.markRead('c1', seq: 2);
    await pumpEventQueue();
    final after = await attention.digest();
    expect(after.newMessages, 0);
    expect(after.finishedTurns, 0);
    expect(after.decisions, 1);
    expect(after.problems, 1);
  });

  test('a reasoning-only assistant step is not a finished turn', () async {
    await chat('c1');
    await chats.insertMessage(
      ChatMessage(
        id: 'c1-1',
        chatId: 'c1',
        seq: 1,
        role: MessageRole.assistant,
        reasoning: 'думаю',
        createdAt: now,
      ),
    );
    await pumpEventQueue();

    final digest = await attention.digest();
    final item = digest.items.single;
    expect(item.unreadMessages, 1);
    expect(item.finishedTurns, 0);
  });

  test('does not put subagent chats into the digest', () async {
    await chat('sub', kind: ChatKind.subagent);
    await reply('sub');
    await chat('main');
    await attention.turnFinished('main', TurnEnd.failed);
    await pumpEventQueue();

    final digest = await attention.digest();
    expect(digest.items.map((item) => item.chatId), ['main']);
  });

  test('a snoozed chat leaves the inbox and returns on unsnooze', () async {
    await chat('c1');
    await reply('c1');
    await pumpEventQueue();
    expect(attention.snapshot.items.map((item) => item.chatId), ['c1']);

    final until = now.add(const Duration(hours: 1));
    await attention.snooze('c1', until);
    await pumpEventQueue();

    expect(attention.snapshot.items, isEmpty);
    // Из входящих чат ушёл, но сообщение всё ещё непрочитано: бейдж
    // приложения не должен обнуляться из-за напоминания.
    expect(attention.snapshot.unreadTotal, 1);
    expect(attention.snapshot.snoozed.single.chatId, 'c1');
    expect(
      attention.snapshot.snoozed.single.until.isAtSameMomentAs(until),
      isTrue,
    );
    expect(attention.isSnoozed('c1'), isTrue);
    // Отложенное не попадает и в дайджест: пользователь попросил не
    // напоминать до срока.
    expect((await attention.digest()).items, isEmpty);

    await attention.unsnooze('c1');
    await pumpEventQueue();

    expect(attention.snapshot.snoozed, isEmpty);
    expect(attention.snapshot.items.single.chatId, 'c1');
    expect(attention.isSnoozed('c1'), isFalse);
  });

  test('snoozing cancels the notices already shown for the chat', () async {
    await attention.dispose();
    final notifier = _RecordingNotifier();
    attention = ChatAttentionService(
      chats,
      broker,
      notifier: notifier,
      now: () => now,
    );
    await chat('c1');
    unawaited(
      broker.requestApproval(
        ApprovalRequest(
          id: 'a1',
          chatId: 'c1',
          toolName: 'run_command',
          summary: 'ls',
          reason: 'подтверждение',
        ),
      ),
    );
    await pumpEventQueue();

    await attention.snooze('c1', now.add(const Duration(hours: 1)));
    await pumpEventQueue();

    expect(
      notifier.cancelled,
      contains(
        agentNoticeId(
          kind: AgentNoticeKind.approvalNeeded,
          chatId: 'c1',
          approvalId: 'a1',
        ),
      ),
    );
  });

  test(
    'repeated snooze moves the deadline instead of adding a second',
    () async {
      await chat('c1');
      await reply('c1');
      await pumpEventQueue();

      await attention.snooze('c1', now.add(const Duration(hours: 1)));
      await attention.snooze('c1', now.add(const Duration(hours: 5)));
      await pumpEventQueue();

      final snooze = attention.snapshot.snoozed.single;
      expect(
        snooze.until.isAtSameMomentAs(now.add(const Duration(hours: 5))),
        isTrue,
      );
      expect(snooze.revision, 2);
    },
  );

  test('snooze rejects a past deadline and an unknown chat', () async {
    await chat('c1');
    await pumpEventQueue();

    await expectLater(
      attention.snooze('c1', now.subtract(const Duration(minutes: 1))),
      throwsA(
        isA<AgentApiException>().having(
          (error) => error.code,
          'code',
          'snooze_in_past',
        ),
      ),
    );
    await expectLater(
      attention.snooze('missing', now.add(const Duration(hours: 1))),
      throwsA(
        isA<AgentApiException>().having(
          (error) => error.code,
          'code',
          'chat_not_found',
        ),
      ),
    );
    expect(attention.snapshot.snoozed, isEmpty);
  });

  test(
    'a deadline that passed while the app was off is cleared on start',
    () async {
      await chat('c1');
      await reply('c1');
      await chats.snoozeAttention('c1', now.subtract(const Duration(hours: 1)));

      // Сервис запускается уже после срока: таймера, который его наступил, не
      // было, и просроченная строка не должна остаться навсегда.
      await attention.dispose();
      final notifier = _RecordingNotifier();
      attention = ChatAttentionService(
        chats,
        broker,
        notifier: notifier,
        now: () => now,
      );
      final due = <String>[];
      final sub = attention.due.listen(due.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();
      await pumpEventQueue();

      expect(attention.snapshot.snoozed, isEmpty);
      expect(attention.snapshot.items.single.chatId, 'c1');
      expect(due, ['c1']);
      expect(await chats.watchAttentionSnoozes().first, isEmpty);
    },
  );

  test('an expired snooze returns the chat and reminds once', () async {
    // Здесь нужны настоящие часы: срок проверяет таймер сервиса. База хранит
    // время с точностью до секунды, поэтому запас срока — больше секунды.
    await attention.dispose();
    final notifier = _RecordingNotifier();
    attention = ChatAttentionService(chats, broker, notifier: notifier);
    await chat('c1');
    await reply('c1');
    await pumpEventQueue();

    final due = <String>[];
    final sub = attention.due.listen(due.add);
    addTearDown(sub.cancel);

    await attention.snooze(
      'c1',
      DateTime.now().add(const Duration(milliseconds: 1200)),
    );
    await pumpEventQueue();
    expect(attention.snapshot.items, isEmpty);

    await Future<void>.delayed(const Duration(milliseconds: 3000));
    await pumpEventQueue();

    expect(attention.snapshot.snoozed, isEmpty);
    expect(attention.snapshot.items.single.chatId, 'c1');
    expect(due, ['c1']);
    expect(notifier.kinds, [AgentNoticeKind.snoozeDue]);
    expect(await chats.watchAttentionSnoozes().first, isEmpty);
  });

  test('re-snoozing cancels the previous due reminder', () async {
    await chat('c1');
    await reply('c1');
    await chats.snoozeAttention('c1', now.subtract(const Duration(minutes: 5)));
    await attention.dispose();
    final notifier = _RecordingNotifier();
    attention = ChatAttentionService(
      chats,
      broker,
      notifier: notifier,
      now: () => now,
    );
    await pumpEventQueue();
    await pumpEventQueue();

    final dueId = agentNoticeId(kind: AgentNoticeKind.snoozeDue, chatId: 'c1');
    expect(notifier.kinds, contains(AgentNoticeKind.snoozeDue));
    expect(notifier.notices, contains(dueId));

    // Новый срок заменяет старое напоминание: уведомление о наступившем сроке
    // не должно остаться в трее, пока чат снова молчит.
    await attention.snooze('c1', now.add(const Duration(hours: 1)));
    await pumpEventQueue();

    expect(notifier.cancelled, contains(dueId));
  });

  test('a shared pause is exposed in the snapshot and can move', () async {
    final until = now.add(const Duration(minutes: 30));
    await attention.pauseNotifications(
      until,
      reason: NotificationPauseReason.meeting,
    );
    await pumpEventQueue();

    expect(attention.isNotificationsPaused, isTrue);
    final pause = attention.snapshot.pause;
    expect(pause?.until.isAtSameMomentAs(until), isTrue);
    expect(pause?.reason, NotificationPauseReason.meeting);
    expect(pause?.revision, 1);

    final next = now.add(const Duration(hours: 2));
    await attention.pauseNotifications(
      next,
      reason: NotificationPauseReason.overnight,
    );
    await pumpEventQueue();

    expect(attention.snapshot.pause?.until.isAtSameMomentAs(next), isTrue);
    expect(attention.snapshot.pause?.revision, 2);

    await attention.resumeNotifications();
    await pumpEventQueue();

    expect(attention.snapshot.pause, isNull);
    expect(attention.isNotificationsPaused, isFalse);
  });

  test('a pause in the past is rejected instead of firing at once', () async {
    await expectLater(
      attention.pauseNotifications(now.subtract(const Duration(minutes: 1))),
      throwsA(
        isA<AgentApiException>().having(
          (error) => error.code,
          'code',
          'pause_in_past',
        ),
      ),
    );
    expect(attention.snapshot.pause, isNull);
  });

  test('a pause that expired while the app was off sends one digest', () async {
    await chat('c1');
    await reply('c1');
    await chats.setNotificationPause(
      now.subtract(const Duration(hours: 1)),
      NotificationPauseReason.overnight,
    );
    await attention.dispose();
    final notifier = _RecordingNotifier();
    attention = ChatAttentionService(
      chats,
      broker,
      notifier: notifier,
      now: () => now,
    );
    final digests = <AttentionDigest>[];
    final sub = attention.pauseDigest.listen(digests.add);
    addTearDown(sub.cancel);
    await pumpEventQueue();
    await pumpEventQueue();

    expect(attention.snapshot.pause, isNull);
    expect(notifier.kinds, [AgentNoticeKind.attentionDigest]);
    expect(digests, hasLength(1));
    expect(digests.single.newMessages, 1);
    expect(await chats.watchNotificationPause().first, isNull);
  });

  test('a pause that ends while running sends exactly one digest', () async {
    // Здесь нужны настоящие часы: срок проверяет таймер сервиса. Запас
    // больше секунды — база хранит время с точностью до секунды.
    await attention.dispose();
    final notifier = _RecordingNotifier();
    attention = ChatAttentionService(chats, broker, notifier: notifier);
    await chat('c1');
    await reply('c1');
    await pumpEventQueue();

    final digests = <AttentionDigest>[];
    final sub = attention.pauseDigest.listen(digests.add);
    addTearDown(sub.cancel);

    await attention.pauseNotifications(
      DateTime.now().add(const Duration(milliseconds: 1200)),
    );
    await pumpEventQueue();
    expect(attention.isNotificationsPaused, isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 3000));
    await pumpEventQueue();

    expect(attention.isNotificationsPaused, isFalse);
    expect(digests, hasLength(1));
    expect(
      notifier.kinds.where((kind) => kind == AgentNoticeKind.attentionDigest),
      hasLength(1),
    );
    expect(await chats.watchNotificationPause().first, isNull);
  });

  test('resuming manually does not send a digest', () async {
    await chat('c1');
    await reply('c1');
    await pumpEventQueue();
    await attention.dispose();
    final notifier = _RecordingNotifier();
    attention = ChatAttentionService(
      chats,
      broker,
      notifier: notifier,
      now: () => now,
    );
    final digests = <AttentionDigest>[];
    final sub = attention.pauseDigest.listen(digests.add);
    addTearDown(sub.cancel);
    await pumpEventQueue();

    await attention.pauseNotifications(now.add(const Duration(hours: 1)));
    await pumpEventQueue();
    await attention.resumeNotifications();
    await pumpEventQueue();

    expect(digests, isEmpty);
    expect(notifier.kinds, isEmpty);
    expect(await chats.watchNotificationPause().first, isNull);
  });
}

/// Notifier, который запоминает типы уведомлений: проверяем, что напоминание
/// о наступившем сроке действительно уходит наружу, а не остаётся снимком.
final class _RecordingNotifier implements AppNotifier {
  final kinds = <AgentNoticeKind>[];
  final notices = <String, String>{};
  final cancelled = <String>[];

  @override
  Future<void> notify({
    required AgentNoticeKind kind,
    required String chatTitle,
    String? detail,
    String? profileId,
    String? chatId,
    String? approvalId,
    String? questionId,
    String? noticeId,
  }) async {
    kinds.add(kind);
    if (noticeId != null) notices[noticeId] = chatTitle;
  }

  @override
  Future<void> cancel(String noticeId) async {
    cancelled.add(noticeId);
    notices.remove(noticeId);
  }

  @override
  Future<void> setUnreadCount(int count) => Future<void>.value();
}

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/features/chats/presentation/bloc/chat_list_cubit.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/attention_api.dart';
import 'package:pw_agent/agent/api/attention_digest_api.dart';
import 'package:pw_agent/agent/api/attention_pause_api.dart';
import 'package:pw_agent/agent/api/attention_snooze_api.dart';
import 'package:pw_agent/agent/domain/attention_digest.dart';
import 'package:pw_agent/agent/domain/chat_attention.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/notification_pause.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/core/data/chat_draft_store.dart';
import 'package:pw_agent/core/domain/host.dart';

void main() {
  test(
    'loads attention, keeps revisions monotonic and counts decisions',
    () async {
      final api = _FakeAgent();
      final cubit = ChatListCubit(api, ChatDraftStore.unbound());
      addTearDown(() async {
        await cubit.close();
        await api.dispose();
      });
      await pumpEventQueue();

      expect(cubit.state.attention.revision, 1);
      expect(cubit.state.actionableCount, 1);

      api.emit(_snapshot(revision: 2, unread: 2));
      await pumpEventQueue();
      expect(cubit.state.attention.revision, 2);
      expect(cubit.state.attention.unreadCount, 2);

      // Запоздавший ответ без решения не возвращает закрытую карточку.
      api.emit(_snapshot(revision: 1, unread: 5));
      await pumpEventQueue();
      expect(cubit.state.attention.unreadCount, isNot(5));
    },
  );

  test('snoozes and returns a chat through the agent API', () async {
    final api = _FakeAgent();
    final cubit = ChatListCubit(api, ChatDraftStore.unbound());
    addTearDown(() async {
      await cubit.close();
      await api.dispose();
    });
    await pumpEventQueue();
    expect(cubit.state.snoozeSupported, isTrue);

    final until = DateTime.utc(2026, 11, 28, 9);
    expect(await cubit.snoozeAttention('c1', until), isTrue);
    expect(api.snoozed, [('c1', until)]);

    expect(await cubit.unsnoozeAttention('c1'), isTrue);
    expect(api.unsnoozed, ['c1']);
  });

  test('pauses and resumes notifications through the agent API', () async {
    final api = _FakeAgent();
    final cubit = ChatListCubit(api, ChatDraftStore.unbound());
    addTearDown(() async {
      await cubit.close();
      await api.dispose();
    });
    await pumpEventQueue();
    expect(cubit.state.pauseSupported, isTrue);

    final until = DateTime.utc(2026, 11, 28, 9);
    expect(
      await cubit.pauseNotifications(
        until,
        reason: NotificationPauseReason.meeting,
      ),
      isTrue,
    );
    expect(api.paused, [(until, NotificationPauseReason.meeting)]);
    expect(cubit.state.attention.pause?.until.isAtSameMomentAs(until), isTrue);

    expect(await cubit.resumeNotifications(), isTrue);
    expect(api.resumed, 1);
    expect(cubit.state.attention.pause, isNull);
  });

  test('a server without snooze support hides the action', () async {
    // remote_agent_api узнаёт поддержку по полю `snoozed`: старый демон его
    // не присылает, и действие не должно обещать несуществующий маршрут.
    final api = _FakeAgent()..snoozeAvailable = false;
    final cubit = ChatListCubit(api, ChatDraftStore.unbound());
    addTearDown(() async {
      await cubit.close();
      await api.dispose();
    });
    await pumpEventQueue();

    expect(cubit.state.snoozeSupported, isFalse);
  });

  test('hides the action after the server rejects snooze', () async {
    final api = _FakeAgent()..snoozeFailure = true;
    final cubit = ChatListCubit(api, ChatDraftStore.unbound());
    addTearDown(() async {
      await cubit.close();
      await api.dispose();
    });
    await pumpEventQueue();
    expect(cubit.state.snoozeSupported, isTrue);

    final until = DateTime.utc(2026, 11, 28, 9);
    expect(await cubit.snoozeAttention('c1', until), isFalse);
    expect(cubit.state.snoozeSupported, isFalse);
  });

  test('approves and answers from the inbox through the agent API', () async {
    final api = _FakeAgent();
    final cubit = ChatListCubit(api, ChatDraftStore.unbound());
    addTearDown(() async {
      await cubit.close();
      await api.dispose();
    });
    await pumpEventQueue();

    expect(await cubit.approve('a1'), isTrue);
    expect(api.actions, [ApprovalAction.allowOnce]);

    api.failNext = true;
    expect(await cubit.deny('a2'), isFalse);
    expect(cubit.state.attentionError, contains('denied'));
  });

  test('treats a missing attention route as an unsupported server', () async {
    final api = _FakeAgent()..attentionFailure = true;
    final cubit = ChatListCubit(api, ChatDraftStore.unbound());
    addTearDown(() async {
      await cubit.close();
      await api.dispose();
    });
    await pumpEventQueue();

    expect(cubit.state.attentionSupported, isFalse);
    expect(cubit.state.snoozeSupported, isFalse);
    expect(cubit.state.attentionError, isNull);

    // Обновлённый демон отвечает снимком: экран должен снова стать рабочим.
    api.attentionFailure = false;
    await cubit.refreshAttention();
    expect(cubit.state.attentionSupported, isTrue);
    expect(cubit.state.snoozeSupported, isTrue);
    expect(cubit.state.attention.revision, 1);
  });

  test('loads and dismisses the attention digest', () async {
    final api = _FakeAgent()
      ..digestValue = const AttentionDigest(
        items: [
          AttentionDigestItem(
            chatId: 'c1',
            hostId: 'local',
            title: 'Chat',
            unreadMessages: 4,
            finishedTurns: 2,
            approvals: 1,
            problems: 1,
          ),
        ],
      );
    final cubit = ChatListCubit(api, ChatDraftStore.unbound());
    addTearDown(() async {
      await cubit.close();
      await api.dispose();
    });
    await pumpEventQueue();

    await cubit.loadDigest();
    expect(cubit.state.digest?.newMessages, 4);
    expect(cubit.state.digest?.finishedTurns, 2);

    cubit.dismissDigest();
    expect(cubit.state.digest, isNull);
  });

  test('a digest response that arrives after dismissal is ignored', () async {
    final api = _FakeAgent()
      ..digestValue = const AttentionDigest(
        items: [
          AttentionDigestItem(
            chatId: 'c1',
            hostId: 'local',
            title: 'Chat',
            unreadMessages: 1,
          ),
        ],
      );
    final cubit = ChatListCubit(api, ChatDraftStore.unbound());
    addTearDown(() async {
      await cubit.close();
      await api.dispose();
    });
    await pumpEventQueue();

    await cubit.loadDigest();
    expect(cubit.state.digest, isNotNull);

    final gate = Completer<AttentionDigest>();
    api.digestGate = gate;
    final pending = cubit.loadDigest();
    cubit.dismissDigest();

    gate.complete(api.digestValue);
    await pending;
    expect(cubit.state.digest, isNull);
  });

  test('coalesces digest requests while one is in flight', () async {
    final api = _FakeAgent();
    final cubit = ChatListCubit(api, ChatDraftStore.unbound());
    addTearDown(() async {
      await cubit.close();
      await api.dispose();
    });
    await pumpEventQueue();

    final gate = Completer<AttentionDigest>();
    api.digestGate = gate;
    final first = cubit.loadDigest();
    final second = cubit.loadDigest();
    final third = cubit.loadDigest();
    expect(api.digestCalls, 1);

    gate.complete(AttentionDigest.empty);
    await Future.wait([first, second, third]);
    await pumpEventQueue();
    // Событие в полёте даёт один трейлинг-запрос, а не запрос на каждый вызов.
    expect(api.digestCalls, 2);
  });

  test('prefers the server unread total and falls back to the chat list', () {
    final chat = Chat(
      id: 'c1',
      hostId: 'local',
      title: 'Chat',
      createdAt: DateTime.utc(2026, 11, 28),
      updatedAt: DateTime.utc(2026, 11, 28),
      lastReadSeq: 0,
      lastMessageSeq: 3,
      unreadCount: 3,
    );
    final fallback = ChatListState(chats: [chat]);
    expect(fallback.unreadCount, 3);

    // Новый сервер присылает готовую сумму: она включает отложенные чаты и
    // поэтому важнее суммы по загруженному списку.
    final server = fallback.copyWith(
      attention: const AttentionSnapshot(
        revision: 1,
        items: [],
        unreadTotal: 7,
      ),
    );
    expect(server.unreadCount, 7);
  });
}

AttentionSnapshot _snapshot({required int revision, required int unread}) =>
    AttentionSnapshot(
      revision: revision,
      items: [
        ChatAttention(
          chatId: 'c1',
          hostId: 'local',
          title: 'Chat',
          reasons: unread > 0
              ? const {ChatAttentionReason.unread}
              : const {ChatAttentionReason.approval},
          approvals: unread > 0
              ? const []
              : const [
                  ApprovalRequest(
                    id: 'a1',
                    chatId: 'c1',
                    toolName: 'run_command',
                    summary: 'ls',
                    reason: 'confirm',
                  ),
                ],
          questions: const [],
          editFileChanges: const [],
          unreadCount: unread,
          lastReadSeq: 0,
          lastMessageSeq: unread,
          running: false,
          updatedAt: DateTime.utc(2026, 11, 27),
        ),
      ],
    );

final class _FakeAgent
    implements
        AgentApi,
        AttentionApi,
        AttentionDigestApi,
        AttentionSnoozeApi,
        AttentionPauseApi {
  final _statuses = StreamController<AgentStatus>.broadcast();
  final _attention = StreamController<AttentionSnapshot>.broadcast();
  final _attentionDue = StreamController<String>.broadcast();
  final _pauseDigest = StreamController<AttentionDigest>.broadcast();
  final actions = <ApprovalAction>[];
  final snoozed = <(String, DateTime)>[];
  final unsnoozed = <String>[];
  final paused = <(DateTime, NotificationPauseReason)>[];
  var resumed = 0;
  var failNext = false;
  var attentionFailure = false;
  var snoozeAvailable = true;
  var snoozeFailure = false;
  var digestValue = AttentionDigest.empty;
  var digestCalls = 0;
  Completer<AttentionDigest>? digestGate;
  var _snapshotValue = _snapshot(revision: 1, unread: 0);

  void emit(AttentionSnapshot snapshot) {
    _snapshotValue = snapshot;
    _attention.add(snapshot);
  }

  Future<void> dispose() async {
    await _statuses.close();
    await _attention.close();
    await _attentionDue.close();
    await _pauseDigest.close();
  }

  @override
  Future<AttentionSnapshot> attention() async {
    if (attentionFailure) {
      throw const AgentApiException(
        404,
        'not_found',
        'unknown attention endpoint',
      );
    }
    return _snapshotValue;
  }

  @override
  Stream<AttentionSnapshot> get attentionChanges => _attention.stream;

  @override
  Future<void> dismissAttention(String chatId) => Future<void>.value();

  @override
  Future<void> snoozeAttention(String chatId, DateTime until) async {
    if (snoozeFailure) {
      snoozeAvailable = false;
      throw const AgentApiException(
        404,
        'not_found',
        'unknown attention endpoint',
      );
    }
    snoozed.add((chatId, until));
  }

  @override
  Future<void> unsnoozeAttention(String chatId) async {
    unsnoozed.add(chatId);
  }

  @override
  bool get supportsSnooze => snoozeAvailable;

  @override
  Stream<String> get attentionDue => _attentionDue.stream;

  @override
  bool get supportsPause => true;

  @override
  Future<void> pauseNotifications(
    DateTime until, {
    NotificationPauseReason reason = NotificationPauseReason.focus,
  }) async {
    paused.add((until, reason));
    _snapshotValue = AttentionSnapshot(
      revision: _snapshotValue.revision + 1,
      items: _snapshotValue.items,
      pause: NotificationPause(
        until: until,
        reason: reason,
        revision: _snapshotValue.pause == null
            ? 1
            : _snapshotValue.pause!.revision + 1,
      ),
    );
  }

  @override
  Future<void> resumeNotifications() async {
    resumed++;
    _snapshotValue = AttentionSnapshot(
      revision: _snapshotValue.revision + 1,
      items: _snapshotValue.items,
    );
  }

  @override
  Stream<AttentionDigest> get pauseDigestDue => _pauseDigest.stream;

  @override
  Future<AttentionDigest> attentionDigest() {
    digestCalls++;
    final gate = digestGate;
    if (gate != null) return gate.future;
    return Future.value(digestValue);
  }

  @override
  Future<void> resolveApproval(
    String id,
    ApprovalAction action, {
    String? reason,
  }) async {
    if (failNext) throw StateError('denied');
    actions.add(action);
  }

  @override
  Future<void> answerQuestion(String id, String? text, {String? answerId}) =>
      Future<void>.value();

  @override
  Future<void> resolveEditFileChanges(
    String id,
    EditFileChangesChoice choice,
  ) => Future<void>.value();

  @override
  AgentStatus get status => AgentStatus.online;

  @override
  Stream<AgentStatus> get statusChanges => _statuses.stream;

  @override
  Stream<List<Chat>> watchChats() => const Stream.empty();

  @override
  Stream<List<Host>> watchHosts() => const Stream.empty();

  @override
  Stream<AgentEvent> get events => const Stream.empty();

  @override
  Stream<ApprovalRequest> get approvals => const Stream.empty();

  @override
  Stream<UserQuestion> get questions => const Stream.empty();

  @override
  Stream<EditFileChangesRequest> get editChanges => const Stream.empty();

  @override
  Set<String> get runningChatIds => const {};

  @override
  Set<String> get waitingChatIds => const {};

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('AgentApi is not used in this test');
}

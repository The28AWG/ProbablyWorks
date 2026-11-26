import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/features/chats/presentation/bloc/chat_list_cubit.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/attention_api.dart';
import 'package:pw_agent/agent/domain/chat_attention.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
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
    expect(cubit.state.attentionError, isNull);

    // Обновлённый демон отвечает снимком: экран должен снова стать рабочим.
    api.attentionFailure = false;
    await cubit.refreshAttention();
    expect(cubit.state.attentionSupported, isTrue);
    expect(cubit.state.attention.revision, 1);
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

final class _FakeAgent implements AgentApi, AttentionApi {
  final _statuses = StreamController<AgentStatus>.broadcast();
  final _attention = StreamController<AttentionSnapshot>.broadcast();
  final actions = <ApprovalAction>[];
  var failNext = false;
  var attentionFailure = false;
  var _snapshotValue = _snapshot(revision: 1, unread: 0);

  void emit(AttentionSnapshot snapshot) {
    _snapshotValue = snapshot;
    _attention.add(snapshot);
  }

  Future<void> dispose() async {
    await _statuses.close();
    await _attention.close();
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
  Future<void> resolveApproval(
    String id,
    ApprovalAction action, {
    String? reason,
  }) async {
    if (failNext) throw StateError('denied');
    actions.add(action);
  }

  @override
  Future<void> answerQuestion(String id, String? text) => Future<void>.value();

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

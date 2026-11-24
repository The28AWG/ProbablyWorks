import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/features/chats/presentation/bloc/chat_list_cubit.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/client_session_api.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/core/data/chat_draft_store.dart';
import 'package:pw_agent/core/domain/host.dart';

void main() {
  test('keeps presence and finds other viewers of a chat', () async {
    final sessions = StreamController<List<ClientSessionView>>.broadcast();
    final cubit = ChatListCubit(
      _FakePresence(sessions.stream),
      ChatDraftStore.unbound(),
    );
    addTearDown(() async {
      await cubit.close();
      await sessions.close();
    });

    final current = _session('s1', chatId: 'c1', current: true);
    final viewer = _session('s2', chatId: 'c1', focused: true);
    final elsewhere = _session('s3', chatId: 'c2');
    final offline = _session('s4', chatId: 'c1', online: false);
    sessions.add([current, viewer, elsewhere, offline]);
    await pumpEventQueue();

    expect(cubit.state.sessions, hasLength(4));
    expect(cubit.state.viewersOf('c1'), [viewer]);
    expect(cubit.state.viewersOf('c2'), [elsewhere]);
    expect(cubit.state.otherOnlineSessions, [viewer, elsewhere]);
  });

  test('clears presence when the backend goes offline', () async {
    final sessions = StreamController<List<ClientSessionView>>.broadcast();
    final statuses = StreamController<AgentStatus>.broadcast();
    final cubit = ChatListCubit(
      _FakePresence(sessions.stream, statuses.stream),
      ChatDraftStore.unbound(),
    );
    addTearDown(() async {
      await cubit.close();
      await sessions.close();
      await statuses.close();
    });

    sessions.add([_session('s2', chatId: 'c1')]);
    await pumpEventQueue();
    expect(cubit.state.otherOnlineSessions, hasLength(1));

    statuses.add(AgentStatus.offline);
    await pumpEventQueue();
    expect(cubit.state.sessions, isEmpty);
    expect(cubit.state.otherOnlineSessions, isEmpty);
  });
}

ClientSessionView _session(
  String id, {
  String? chatId,
  bool current = false,
  bool online = true,
  bool focused = false,
}) => ClientSessionView(
  id: id,
  deviceId: id,
  clientApp: 'ProbablyWorks',
  clientVersion: '2.0.0',
  clientBuild: '1',
  clientPlatform: 'linux',
  activeChatId: chatId,
  createdAt: DateTime.utc(2026, 11, 24),
  lastSeenAt: DateTime.utc(2026, 11, 24, 12),
  expiresAt: DateTime.utc(2026, 11, 24, 12, 1),
  focused: focused,
  online: online,
  current: current,
);

final class _FakePresence implements AgentApi, ClientSessionApi {
  _FakePresence(this._sessions, [Stream<AgentStatus>? statuses])
    : _statuses = statuses ?? const Stream.empty();

  final Stream<List<ClientSessionView>> _sessions;
  final Stream<AgentStatus> _statuses;

  @override
  Stream<List<ClientSessionView>> get clientSessions => _sessions;

  @override
  Future<List<ClientSessionView>> refreshClientSessions() async => const [];

  /// Сколько раз тест попросил обновить присутствие.
  var presenceUpdates = 0;

  @override
  void setPresence({
    bool? focused,
    String? activeChatId,
    bool clearActiveChat = false,
  }) {
    presenceUpdates++;
  }

  @override
  AgentStatus get status => AgentStatus.online;

  @override
  Stream<AgentStatus> get statusChanges => _statuses;

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

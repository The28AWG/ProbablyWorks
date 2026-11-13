import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/features/chats/presentation/bloc/chat_list_cubit.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/core/data/chat_draft_store.dart';
import 'package:pw_agent/core/domain/host.dart';

void main() {
  test('clears the list when the backend goes offline', () async {
    final statuses = StreamController<AgentStatus>.broadcast();
    final chats = StreamController<List<Chat>>.broadcast();
    final hosts = StreamController<List<Host>>.broadcast();
    final api = _FakeAgent(statuses.stream, chats.stream, hosts.stream);
    final cubit = ChatListCubit(api, ChatDraftStore.unbound());
    addTearDown(() async {
      await cubit.close();
      await statuses.close();
      await chats.close();
      await hosts.close();
    });

    final chat = Chat(
      id: 'c1',
      hostId: 'local',
      title: 'Chat',
      createdAt: DateTime.utc(2026, 11, 13),
      updatedAt: DateTime.utc(2026, 11, 13),
    );
    chats.add([chat]);
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.chats, hasLength(1));

    statuses.add(AgentStatus.offline);
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.chats, isEmpty);
  });
}

final class _FakeAgent implements AgentApi {
  _FakeAgent(this._statuses, this._chats, this._hosts);

  final Stream<AgentStatus> _statuses;
  final Stream<List<Chat>> _chats;
  final Stream<List<Host>> _hosts;

  @override
  AgentStatus get status => AgentStatus.online;

  @override
  Stream<AgentStatus> get statusChanges => _statuses;

  @override
  Stream<List<Chat>> watchChats() => _chats;

  @override
  Stream<List<Host>> watchHosts() => _hosts;

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

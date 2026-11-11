import 'dart:async';

import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/agent/schedule/scheduled_task.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_client/pw_client.dart';
import 'package:pw_server/pw_server.dart';
import 'package:test/test.dart';

const _token = 'client-token';

void main() {
  late _FakeAgent backend;
  late ApiServer server;
  late RemoteAgentApi remote;

  setUp(() async {
    backend = _FakeAgent();
    server = ApiServer(backend, _token, port: 0);
    final port = await server.start();
    remote = RemoteAgentApi(
      baseUri: Uri.parse('http://127.0.0.1:$port'),
      token: _token,
    );
  });

  tearDown(() async {
    await remote.dispose();
    await server.stop();
    await backend.dispose();
  });

  test('reads chats, hosts and journal', () async {
    final chats = await remote.chats();
    final hosts = await remote.hosts();
    final messages = await remote.messages('c1');
    final runs = await remote.runs('c1');

    expect(chats.single.title, 'Test chat');
    expect(hosts.single.id, 'local');
    expect(messages.single.text, 'hello');
    expect(runs, isEmpty);
  });

  test('sends a message and resolves a card', () async {
    await remote.send('c1', 'do it', sendNow: true);
    await remote.resolveApproval('a1', ApprovalAction.allowTurn);
    await remote.answerQuestion('q1', 'yes');

    expect(backend.sent, [('c1', 'do it', true)]);
    expect(backend.decisions, [ApprovalAction.allowTurn]);
    expect(backend.answers, ['yes']);
  });

  test('creates and reads a schedule', () async {
    final task = await remote.schedule(
      chatId: 'c1',
      prompt: 'later',
      dueAt: DateTime.utc(2030),
    );
    final fetched = await remote.scheduledTask(task.id);

    expect(fetched?.prompt, 'later');
    expect(fetched?.dueAt.isUtc, isTrue);
  });

  test('maps missing resources to null and 404 errors', () async {
    expect(await remote.chat('missing'), isNull);
    expect(await remote.scheduledTask('missing'), isNull);
    await expectLater(
      remote.messages('missing'),
      throwsA(
        isA<AgentApiException>().having((error) => error.status, 'status', 404),
      ),
    );
  });

  test('streams SSE events into typed streams', () async {
    final events = <AgentEvent>[];
    final approvals = <ApprovalRequest>[];
    final eventsSub = remote.events.listen(events.add);
    final approvalsSub = remote.approvals.listen(approvals.add);
    addTearDown(eventsSub.cancel);
    addTearDown(approvalsSub.cancel);

    await remote.startEvents();
    await remote.eventsReady.timeout(const Duration(seconds: 3));
    backend
      ..emit(const AgentTurnStarted('c1'))
      ..emit(
        const ApprovalRequest(
          id: 'a1',
          chatId: 'c1',
          toolName: 'run_command',
          summary: 'ls',
          reason: 'ask',
        ),
      );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(events.single, isA<AgentTurnStarted>());
    expect(approvals.single.id, 'a1');
  });
}

final class _FakeAgent implements AgentApi {
  final _events = StreamController<AgentEvent>.broadcast();
  final _approvals = StreamController<ApprovalRequest>.broadcast();
  final _questions = StreamController<UserQuestion>.broadcast();
  final _editChanges = StreamController<EditFileChangesRequest>.broadcast();

  final sent = <(String, String, bool)>[];
  final decisions = <ApprovalAction>[];
  final answers = <String?>[];
  final scheduled = <ScheduledTask>[];

  final _chat = Chat(
    id: 'c1',
    hostId: 'local',
    title: 'Test chat',
    createdAt: DateTime.utc(2026, 11, 11),
    updatedAt: DateTime.utc(2026, 11, 11),
  );

  void emit(Object event) {
    switch (event) {
      case AgentEvent value:
        _events.add(value);
      case ApprovalRequest value:
        _approvals.add(value);
      case UserQuestion value:
        _questions.add(value);
      case EditFileChangesRequest value:
        _editChanges.add(value);
    }
  }

  Future<void> dispose() async {
    await _events.close();
    await _approvals.close();
    await _questions.close();
    await _editChanges.close();
  }

  @override
  Set<String> get runningChatIds => const {};

  @override
  Set<String> get waitingChatIds => const {};

  @override
  Stream<List<Chat>> watchChats() => Stream.value([_chat]);

  @override
  Stream<List<Host>> watchHosts() => Stream.value(const []);

  @override
  Stream<AgentEvent> get events => _events.stream;

  @override
  Stream<ApprovalRequest> get approvals => _approvals.stream;

  @override
  Stream<UserQuestion> get questions => _questions.stream;

  @override
  Stream<EditFileChangesRequest> get editChanges => _editChanges.stream;

  @override
  Future<List<Host>> hosts() async => [
    Host(
      id: 'local',
      name: 'Local',
      kind: HostKind.local,
      createdAt: DateTime.utc(2026, 11, 11),
      updatedAt: DateTime.utc(2026, 11, 11),
    ),
  ];

  @override
  Future<List<Chat>> chats() async => [_chat];

  @override
  Future<Chat?> chat(String id) async => id == 'c1' ? _chat : null;

  @override
  Future<Chat> createChat(String hostId) async => _chat.copyWith(id: 'c2');

  @override
  Future<void> renameChat(String chatId, String title) => Future<void>.value();

  @override
  Future<Chat?> forkChat(String chatId, {String? title}) async => _chat;

  @override
  Future<void> deleteChat(String chatId) => Future<void>.value();

  @override
  Future<List<ChatMessage>> messages(String chatId) async {
    if (chatId != 'c1') {
      throw AgentApiException(404, 'chat_not_found', 'chat $chatId not found');
    }
    return [
      ChatMessage(
        id: 'm1',
        chatId: chatId,
        seq: 1,
        role: MessageRole.user,
        createdAt: DateTime.utc(2026, 11, 11),
        text: 'hello',
      ),
    ];
  }

  @override
  Future<List<ToolRun>> runs(String chatId) async {
    if (chatId != 'c1') {
      throw AgentApiException(404, 'chat_not_found', 'chat $chatId not found');
    }
    return const [];
  }

  @override
  Future<void> openChat(String chatId) => Future<void>.value();

  @override
  Future<void> send(String chatId, String text, {bool sendNow = false}) async {
    sent.add((chatId, text, sendNow));
  }

  @override
  Future<void> stop(String chatId, {String? reason}) => Future<void>.value();

  @override
  Future<void> resolveApproval(
    String id,
    ApprovalAction action, {
    String? reason,
  }) async {
    decisions.add(action);
  }

  @override
  Future<void> answerQuestion(String id, String? text) async {
    answers.add(text);
  }

  @override
  Future<void> resolveEditFileChanges(
    String id,
    EditFileChangesChoice choice,
  ) => Future<void>.value();

  @override
  Future<List<ApprovalRequest>> pendingApprovals(String chatId) async =>
      const [];

  @override
  Future<List<UserQuestion>> pendingQuestions(String chatId) async => const [];

  @override
  Future<List<EditFileChangesRequest>> pendingEditFileChanges(
    String chatId,
  ) async => const [];

  @override
  Future<List<ScheduledTask>> schedules() async => scheduled;

  @override
  Future<ScheduledTask?> scheduledTask(String id) async {
    for (final task in scheduled) {
      if (task.id == id) return task;
    }
    return null;
  }

  @override
  Future<ScheduledTask> schedule({
    required String chatId,
    required String prompt,
    required DateTime dueAt,
  }) async {
    final task = ScheduledTask(
      id: 's1',
      chatId: chatId,
      prompt: prompt,
      dueAt: dueAt,
      status: ScheduledTaskStatus.pending,
      createdAt: DateTime.utc(2026, 11, 11),
      updatedAt: DateTime.utc(2026, 11, 11),
    );
    scheduled.add(task);
    return task;
  }

  @override
  Future<void> cancelSchedule(String id) => Future<void>.value();
}

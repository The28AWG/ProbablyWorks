import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/agent/schedule/scheduled_task.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_server/pw_server.dart';
import 'package:test/test.dart';

const _token = 'test-token';

void main() {
  late _FakeBackend backend;
  late ApiServer server;
  late HttpClient client;
  late String base;

  setUp(() async {
    backend = _FakeBackend();
    server = ApiServer(backend, _token, port: 0);
    final port = await server.start();
    base = 'http://127.0.0.1:$port';
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    await backend.dispose();
  });

  test('health is open and reports ok', () async {
    final (status, body) = await _request(
      client,
      base,
      'GET',
      '/api/v1/health',
    );

    expect(status, HttpStatus.ok);
    expect(jsonDecode(body), containsPair('ok', true));
  });

  test('protected endpoints require a bearer token', () async {
    final (status, body) = await _request(client, base, 'GET', '/api/v1/chats');

    expect(status, HttpStatus.unauthorized);
    expect(jsonDecode(body), contains('error'));
  });

  test('wrong token is rejected', () async {
    final (status, _) = await _request(
      client,
      base,
      'GET',
      '/api/v1/chats',
      token: 'wrong',
    );

    expect(status, HttpStatus.unauthorized);
  });

  test('lists main chats', () async {
    final (status, body) = await _request(
      client,
      base,
      'GET',
      '/api/v1/chats',
      token: _token,
    );

    expect(status, HttpStatus.ok);
    final chats = (jsonDecode(body) as Map)['chats'] as List;
    expect(chats, hasLength(1));
    expect(chats.single['title'], 'Test chat');
  });

  test('lists hosts and creates a chat', () async {
    final (hostsStatus, hostsBody) = await _request(
      client,
      base,
      'GET',
      '/api/v1/hosts',
      token: _token,
    );
    final (createStatus, createBody) = await _request(
      client,
      base,
      'POST',
      '/api/v1/chats',
      token: _token,
      body: {'hostId': 'local'},
    );

    expect(hostsStatus, HttpStatus.ok);
    expect((jsonDecode(hostsBody) as Map)['hosts'], hasLength(1));
    expect(createStatus, HttpStatus.created);
    expect((jsonDecode(createBody) as Map)['hostId'], 'local');
  });

  test('unknown chat subresources return 404', () async {
    for (final path in [
      '/api/v1/chats/missing/messages',
      '/api/v1/chats/missing/runs',
      '/api/v1/chats/missing/events',
    ]) {
      final (status, _) = await _request(
        client,
        base,
        'GET',
        path,
        token: _token,
      );
      expect(status, HttpStatus.notFound, reason: path);
    }
  });

  test('unknown host is rejected when creating a chat', () async {
    final (status, body) = await _request(
      client,
      base,
      'POST',
      '/api/v1/chats',
      token: _token,
      body: {'hostId': 'missing'},
    );

    expect(status, HttpStatus.notFound);
    expect((jsonDecode(body) as Map)['error'], contains('code'));
  });

  test('returns chat journal and pending cards', () async {
    final (status, body) = await _request(
      client,
      base,
      'GET',
      '/api/v1/chats/c1',
      token: _token,
    );

    expect(status, HttpStatus.ok);
    final json = jsonDecode(body) as Map;
    expect((json['messages'] as List).single['text'], 'hello');
    expect((json['approvals'] as List).single['id'], 'a1');
    expect((json['questions'] as List).single['text'], 'continue?');
  });

  test('accepts a message and forwards sendNow', () async {
    final (status, _) = await _request(
      client,
      base,
      'POST',
      '/api/v1/chats/c1/messages',
      token: _token,
      body: {'text': 'do it', 'sendNow': true},
    );

    expect(status, HttpStatus.accepted);
    expect(backend.sent, [('c1', 'do it', true)]);
  });

  test('resolves approvals with the requested scope', () async {
    final (status, _) = await _request(
      client,
      base,
      'PUT',
      '/api/v1/approvals/a1/decision',
      token: _token,
      body: {'action': 'allowTurn'},
    );

    expect(status, HttpStatus.noContent);
    expect(backend.decisions, [ApprovalAction.allowTurn]);
  });

  test('exposes messages and runs as subresources', () async {
    final (messagesStatus, messagesBody) = await _request(
      client,
      base,
      'GET',
      '/api/v1/chats/c1/messages',
      token: _token,
    );
    final (runsStatus, runsBody) = await _request(
      client,
      base,
      'GET',
      '/api/v1/chats/c1/runs',
      token: _token,
    );

    expect(messagesStatus, HttpStatus.ok);
    expect((jsonDecode(messagesBody) as Map)['messages'], hasLength(1));
    expect(runsStatus, HttpStatus.ok);
    expect((jsonDecode(runsBody) as Map)['runs'], isEmpty);
  });

  test('uses resources for presence and stopping a turn', () async {
    final (presence, _) = await _request(
      client,
      base,
      'PUT',
      '/api/v1/chats/c1/presence',
      token: _token,
    );
    final (turn, _) = await _request(
      client,
      base,
      'DELETE',
      '/api/v1/chats/c1/turn',
      token: _token,
    );

    expect(presence, HttpStatus.noContent);
    expect(turn, HttpStatus.noContent);
    expect(backend.opened, 1);
    expect(backend.stopped, 1);
  });

  test('answers questions and resolves edit changes', () async {
    final (answer, _) = await _request(
      client,
      base,
      'PUT',
      '/api/v1/questions/q1/answer',
      token: _token,
      body: {'answer': 'yes'},
    );
    final (choice, _) = await _request(
      client,
      base,
      'PUT',
      '/api/v1/edit-file-changes/e1/decision',
      token: _token,
      body: {'choice': 'cancel'},
    );

    expect(answer, HttpStatus.noContent);
    expect(choice, HttpStatus.noContent);
    expect(backend.answers, ['yes']);
    expect(backend.choices, [EditFileChangesChoice.cancel]);
  });

  test('creates a scheduled task', () async {
    final dueAt = DateTime(2026, 11, 12, 9);
    final (status, body) = await _request(
      client,
      base,
      'POST',
      '/api/v1/schedules',
      token: _token,
      body: {
        'chatId': 'c1',
        'prompt': 'later',
        'dueAt': dueAt.toIso8601String(),
      },
    );

    expect(status, HttpStatus.created);
    expect((jsonDecode(body) as Map)['prompt'], 'later');
    expect(backend.scheduled, hasLength(1));
  });

  test('streams more than one event on the same connection', () async {
    final request = await client.getUrl(
      Uri.parse('$base/api/v1/events?chatId=c1'),
    );
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
    final response = await request.close();
    final lines = StreamIterator(
      response
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(const Duration(seconds: 3)),
    );
    expect(await lines.moveNext(), isTrue);
    expect(lines.current, ': connected');

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

    final data = <String>[];
    while (await lines.moveNext()) {
      if (lines.current.startsWith('data:')) data.add(lines.current);
      if (data.length == 2) break;
    }
    await lines.cancel();
    expect(data, hasLength(2));
  });

  test('serializes schedule timestamps as UTC', () async {
    final local = DateTime(2030, 1, 1, 5);
    backend.scheduled.add(
      ScheduledTask(
        id: 'local',
        chatId: 'c1',
        prompt: 'later',
        dueAt: local,
        status: ScheduledTaskStatus.pending,
        createdAt: local,
        updatedAt: local,
      ),
    );

    final (status, body) = await _request(
      client,
      base,
      'GET',
      '/api/v1/schedules/local',
      token: _token,
    );

    expect(status, HttpStatus.ok);
    final dueRaw = (jsonDecode(body) as Map)['dueAt'] as String;
    expect(dueRaw, endsWith('Z'));
    expect(DateTime.parse(dueRaw).isAtSameMomentAs(local), isTrue);
  });

  test('returns 404 for an unknown schedule', () async {
    final (status, body) = await _request(
      client,
      base,
      'GET',
      '/api/v1/schedules/missing',
      token: _token,
    );

    expect(status, HttpStatus.notFound);
    expect((jsonDecode(body) as Map)['error'], contains('code'));
  });

  test('streams agent events over SSE', () async {
    final request = await client.getUrl(
      Uri.parse('$base/api/v1/events?chatId=c1'),
    );
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
    final response = await request.close();
    final lines = StreamIterator(
      response
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(const Duration(seconds: 3)),
    );
    // Первая строка подтверждает, что сервер подписался на события.
    expect(await lines.moveNext(), isTrue);
    expect(lines.current, ': connected');
    backend.emit(const AgentTurnStarted('c1'));

    String? event;
    String? data;
    while (await lines.moveNext()) {
      if (lines.current.startsWith('event:')) event = lines.current;
      if (lines.current.startsWith('data:')) data = lines.current;
      if (event != null && data != null) break;
    }
    await lines.cancel();
    expect(event, 'event: turnStarted');
    expect(jsonDecode(data!.replaceFirst('data: ', ''))['chatId'], 'c1');
  });
}

Future<(int, String)> _request(
  HttpClient client,
  String base,
  String method,
  String path, {
  String? token,
  Object? body,
}) async {
  final request = await client.openUrl(method, Uri.parse('$base$path'));
  if (token != null) {
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  }
  if (body != null) {
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
  }
  final response = await request.close();
  return (response.statusCode, await utf8.decoder.bind(response).join());
}

final class _FakeBackend implements AgentApi {
  final _events = StreamController<AgentEvent>.broadcast();
  final _approvals = StreamController<ApprovalRequest>.broadcast();
  final _questions = StreamController<UserQuestion>.broadcast();
  final _editChanges = StreamController<EditFileChangesRequest>.broadcast();
  final sent = <(String, String, bool)>[];
  final decisions = <ApprovalAction>[];
  final scheduled = <ScheduledTask>[];
  final answers = <String?>[];
  final choices = <EditFileChangesChoice>[];
  var opened = 0;
  var stopped = 0;

  final _chat = Chat(
    id: 'c1',
    hostId: 'local',
    title: 'Test chat',
    createdAt: DateTime(2026, 11, 11),
    updatedAt: DateTime(2026, 11, 11),
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
  Future<List<Host>> hosts() async => [
    Host(
      id: 'local',
      name: 'Local',
      kind: HostKind.local,
      createdAt: DateTime(2026, 11, 11),
      updatedAt: DateTime(2026, 11, 11),
    ),
  ];

  @override
  Future<List<Chat>> chats() async => [_chat];

  @override
  Future<Chat> createChat(String hostId) async {
    if (hostId != 'local') {
      throw AgentApiException(404, 'host_not_found', 'host $hostId not found');
    }
    return Chat(
      id: 'c2',
      hostId: hostId,
      title: '',
      createdAt: DateTime(2026, 11, 11),
      updatedAt: DateTime(2026, 11, 11),
    );
  }

  @override
  Future<Chat?> chat(String id) async => id == 'c1' ? _chat : null;

  @override
  Future<List<ChatMessage>> messages(String id) async {
    if (id != 'c1') {
      throw AgentApiException(404, 'chat_not_found', 'chat $id not found');
    }
    return [
      ChatMessage(
        id: 'm1',
        chatId: id,
        seq: 1,
        role: MessageRole.user,
        createdAt: DateTime(2026, 11, 11),
        text: 'hello',
      ),
    ];
  }

  @override
  Future<List<ToolRun>> runs(String id) async {
    if (id != 'c1') {
      throw AgentApiException(404, 'chat_not_found', 'chat $id not found');
    }
    return const [];
  }

  @override
  Future<void> openChat(String id) async {
    opened++;
  }

  @override
  Future<void> send(String chatId, String text, {bool sendNow = false}) async {
    sent.add((chatId, text, sendNow));
  }

  @override
  Future<void> stop(String chatId) async {
    stopped++;
  }

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
  ) async {
    choices.add(choice);
  }

  @override
  Future<List<ApprovalRequest>> pendingApprovals(String chatId) async => const [
    ApprovalRequest(
      id: 'a1',
      chatId: 'c1',
      toolName: 'run_command',
      summary: 'ls',
      reason: 'ask',
    ),
  ];

  @override
  Future<List<UserQuestion>> pendingQuestions(String chatId) async => const [
    UserQuestion(id: 'q1', chatId: 'c1', text: 'continue?'),
  ];

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
      createdAt: DateTime(2026, 11, 11),
      updatedAt: DateTime(2026, 11, 11),
    );
    scheduled.add(task);
    return task;
  }

  @override
  Future<void> cancelSchedule(String id) => Future<void>.value();

  @override
  Stream<AgentEvent> get events => _events.stream;

  @override
  Stream<ApprovalRequest> get approvals => _approvals.stream;

  @override
  Stream<UserQuestion> get questions => _questions.stream;

  @override
  Stream<EditFileChangesRequest> get editChanges => _editChanges.stream;
}

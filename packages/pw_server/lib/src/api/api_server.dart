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

/// Локальный HTTP API поверх агента.
///
/// По умолчанию слушает loopback. Авторизация — `Authorization: Bearer <token>`.
/// API не запускает команды само: все действия идут через [AgentApi], а значит
/// через policy и карточки подтверждения.
final class ApiServer {
  ApiServer(
    this._backend,
    this._token, {
    InternetAddress? address,
    this._port = 7787,
  }) : _address = address ?? InternetAddress.loopbackIPv4;

  static const _maxBodyBytes = 1 << 20;
  static const _eventHeartbeat = Duration(seconds: 15);

  final AgentApi _backend;
  final String _token;
  final InternetAddress _address;
  final int _port;

  HttpServer? _server;
  final _clients = <HttpResponse>{};

  /// Запускает сервер и возвращает фактический порт (0 превращается в выбранный ОС).
  Future<int> start() async {
    if (_server != null) throw StateError('API server is already running');
    final server = await HttpServer.bind(_address, _port);
    _server = server;
    server
      ..idleTimeout = const Duration(seconds: 30)
      ..listen(_handle);
    return server.port;
  }

  Future<void> stop() async {
    for (final response in [..._clients]) {
      await response.close();
    }
    _clients.clear();
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.method == 'GET' && request.uri.path == '/api/v1/health') {
        _json(response, HttpStatus.ok, {'ok': true, 'version': '1'});
        return;
      }
      if (!_authorized(request)) {
        response.headers.set(
          HttpHeaders.wwwAuthenticateHeader,
          'Bearer realm="probablyworks"',
        );
        _error(
          response,
          HttpStatus.unauthorized,
          'unauthorized',
          'invalid token',
        );
        return;
      }
      await _route(request);
    } on AgentApiException catch (error) {
      _error(response, error.status, error.code, error.message);
    } on FormatException catch (error) {
      _error(response, HttpStatus.badRequest, 'bad_json', error.message);
    } on Object catch (error) {
      _error(
        response,
        HttpStatus.internalServerError,
        'internal_error',
        '$error',
      );
    } finally {
      try {
        await response.close();
      } on Object {
        // Соединение уже закрыто клиентом (например, SSE).
      }
    }
  }

  Future<void> _route(HttpRequest request) async {
    final path = request.uri.pathSegments;
    if (path.length < 3 || path.first != 'api' || path[1] != 'v1') {
      throw const AgentApiException(
        HttpStatus.notFound,
        'not_found',
        'unknown endpoint',
      );
    }
    final rest = path.sublist(3);
    switch (path[2]) {
      case 'hosts':
        if (rest.isEmpty && request.method == 'GET') return _hosts(request);
      case 'chats':
        return _routeChats(request, rest);
      case 'approvals':
        if (rest.length == 2 &&
            rest[1] == 'decision' &&
            request.method == 'PUT') {
          return _approval(request, rest.first);
        }
      case 'questions':
        if (rest.length == 2 &&
            rest[1] == 'answer' &&
            request.method == 'PUT') {
          return _answer(request, rest.first);
        }
      case 'edit-file-changes':
        if (rest.length == 2 &&
            rest[1] == 'decision' &&
            request.method == 'PUT') {
          return _editFileChanges(request, rest.first);
        }
      case 'schedules':
        if (rest.isEmpty && request.method == 'GET') return _schedules(request);
        if (rest.isEmpty && request.method == 'POST') return _schedule(request);
        if (rest.length == 1 && request.method == 'GET') {
          return _scheduleItem(request, rest.first);
        }
        if (rest.length == 1 && request.method == 'DELETE') {
          await _backend.cancelSchedule(rest.first);
          return _json(request.response, HttpStatus.noContent, {});
        }
      case 'events':
        if (rest.isEmpty && request.method == 'GET') return _events(request);
    }
    throw const AgentApiException(
      HttpStatus.notFound,
      'not_found',
      'unknown endpoint',
    );
  }

  Future<void> _routeChats(HttpRequest request, List<String> rest) async {
    if (rest.isEmpty && request.method == 'GET') return _chats(request);
    if (rest.isEmpty && request.method == 'POST') return _createChat(request);
    if (rest.length == 1 && request.method == 'GET') {
      return _chat(request, rest.first);
    }
    if (rest.length == 2) {
      final chatId = rest.first;
      switch (rest[1]) {
        case 'messages':
          if (request.method == 'GET') return _messages(request, chatId);
          if (request.method == 'POST') return _send(request, chatId);
        case 'runs':
          if (request.method == 'GET') return _runs(request, chatId);
        case 'events':
          if (request.method == 'GET') {
            return _events(request, chatId: chatId);
          }
        case 'presence':
          if (request.method == 'PUT') {
            await _backend.openChat(chatId);
            return _json(request.response, HttpStatus.noContent, {});
          }
        case 'turn':
          if (request.method == 'DELETE') {
            await _backend.stop(chatId);
            return _json(request.response, HttpStatus.noContent, {});
          }
      }
    }
    throw const AgentApiException(
      HttpStatus.notFound,
      'not_found',
      'unknown chat endpoint',
    );
  }

  Future<void> _hosts(HttpRequest request) async {
    final hosts = await _backend.hosts();
    _json(request.response, HttpStatus.ok, {
      'hosts': [for (final host in hosts) _hostJson(host)],
    });
  }

  Future<void> _chats(HttpRequest request) async {
    final chats = await _backend.chats();
    _json(request.response, HttpStatus.ok, {
      'chats': [for (final chat in chats) _chatJson(chat)],
    });
  }

  Future<void> _createChat(HttpRequest request) async {
    final body = await _body(request);
    final chat = await _backend.createChat(_string(body, 'hostId'));
    _json(request.response, HttpStatus.created, _chatJson(chat));
  }

  Future<void> _chat(HttpRequest request, String id) async {
    final chat = await _backend.chat(id);
    if (chat == null) {
      throw AgentApiException(
        HttpStatus.notFound,
        'chat_not_found',
        'chat $id not found',
      );
    }
    final messages = await _backend.messages(id);
    final runs = await _backend.runs(id);
    final approvals = await _backend.pendingApprovals(id);
    final questions = await _backend.pendingQuestions(id);
    final edits = await _backend.pendingEditFileChanges(id);
    _json(request.response, HttpStatus.ok, {
      'chat': _chatJson(chat),
      'messages': [for (final message in messages) _messageJson(message)],
      'runs': [for (final run in runs) _runJson(run)],
      'approvals': [for (final approval in approvals) _approvalJson(approval)],
      'questions': [for (final question in questions) _questionJson(question)],
      'editFileChanges': [for (final edit in edits) _editJson(edit)],
    });
  }

  Future<void> _messages(HttpRequest request, String chatId) async {
    final messages = await _backend.messages(chatId);
    _json(request.response, HttpStatus.ok, {
      'messages': [for (final message in messages) _messageJson(message)],
    });
  }

  Future<void> _runs(HttpRequest request, String chatId) async {
    final runs = await _backend.runs(chatId);
    _json(request.response, HttpStatus.ok, {
      'runs': [for (final run in runs) _runJson(run)],
    });
  }

  Future<void> _send(HttpRequest request, String chatId) async {
    final body = await _body(request);
    final text = _string(body, 'text');
    await _backend.send(chatId, text, sendNow: body['sendNow'] == true);
    _json(request.response, HttpStatus.accepted, {'ok': true});
  }

  Future<void> _approval(HttpRequest request, String id) async {
    final body = await _body(request);
    final action = switch (_string(body, 'action')) {
      'allowOnce' => ApprovalAction.allowOnce,
      'allowTurn' => ApprovalAction.allowTurn,
      'allowChat' => ApprovalAction.allowChat,
      'deny' => ApprovalAction.deny,
      final value => throw AgentApiException(
        HttpStatus.badRequest,
        'bad_action',
        'unknown approval action: $value',
      ),
    };
    await _backend.resolveApproval(
      id,
      action,
      reason: body['reason'] is String ? body['reason'] as String : null,
    );
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _answer(HttpRequest request, String id) async {
    final body = await _body(request);
    final value = body['answer'];
    await _backend.answerQuestion(id, value is String ? value : null);
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _editFileChanges(HttpRequest request, String id) async {
    final body = await _body(request);
    final choice = switch (_string(body, 'choice')) {
      'rollbackAndContinue' => EditFileChangesChoice.rollbackAndContinue,
      'continueWithoutRollback' =>
        EditFileChangesChoice.continueWithoutRollback,
      'cancel' => EditFileChangesChoice.cancel,
      final value => throw AgentApiException(
        HttpStatus.badRequest,
        'bad_choice',
        'unknown choice: $value',
      ),
    };
    await _backend.resolveEditFileChanges(id, choice);
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _scheduleItem(HttpRequest request, String id) async {
    final task = await _backend.scheduledTask(id);
    if (task == null) {
      throw AgentApiException(
        HttpStatus.notFound,
        'schedule_not_found',
        'schedule $id not found',
      );
    }
    _json(request.response, HttpStatus.ok, _taskJson(task));
  }

  Future<void> _schedules(HttpRequest request) async {
    final tasks = await _backend.schedules();
    _json(request.response, HttpStatus.ok, {
      'schedules': [for (final task in tasks) _taskJson(task)],
    });
  }

  Future<void> _schedule(HttpRequest request) async {
    final body = await _body(request);
    final dueAtRaw = _string(body, 'dueAt');
    final dueAt = DateTime.tryParse(dueAtRaw);
    if (dueAt == null) {
      throw const AgentApiException(
        HttpStatus.badRequest,
        'bad_due_at',
        'dueAt must be an ISO-8601 date',
      );
    }
    final task = await _backend.schedule(
      chatId: _string(body, 'chatId'),
      prompt: _string(body, 'prompt'),
      dueAt: dueAt,
    );
    _json(request.response, HttpStatus.created, _taskJson(task));
  }

  /// SSE-поток всех событий или одного чата (`?chatId=`).
  Future<void> _events(HttpRequest request, {String? chatId}) async {
    final response = request.response;
    final filterChatId = chatId ?? request.uri.queryParameters['chatId'];
    if (filterChatId != null && await _backend.chat(filterChatId) == null) {
      throw AgentApiException(
        HttpStatus.notFound,
        'chat_not_found',
        'chat $filterChatId not found',
      );
    }
    response
      ..bufferOutput = false
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      )
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-cache')
      ..headers.set(HttpHeaders.connectionHeader, 'keep-alive');
    _clients.add(response);
    final subscription = _allEvents().listen((event) {
      if (!_matchesChat(event, filterChatId)) return;
      final encoded = _event(event);
      response.write(
        'event: ${encoded.$1}\ndata: ${jsonEncode(encoded.$2)}\n\n',
      );
    });
    response.write(': connected\n\n');
    await response.flush();
    final heartbeat = Timer.periodic(_eventHeartbeat, (_) {
      response.write(': ping\n\n');
    });
    try {
      await response.done;
    } on Object {
      // Клиент закрыл соединение.
    } finally {
      heartbeat.cancel();
      await subscription.cancel();
      _clients.remove(response);
    }
  }

  /// Склеивает журнал и карточки в один поток для SSE.
  Stream<Object> _allEvents() {
    final controller = StreamController<Object>();
    final subscriptions = <StreamSubscription<dynamic>>[
      _backend.events.listen(controller.add),
      _backend.approvals.listen(controller.add),
      _backend.questions.listen(controller.add),
      _backend.editChanges.listen(controller.add),
    ];
    controller.onCancel = () async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    };
    return controller.stream;
  }

  Future<Map<String, dynamic>> _body(HttpRequest request) async {
    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
      if (bytes.length > _maxBodyBytes) {
        throw const AgentApiException(
          HttpStatus.requestEntityTooLarge,
          'body_too_large',
          'request body is too large',
        );
      }
    }
    if (bytes.isEmpty) return const {};
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw const AgentApiException(
        HttpStatus.badRequest,
        'bad_json',
        'expected a JSON object',
      );
    }
    return Map<String, dynamic>.from(decoded);
  }

  bool _authorized(HttpRequest request) {
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    if (header == null || !header.startsWith('Bearer ')) return false;
    final value = header.replaceFirst('Bearer ', '');
    if (value.length != _token.length) return false;
    var different = 0;
    for (var i = 0; i < value.length; i++) {
      different |= value.codeUnitAt(i) ^ _token.codeUnitAt(i);
    }
    return different == 0;
  }

  static String _string(Map<String, dynamic> body, String key) {
    final value = body[key];
    if (value is String && value.isNotEmpty) return value;
    throw AgentApiException(
      HttpStatus.badRequest,
      'missing_field',
      'expected non-empty string field "$key"',
    );
  }

  static void _json(HttpResponse response, int status, Object body) {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    if (status != HttpStatus.noContent) response.write(jsonEncode(body));
  }

  static void _error(
    HttpResponse response,
    int status,
    String code,
    String message,
  ) {
    _json(response, status, {
      'error': {'code': code, 'message': message},
    });
  }
}

Map<String, Object?> _hostJson(Host host) => {
  'id': host.id,
  'name': host.name,
  'kind': host.kind.name,
  'address': host.address,
  'port': host.port,
  'username': host.username,
  'os': host.os.name,
  'defaultWorkspace': host.defaultWorkspace,
  'notes': host.notes,
};

Map<String, Object?> _chatJson(Chat chat) => {
  'id': chat.id,
  'hostId': chat.hostId,
  'projectId': chat.projectId,
  'kind': chat.kind.name,
  'parentChatId': chat.parentChatId,
  'rootChatId': chat.rootChatId,
  'depth': chat.depth,
  'title': chat.title,
  'titleSource': chat.titleSource.name,
  'model': chat.model,
  'policyMode': chat.policyMode.name,
  'workspace': chat.workspace,
  'lastPromptTokens': chat.lastPromptTokens,
  'lastCompletionTokens': chat.lastCompletionTokens,
  'contextLength': chat.contextLength,
  'createdAt': chat.createdAt.toUtc().toIso8601String(),
  'updatedAt': chat.updatedAt.toUtc().toIso8601String(),
};

Map<String, Object?> _messageJson(ChatMessage message) => {
  'id': message.id,
  'chatId': message.chatId,
  'seq': message.seq,
  'role': message.role.name,
  'text': message.text,
  'reasoning': message.reasoning,
  'toolCalls': [
    for (final call in message.toolCalls)
      {'id': call.id, 'name': call.name, 'arguments': call.arguments},
  ],
  'toolCallId': message.toolCallId,
  'attachments': [
    for (final attachment in message.attachments)
      {
        'name': attachment.name,
        'mode': attachment.mode.name,
        'mimeType': attachment.mimeType,
        'sizeBytes': attachment.sizeBytes,
      },
  ],
  'createdAt': message.createdAt.toUtc().toIso8601String(),
};

Map<String, Object?> _runJson(ToolRun run) => {
  'id': run.id,
  'chatId': run.chatId,
  'messageId': run.messageId,
  'toolName': run.toolName,
  'argsJson': run.argsJson,
  'command': run.command,
  'background': run.background,
  'status': run.status.name,
  'pid': run.pid,
  'exitCode': run.exitCode,
  'timedOut': run.timedOut,
  'outputText': run.outputText,
  'outputTruncated': run.outputTruncated,
  'resultPreview': run.resultPreview,
  'startedAt': run.startedAt.toUtc().toIso8601String(),
  'finishedAt': run.finishedAt?.toUtc().toIso8601String(),
  'toolCallId': run.toolCallId,
  'pendingCard': run.pendingCard == null ? null : jsonDecode(run.pendingCard!),
};

Map<String, Object?> _taskJson(ScheduledTask task) => {
  'id': task.id,
  'chatId': task.chatId,
  'prompt': task.prompt,
  'dueAt': task.dueAt.toUtc().toIso8601String(),
  'status': task.status.name,
  'error': task.error,
  'createdAt': task.createdAt.toUtc().toIso8601String(),
  'updatedAt': task.updatedAt.toUtc().toIso8601String(),
};

Map<String, Object?> _approvalJson(ApprovalRequest request) => {
  'id': request.id,
  'chatId': request.chatId,
  'toolName': request.toolName,
  'summary': request.summary,
  'reason': request.reason,
  'diff': request.diff,
  'turnId': request.turnId,
  'permissionKey': request.permissionKey,
  'grantable': request.grantable,
};

Map<String, Object?> _questionJson(UserQuestion question) => {
  'id': question.id,
  'chatId': question.chatId,
  'text': question.text,
};

Map<String, Object?> _editJson(EditFileChangesRequest request) => {
  'id': request.id,
  'chatId': request.chatId,
  'files': [
    for (final file in request.files)
      {'path': file.path, 'kind': file.kind.name},
  ],
  'shellMayHaveChangedFiles': request.shellMayHaveChangedFiles,
};

bool _matchesChat(Object event, String? chatId) {
  final eventChatId = switch (event) {
    AgentEvent value => value.chatId,
    ApprovalRequest value => value.chatId,
    UserQuestion value => value.chatId,
    EditFileChangesRequest value => value.chatId,
    _ => null,
  };
  return chatId == null || eventChatId == chatId;
}

(String, Map<String, Object?>) _event(Object event) => switch (event) {
  AgentTurnStarted value => ('turnStarted', {'chatId': value.chatId}),
  AgentTurnFinished value => (
    'turnFinished',
    {'chatId': value.chatId, 'end': value.end.name},
  ),
  AgentMessageAdded value => (
    'messageAdded',
    {'chatId': value.chatId, 'message': _messageJson(value.message)},
  ),
  AgentTextDelta value => (
    'textDelta',
    {'chatId': value.chatId, 'text': value.text, 'reset': value.reset},
  ),
  AgentReasoningDelta value => (
    'reasoningDelta',
    {'chatId': value.chatId, 'text': value.text, 'reset': value.reset},
  ),
  AgentRunChanged value => (
    'runChanged',
    {'chatId': value.chatId, 'run': _runJson(value.run)},
  ),
  AgentQueueChanged value => (
    'queueChanged',
    {'chatId': value.chatId, 'size': value.size},
  ),
  AgentFailureRaised value => (
    'failure',
    {'chatId': value.chatId, 'message': value.failure.message},
  ),
  AgentTrustNeeded value => (
    'trustNeeded',
    {'chatId': value.chatId, 'workspace': value.workspace},
  ),
  AgentUsageUpdated value => (
    'usage',
    {
      'chatId': value.chatId,
      'promptTokens': value.promptTokens,
      'limit': value.limit,
      'dailyCostUsd': value.dailyCostUsd,
      'dailyBudgetUsd': value.dailyBudgetUsd,
    },
  ),
  AgentStateChanged value => ('stateChanged', {'chatId': value.chatId}),
  ApprovalRequest value => ('approval', _approvalJson(value)),
  UserQuestion value => ('question', _questionJson(value)),
  EditFileChangesRequest value => ('editFileChanges', _editJson(value)),
  _ => ('unknown', {'type': event.runtimeType.toString()}),
};

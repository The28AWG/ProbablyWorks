import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:http/http.dart' as http;
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/chat_api.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/project.dart';
import 'package:pw_agent/agent/domain/steps_display.dart';
import 'package:pw_agent/agent/exec/active_exec_registry.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/agent/loop/prompt_queue.dart';
import 'package:pw_agent/agent/schedule/scheduled_task.dart';
import 'package:pw_agent/agent/turn/turn_file_kind.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/core/domain/chat_usage.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';
import 'package:uuid/uuid.dart';

/// [AgentApi] поверх HTTP/SSE.
///
/// Используется для удалённых профилей. Локальный профиль работает через
/// `LocalAgentApi` без транспорта.
class RemoteAgentApi implements AgentApi, ChatApi {
  RemoteAgentApi({
    required this.baseUri,
    required this.token,
    http.Client? client,
    io.HttpClient? eventsClient,
    this.timeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client(),
       _eventsClient = eventsClient ?? io.HttpClient();

  /// Корень сервера, например `http://127.0.0.1:7787`.
  final Uri baseUri;
  final String token;
  final Duration timeout;

  final http.Client _client;
  final io.HttpClient _eventsClient;

  final _statusChanges = StreamController<AgentStatus>.broadcast();
  var _status = AgentStatus.connecting;
  final _running = <String>{};
  final _waiting = <String>{};
  final _approvalChats = <String, String>{};
  final _questionChats = <String, String>{};
  final _editChats = <String, String>{};
  final _queues = <String, List<QueuedPrompt>>{};
  final _approvalsById = <String, ApprovalRequest>{};
  final _questionsById = <String, UserQuestion>{};
  final _editsById = <String, EditFileChangesRequest>{};
  final _events = StreamController<AgentEvent>.broadcast();
  final _approvals = StreamController<ApprovalRequest>.broadcast();
  final _questions = StreamController<UserQuestion>.broadcast();
  final _editChanges = StreamController<EditFileChangesRequest>.broadcast();

  static const _uuid = Uuid();

  var _eventsStarted = false;
  var _disposed = false;
  final _eventsReady = Completer<void>();

  @override
  AgentStatus get status => _status;

  @override
  Stream<AgentStatus> get statusChanges => _statusChanges.stream;

  @override
  Future<bool> checkConnection() async {
    try {
      final response = await _client
          .get(_url('/health'))
          .timeout(const Duration(seconds: 5));
      final online = response.statusCode == 200;
      _setStatus(online ? AgentStatus.online : AgentStatus.offline);
      return online;
    } on Object {
      _setStatus(AgentStatus.offline);
      return false;
    }
  }

  @override
  Set<String> get runningChatIds => Set.unmodifiable(_running);

  @override
  Set<String> get waitingChatIds => Set.unmodifiable(_waiting);

  @override
  Stream<AgentEvent> get events => _events.stream;

  @override
  Stream<ApprovalRequest> get approvals => _approvals.stream;

  @override
  Stream<UserQuestion> get questions => _questions.stream;

  @override
  Stream<EditFileChangesRequest> get editChanges => _editChanges.stream;

  @override
  late final ChatStore chatStore = _RemoteChatStore(this);

  @override
  late final SettingsStore settings = _RemoteSettings();

  @override
  late final ProjectStore projectStore = const _RemoteProjectStore();

  @override
  late final ProjectsStore projects = const _RemoteProjects();

  @override
  late final ModelStore models = const _RemoteModels();

  @override
  late final HostStore hostStore = _RemoteHosts(this);

  @override
  late final ExecStore registry = const _RemoteExec();

  @override
  late final InteractionsStore broker = _RemoteInteractions(this);

  @override
  ChatSessionApi session(String chatId) => _RemoteChatSession(this, chatId);

  @override
  Future<AppLimits> limits() async => const AppLimits();

  @override
  Chat draftChat({required String hostId, Host? host}) {
    final now = DateTime.now();
    return Chat(
      id: _uuid.v4(),
      hostId: hostId,
      workspace: host?.defaultWorkspace,
      title: '',
      createdAt: now,
      updatedAt: now,
    );
  }

  /// Завершается после установки первого SSE-соединения.
  Future<void> get eventsReady => _eventsReady.future;

  /// Открывает SSE-подписку. Вызывает менеджер профилей, а не сам конструктор:
  /// клиент может быть создан для проверки соединения без живого потока.
  Future<void> startEvents() async {
    if (_eventsStarted || _disposed) return;
    _eventsStarted = true;
    _setStatus(AgentStatus.connecting);
    unawaited(_listen());
  }

  Future<void> dispose() async {
    _disposed = true;
    await _statusChanges.close();
    await _events.close();
    await _approvals.close();
    await _questions.close();
    await _editChanges.close();
    _client.close();
    _eventsClient.close(force: true);
  }

  @override
  Future<List<Host>> hosts() async {
    final json = await _get('/hosts');
    return [
      for (final item in (json['hosts'] as List? ?? const []))
        _host(Map<String, dynamic>.from(item as Map)),
    ];
  }

  @override
  Stream<List<Chat>> watchChats() {
    late final StreamController<List<Chat>> controller;
    Timer? timer;
    Future<void> refresh() async {
      try {
        controller.add(await chats());
      } on Object {
        // Следующий тик попробует снова.
      }
    }

    controller = StreamController<List<Chat>>(
      onListen: () {
        unawaited(refresh());
        timer = Timer.periodic(
          const Duration(seconds: 2),
          (_) => unawaited(refresh()),
        );
      },
      onCancel: () {
        timer?.cancel();
      },
    );
    return controller.stream;
  }

  @override
  Stream<List<Host>> watchHosts() {
    late final StreamController<List<Host>> controller;
    Timer? timer;
    Future<void> refresh() async {
      try {
        controller.add(await hosts());
      } on Object {
        // Следующий тик попробует снова.
      }
    }

    controller = StreamController<List<Host>>(
      onListen: () {
        unawaited(refresh());
        timer = Timer.periodic(
          const Duration(seconds: 10),
          (_) => unawaited(refresh()),
        );
      },
      onCancel: () {
        timer?.cancel();
      },
    );
    return controller.stream;
  }

  @override
  Future<List<Chat>> chats() async {
    final json = await _get('/chats');
    final chats = <Chat>[];
    for (final item in (json['chats'] as List? ?? const [])) {
      final map = Map<String, dynamic>.from(item as Map);
      final chat = _chat(map);
      chats.add(chat);
      _trackChatState(chat.id, map);
    }
    return chats;
  }

  @override
  Future<Chat?> chat(String id) async {
    try {
      final json = await _get('/chats/$id');
      final map = Map<String, dynamic>.from(json['chat'] as Map);
      final chat = _chat(map);
      _trackChatState(chat.id, map);
      _syncCards(chat.id, json);
      return chat;
    } on AgentApiException catch (error) {
      if (error.status == 404) return null;
      rethrow;
    }
  }

  @override
  Future<Chat> createChat(String hostId) async {
    final json = await _send('POST', '/chats', body: {'hostId': hostId});
    final map = Map<String, dynamic>.from(json as Map);
    final chat = _chat(map);
    _trackChatState(chat.id, map);
    return chat;
  }

  @override
  @override
  Future<void> saveChat(Chat chat) async {
    await _send('PUT', '/chats/${chat.id}', body: _chatBody(chat));
  }

  @override
  Future<void> renameChat(String chatId, String title) =>
      updateChat(chatId, title: title);

  @override
  Future<void> updateChat(
    String chatId, {
    String? title,
    String? model,
    PolicyMode? policyMode,
    String? workspace,
    bool workspaceSpecified = false,
  }) async {
    await _send(
      'PATCH',
      '/chats/$chatId',
      body: {
        'title': ?title,
        'model': ?model,
        'policyMode': ?policyMode?.name,
        'workspace': ?workspace,
        if (workspaceSpecified) 'workspaceSpecified': true,
      },
    );
  }

  @override
  Future<Chat?> forkChat(
    String chatId, {
    String? title,
    String? untilMessageId,
  }) async {
    try {
      final json = await _send(
        'POST',
        '/chats/$chatId/fork',
        body: {'title': ?title},
      );
      final map = Map<String, dynamic>.from(json as Map);
      final chat = _chat(map);
      _trackChatState(chat.id, map);
      return chat;
    } on AgentApiException catch (error) {
      if (error.status == 404) return null;
      rethrow;
    }
  }

  @override
  Future<void> deleteChat(String chatId) async {
    await _send('DELETE', '/chats/$chatId');
    _running.remove(chatId);
    _waiting.remove(chatId);
  }

  @override
  Future<List<ChatMessage>> messages(String chatId) async {
    final json = await _get('/chats/$chatId/messages');
    return [
      for (final item in (json['messages'] as List? ?? const []))
        _message(Map<String, dynamic>.from(item as Map)),
    ];
  }

  @override
  Future<List<ToolRun>> runs(String chatId) async {
    final json = await _get('/chats/$chatId/runs');
    return [
      for (final item in (json['runs'] as List? ?? const []))
        _run(Map<String, dynamic>.from(item as Map)),
    ];
  }

  @override
  Future<void> openChat(String chatId) async {
    await _send('PUT', '/chats/$chatId/presence');
    await _trySyncSession(chatId);
  }

  @override
  Future<void> send(String chatId, String text, {bool sendNow = false}) async {
    await _send(
      'POST',
      '/chats/$chatId/messages',
      body: {'text': text, 'sendNow': sendNow},
    );
    await _trySyncSession(chatId);
  }

  Future<void> _trySyncSession(String chatId) async {
    try {
      await _syncSession(chatId);
    } on AgentApiException {
      // Очередь — дополнительная информация; без неё чат всё равно работает.
    }
  }

  Future<void> _syncSession(String chatId) async {
    final json = await _get('/chats/$chatId/session');
    _queues[chatId] = [
      for (final item in (json['queue'] as List? ?? const []))
        if (item is Map) QueuedPrompt.user('${item['text'] ?? ''}'),
    ];
  }

  @override
  Future<void> stop(String chatId, {String? reason}) async {
    final query = reason == null || reason.isEmpty
        ? ''
        : '?reason=${Uri.encodeQueryComponent(reason)}';
    await _send('DELETE', '/chats/$chatId/turn$query');
  }

  @override
  Future<void> resolveApproval(
    String id,
    ApprovalAction action, {
    String? reason,
  }) async {
    final body = <String, Object?>{'action': action.name};
    if (reason != null) body['reason'] = reason;
    await _send('PUT', '/approvals/$id/decision', body: body);
    _approvalsById.remove(id);
    final chatId = _approvalChats.remove(id);
    if (chatId != null && !_hasPending(chatId)) _waiting.remove(chatId);
  }

  @override
  Future<void> answerQuestion(String id, String? text) async {
    await _send('PUT', '/questions/$id/answer', body: {'answer': text});
    _questionsById.remove(id);
    final chatId = _questionChats.remove(id);
    if (chatId != null && !_hasPending(chatId)) _waiting.remove(chatId);
  }

  @override
  Future<void> resolveEditFileChanges(
    String id,
    EditFileChangesChoice choice,
  ) async {
    await _send(
      'PUT',
      '/edit-file-changes/$id/decision',
      body: {'choice': choice.name},
    );
    _editsById.remove(id);
    final chatId = _editChats.remove(id);
    if (chatId != null && !_hasPending(chatId)) _waiting.remove(chatId);
  }

  @override
  Future<List<ApprovalRequest>> pendingApprovals(String chatId) async {
    await _syncCardsFromServer(chatId);
    return pendingApprovalsSync(chatId);
  }

  @override
  Future<List<UserQuestion>> pendingQuestions(String chatId) async {
    await _syncCardsFromServer(chatId);
    return pendingQuestionsSync(chatId);
  }

  @override
  Future<List<EditFileChangesRequest>> pendingEditFileChanges(
    String chatId,
  ) async {
    await _syncCardsFromServer(chatId);
    return pendingEditFileChangesSync(chatId);
  }

  List<ApprovalRequest> pendingApprovalsSync(String chatId) => [
    for (final value in _approvalsById.values)
      if (value.chatId == chatId) value,
  ];

  List<UserQuestion> pendingQuestionsSync(String chatId) => [
    for (final value in _questionsById.values)
      if (value.chatId == chatId) value,
  ];

  List<EditFileChangesRequest> pendingEditFileChangesSync(String chatId) => [
    for (final value in _editsById.values)
      if (value.chatId == chatId) value,
  ];

  Future<void> _syncCardsFromServer(String chatId) async {
    final json = await _get('/chats/$chatId');
    _syncCards(chatId, json);
  }

  void _syncCards(String chatId, Map<String, dynamic> json) {
    _approvalsById.removeWhere((_, value) => value.chatId == chatId);
    _questionsById.removeWhere((_, value) => value.chatId == chatId);
    _editsById.removeWhere((_, value) => value.chatId == chatId);
    for (final item in (json['approvals'] as List? ?? const [])) {
      final request = _approval(Map<String, dynamic>.from(item as Map));
      _approvalsById[request.id] = request;
      _approvalChats[request.id] = request.chatId;
    }
    for (final item in (json['questions'] as List? ?? const [])) {
      final question = _question(Map<String, dynamic>.from(item as Map));
      _questionsById[question.id] = question;
      _questionChats[question.id] = question.chatId;
    }
    for (final item in (json['editFileChanges'] as List? ?? const [])) {
      final request = _editChangesRequest(
        Map<String, dynamic>.from(item as Map),
      );
      _editsById[request.id] = request;
      _editChats[request.id] = request.chatId;
    }
    _waiting.removeWhere((id) => id == chatId && !_hasPending(chatId));
    if (_hasPending(chatId)) _waiting.add(chatId);
  }

  @override
  Future<List<ScheduledTask>> schedules() async {
    final json = await _get('/schedules');
    return [
      for (final item in (json['schedules'] as List? ?? const []))
        _task(Map<String, dynamic>.from(item as Map)),
    ];
  }

  @override
  Future<ScheduledTask?> scheduledTask(String id) async {
    try {
      final json = await _get('/schedules/$id');
      return _task(Map<String, dynamic>.from(json as Map));
    } on AgentApiException catch (error) {
      if (error.status == 404) return null;
      rethrow;
    }
  }

  @override
  Future<ScheduledTask> schedule({
    required String chatId,
    required String prompt,
    required DateTime dueAt,
  }) async {
    final json = await _send(
      'POST',
      '/schedules',
      body: {
        'chatId': chatId,
        'prompt': prompt,
        'dueAt': dueAt.toUtc().toIso8601String(),
      },
    );
    return _task(Map<String, dynamic>.from(json as Map));
  }

  @override
  Future<void> cancelSchedule(String id) async {
    await _send('DELETE', '/schedules/$id');
  }

  @override
  Future<void> resumeAfterRestart() => Future<void>.value();

  Future<Map<String, dynamic>> _get(String path) async =>
      _asMap(await _send('GET', path));

  Future<Object?> _send(String method, String path, {Object? body}) async {
    final request = http.Request(method, _url(path));
    request.headers['Authorization'] = 'Bearer $token';
    request.headers['Accept'] = 'application/json';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final http.Response response;
    try {
      final streamed = await _client.send(request).timeout(timeout);
      response = await http.Response.fromStream(streamed);
    } on http.ClientException {
      _setStatus(AgentStatus.offline);
      rethrow;
    } on io.SocketException {
      _setStatus(AgentStatus.offline);
      rethrow;
    } on TimeoutException {
      _setStatus(AgentStatus.offline);
      rethrow;
    }
    _setStatus(AgentStatus.online);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _error(response);
    }
    if (response.body.isEmpty) return null;
    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>> getJson(String path) => _get(path);

  Future<Object?> sendJson(String method, String path, {Object? body}) =>
      _send(method, path, body: body);

  Map<String, dynamic> _asMap(Object? value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    throw const AgentApiException(500, 'bad_response', 'expected JSON object');
  }

  AgentApiException _error(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['error'] is Map) {
        final error = decoded['error'] as Map;
        return AgentApiException(
          response.statusCode,
          '${error['code'] ?? 'http_error'}',
          '${error['message'] ?? response.reasonPhrase ?? 'HTTP error'}',
        );
      }
    } on FormatException {
      // Ниже отдаём общий ответ.
    }
    return AgentApiException(
      response.statusCode,
      'http_${response.statusCode}',
      response.reasonPhrase ?? 'HTTP ${response.statusCode}',
    );
  }

  Uri _url(String path) => baseUri.resolve('/api/v1$path');

  void _setStatus(AgentStatus status) {
    if (_status == status) return;
    _status = status;
    if (!_statusChanges.isClosed) _statusChanges.add(status);
  }

  Future<void> _listen() async {
    while (!_disposed) {
      try {
        final request = await _eventsClient.getUrl(_url('/events'));
        request.headers.set('Authorization', 'Bearer $token');
        final response = await request.close();
        if (response.statusCode != 200) {
          throw AgentApiException(
            response.statusCode,
            'events_failed',
            'SSE connection failed',
          );
        }
        _setStatus(AgentStatus.online);
        if (!_eventsReady.isCompleted) _eventsReady.complete();
        await _consume(response);
      } on Object {
        _setStatus(AgentStatus.offline);
        // Ниже пауза и повторное подключение.
      }
      if (_disposed) break;
      await Future<void>.delayed(const Duration(seconds: 3));
    }
  }

  Future<void> _consume(Stream<List<int>> stream) async {
    String? event;
    final data = StringBuffer();
    final lines = stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (line.isEmpty) {
        if (event != null && data.isNotEmpty) {
          _dispatch(event, data.toString());
        }
        event = null;
        data.clear();
        continue;
      }
      if (line.startsWith(':')) continue;
      if (line.startsWith('event:')) {
        event = line.replaceFirst('event:', '').trim();
      } else if (line.startsWith('data:')) {
        data.writeln(line.replaceFirst('data:', '').trimLeft());
      }
    }
  }

  void _trackChatState(String chatId, Map<String, dynamic> json) {
    if (json['running'] == true) {
      _running.add(chatId);
    } else {
      _running.remove(chatId);
    }
    if (json['waiting'] == true) {
      _waiting.add(chatId);
    } else {
      _waiting.remove(chatId);
    }
  }

  bool _hasPending(String chatId) =>
      _approvalChats.containsValue(chatId) ||
      _questionChats.containsValue(chatId) ||
      _editChats.containsValue(chatId);

  void _dispatch(String event, String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return;
    final json = Map<String, dynamic>.from(decoded);
    switch (event) {
      case 'approval':
        final request = _approval(json);
        _approvalChats[request.id] = request.chatId;
        _approvalsById[request.id] = request;
        _waiting.add(request.chatId);
        _approvals.add(request);
      case 'question':
        final question = _question(json);
        _questionChats[question.id] = question.chatId;
        _questionsById[question.id] = question;
        _waiting.add(question.chatId);
        _questions.add(question);
      case 'editFileChanges':
        final request = _editChangesRequest(json);
        _editChats[request.id] = request.chatId;
        _editsById[request.id] = request;
        _waiting.add(request.chatId);
        _editChanges.add(request);
      case 'turnStarted':
        final chatId = _string(json, 'chatId');
        _running.add(chatId);
        _events.add(AgentTurnStarted(chatId));
      case 'turnFinished':
        final chatId = _string(json, 'chatId');
        _running.remove(chatId);
        _events.add(
          AgentTurnFinished(
            chatId,
            TurnEnd.values.byName(_string(json, 'end')),
          ),
        );
      case 'messageAdded':
        _events.add(
          AgentMessageAdded(
            _string(json, 'chatId'),
            _message(Map<String, dynamic>.from(json['message'] as Map)),
          ),
        );
      case 'textDelta':
        _events.add(
          AgentTextDelta(
            _string(json, 'chatId'),
            '${json['text'] ?? ''}',
            reset: json['reset'] == true,
          ),
        );
      case 'reasoningDelta':
        _events.add(
          AgentReasoningDelta(
            _string(json, 'chatId'),
            '${json['text'] ?? ''}',
            reset: json['reset'] == true,
          ),
        );
      case 'runChanged':
        _events.add(
          AgentRunChanged(
            _string(json, 'chatId'),
            _run(Map<String, dynamic>.from(json['run'] as Map)),
          ),
        );
      case 'queueChanged':
        _events.add(
          AgentQueueChanged(_string(json, 'chatId'), _int(json, 'size')),
        );
      case 'failure':
        _events.add(
          AgentFailureRaised(
            _string(json, 'chatId'),
            GenericFailure('${json['message'] ?? ''}'),
          ),
        );
      case 'trustNeeded':
        _events.add(
          AgentTrustNeeded(
            _string(json, 'chatId'),
            json['workspace'] as String?,
          ),
        );
      case 'usage':
        _events.add(
          AgentUsageUpdated(
            _string(json, 'chatId'),
            _int(json, 'promptTokens'),
            _int(json, 'limit'),
            dailyCostUsd: _double(json['dailyCostUsd']),
            dailyBudgetUsd: _double(json['dailyBudgetUsd']),
          ),
        );
      case 'stateChanged':
        _events.add(AgentStateChanged(_string(json, 'chatId')));
    }
  }
}

Map<String, Object?> _chatBody(Chat chat) => {
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

Chat _chat(Map<String, dynamic> json) => Chat(
  id: _string(json, 'id'),
  hostId: _string(json, 'hostId'),
  projectId: json['projectId'] as String?,
  kind: ChatKind.values.byName('${json['kind'] ?? 'main'}'),
  parentChatId: json['parentChatId'] as String?,
  rootChatId: json['rootChatId'] as String?,
  depth: _int(json, 'depth'),
  title: '${json['title'] ?? ''}',
  titleSource: ChatTitleSource.values.byName(
    '${json['titleSource'] ?? 'none'}',
  ),
  model: json['model'] as String?,
  policyMode: PolicyMode.values.byName('${json['policyMode'] ?? 'ask'}'),
  workspace: json['workspace'] as String?,
  lastPromptTokens: json['lastPromptTokens'] as int?,
  lastCompletionTokens: json['lastCompletionTokens'] as int?,
  contextLength: json['contextLength'] as int?,
  createdAt: DateTime.parse(_string(json, 'createdAt')),
  updatedAt: DateTime.parse(_string(json, 'updatedAt')),
);

ChatMessage _message(Map<String, dynamic> json) => ChatMessage(
  id: _string(json, 'id'),
  chatId: _string(json, 'chatId'),
  seq: _int(json, 'seq'),
  role: MessageRole.values.byName(_string(json, 'role')),
  text: '${json['text'] ?? ''}',
  reasoning: '${json['reasoning'] ?? ''}',
  toolCalls: [
    for (final call in (json['toolCalls'] as List? ?? const []))
      ToolCallRef.fromJson(Map<String, dynamic>.from(call as Map)),
  ],
  toolCallId: json['toolCallId'] as String?,
  attachments: [
    for (final attachment in (json['attachments'] as List? ?? const []))
      AttachmentRef(
        name: '${(attachment as Map)['name'] ?? ''}',
        mode: AttachmentMode.values.byName('${attachment['mode'] ?? 'file'}'),
        mimeType: attachment['mimeType'] as String?,
        sizeBytes: _int(Map<String, dynamic>.from(attachment), 'sizeBytes'),
      ),
  ],
  createdAt: DateTime.parse(_string(json, 'createdAt')),
);

ToolRun _run(Map<String, dynamic> json) => ToolRun(
  id: _string(json, 'id'),
  chatId: _string(json, 'chatId'),
  messageId: _string(json, 'messageId'),
  toolName: _string(json, 'toolName'),
  argsJson: '${json['argsJson'] ?? ''}',
  command: json['command'] as String?,
  background: json['background'] == true,
  status: ToolRunStatus.values.byName(_string(json, 'status')),
  pid: json['pid'] as int?,
  exitCode: json['exitCode'] as int?,
  timedOut: json['timedOut'] == true,
  outputText: json['outputText'] as String?,
  outputTruncated: json['outputTruncated'] == true,
  resultPreview: json['resultPreview'] as String?,
  startedAt: DateTime.parse(_string(json, 'startedAt')),
  finishedAt: _date(json['finishedAt']),
  toolCallId: json['toolCallId'] as String?,
  pendingCard: json['pendingCard'] == null
      ? null
      : jsonEncode(json['pendingCard']),
);

Host _host(Map<String, dynamic> json) => Host(
  id: _string(json, 'id'),
  name: _string(json, 'name'),
  kind: HostKind.values.byName(_string(json, 'kind')),
  address: json['address'] as String?,
  port: _int(json, 'port'),
  username: json['username'] as String?,
  os: HostOs.values.byName('${json['os'] ?? 'posix'}'),
  defaultWorkspace: json['defaultWorkspace'] as String?,
  notes: json['notes'] as String?,
  createdAt: _date(json['createdAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
  updatedAt: _date(json['updatedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
);

ScheduledTask _task(Map<String, dynamic> json) => ScheduledTask(
  id: _string(json, 'id'),
  chatId: _string(json, 'chatId'),
  prompt: _string(json, 'prompt'),
  dueAt: DateTime.parse(_string(json, 'dueAt')),
  status: ScheduledTaskStatus.values.byName(_string(json, 'status')),
  error: json['error'] as String?,
  createdAt: DateTime.parse(_string(json, 'createdAt')),
  updatedAt: DateTime.parse(_string(json, 'updatedAt')),
);

ApprovalRequest _approval(Map<String, dynamic> json) => ApprovalRequest(
  id: _string(json, 'id'),
  chatId: _string(json, 'chatId'),
  toolName: _string(json, 'toolName'),
  summary: _string(json, 'summary'),
  reason: _string(json, 'reason'),
  diff: json['diff'] as String?,
  turnId: json['turnId'] as String?,
  permissionKey: json['permissionKey'] as String?,
  grantable: json['grantable'] != false,
);

UserQuestion _question(Map<String, dynamic> json) => UserQuestion(
  id: _string(json, 'id'),
  chatId: _string(json, 'chatId'),
  text: _string(json, 'text'),
);

EditFileChangesRequest _editChangesRequest(Map<String, dynamic> json) =>
    EditFileChangesRequest(
      id: _string(json, 'id'),
      chatId: _string(json, 'chatId'),
      files: [
        for (final file in (json['files'] as List? ?? const []))
          EditFileChangesEntry(
            path: _string(Map<String, dynamic>.from(file as Map), 'path'),
            kind: TurnFileKind.values.byName(
              _string(Map<String, dynamic>.from(file), 'kind'),
            ),
          ),
      ],
      shellMayHaveChangedFiles: json['shellMayHaveChangedFiles'] == true,
    );

String _string(Map<String, dynamic> json, String key) => '${json[key] ?? ''}';

int _int(Map<String, dynamic> json, String key) {
  final value = json[key];
  return value is num ? value.toInt() : 0;
}

double? _double(Object? value) => value is num ? value.toDouble() : null;

DateTime? _date(Object? value) =>
    value is String && value.isNotEmpty ? DateTime.tryParse(value) : null;

final class _RemoteChatStore implements ChatStore {
  _RemoteChatStore(this._api);

  final RemoteAgentApi _api;

  @override
  Future<Chat?> chat(String id) => _api.chat(id);

  @override
  Future<List<ChatMessage>> messages(String id) => _api.messages(id);

  @override
  Future<List<ToolRun>> toolRunsForChat(String id) => _api.runs(id);

  @override
  Future<void> saveChat(Chat chat) async {
    await _api.sendJson(
      'PATCH',
      '/chats/${chat.id}',
      body: {
        'title': chat.title,
        'model': chat.model,
        'policyMode': chat.policyMode.name,
        'workspace': chat.workspace,
      },
    );
  }
}

final class _RemoteSettings implements SettingsStore {
  @override
  Stream<String?> watch(String key) => Stream<String?>.empty();

  @override
  Future<String?> read(String key) => Future<String?>.value();

  @override
  Future<List<String>> readPinnedModels() => Future.value(const []);

  @override
  Future<void> savePinnedModels(List<String> ids) => Future<void>.value();

  @override
  Future<StepsDisplay> readStepsDisplay() =>
      Future.value(StepsDisplay.defaults);

  @override
  Future<ChatDailyUsage> readDailyUsage(String chatId) =>
      Future.value(const ChatDailyUsage());

  @override
  Future<double?> readDailyBudget(String chatId) => Future<double?>.value();

  @override
  Future<void> saveDailyBudget(String chatId, double? value) =>
      Future<void>.value();

  @override
  Future<ChatCompactionInfo?> readCompactionInfo(String chatId) =>
      Future<ChatCompactionInfo?>.value();

  @override
  Future<void> setTrusted(
    String hostId,
    String workspace, {
    required bool trusted,
  }) => Future<void>.value();

  @override
  AppLimits cachedLimits() => const AppLimits();

  @override
  List<String> cachedPinnedModels() => const [];

  @override
  StepsDisplay cachedStepsDisplay() => StepsDisplay.defaults;

  @override
  String? cached(String key) => null;
}

final class _RemoteProjectStore implements ProjectStore {
  const _RemoteProjectStore();

  @override
  Future<Project?> forChat(String chatId) => Future<Project?>.value();

  @override
  Future<Project?> byId(String id) => Future<Project?>.value();
}

final class _RemoteProjects implements ProjectsStore {
  const _RemoteProjects();

  @override
  Future<Chat> attach(Chat chat) => Future.value(chat);

  @override
  String? configuredWorkspace(Host host) => host.defaultWorkspace;

  @override
  Future<Chat> relocate(
    Chat chat, {
    String? hostId,
    String? workspace,
    bool workspaceSpecified = false,
  }) => Future.value(chat);

  @override
  Future<void> trustWorkspace(String projectId) => Future<void>.value();
}

final class _RemoteModels implements ModelStore {
  const _RemoteModels();

  @override
  ModelCatalogState get state => const ModelCatalogState();

  @override
  Stream<ModelCatalogState> watch() => Stream<ModelCatalogState>.empty();

  @override
  Future<void> remember(List<String> ids) => Future<void>.value();
}

final class _RemoteHosts implements HostStore {
  _RemoteHosts(this._api);

  final RemoteAgentApi _api;

  @override
  Future<List<Host>> all() => _api.hosts();

  @override
  Stream<List<Host>> watchAll() => _api.watchHosts();
}

final class _RemoteExec implements ExecStore {
  const _RemoteExec();

  @override
  ActiveExec? find(String runId) => null;

  @override
  Future<void> stop(ActiveExec exec, {required bool force}) =>
      Future<void>.value();
}

final class _RemoteInteractions implements InteractionsStore {
  _RemoteInteractions(this._api);

  final RemoteAgentApi _api;

  @override
  Stream<ApprovalRequest> get approvalRequests => _api.approvals;

  @override
  Stream<UserQuestion> get questions => _api.questions;

  @override
  Stream<EditFileChangesRequest> get editFileChangesRequests =>
      _api.editChanges;

  @override
  List<ApprovalRequest> pendingApprovals(String chatId) =>
      _api.pendingApprovalsSync(chatId);

  @override
  List<UserQuestion> pendingQuestions(String chatId) =>
      _api.pendingQuestionsSync(chatId);

  @override
  List<EditFileChangesRequest> pendingEditFileChanges(String chatId) =>
      _api.pendingEditFileChangesSync(chatId);

  @override
  void resolveApproval(String requestId, ApprovalDecision decision) {
    unawaited(_api.resolveApproval(requestId, decision.action));
  }

  @override
  void answer(String questionId, String? text) {
    unawaited(_api.answerQuestion(questionId, text));
  }

  @override
  void resolveEditFileChanges(String requestId, EditFileChangesChoice choice) {
    unawaited(_api.resolveEditFileChanges(requestId, choice));
  }
}

final class _RemoteChatSession implements ChatSessionApi {
  _RemoteChatSession(this._api, this._chatId);

  final RemoteAgentApi _api;
  final String _chatId;

  @override
  bool get isRunning => _api.runningChatIds.contains(_chatId);

  @override
  List<QueuedPrompt> get queue => _api._queues[_chatId] ?? const [];

  @override
  Stream<AgentEvent> get events =>
      _api.events.where((event) => event.chatId == _chatId);

  @override
  Future<void> submit(
    String text, {
    List<AttachmentRef> attachments = const [],
    bool sendNow = false,
  }) => _api.send(_chatId, text, sendNow: sendNow);

  @override
  Future<void> stop({String? reason}) => _api.stop(_chatId, reason: reason);

  @override
  Future<void> continueAfterStepLimit() async {
    await _api.sendJson('POST', '/chats/$_chatId/session/continue');
  }

  @override
  Future<bool> regenerateLast() async {
    final json = await _api.sendJson(
      'POST',
      '/chats/$_chatId/session/regenerate',
    );
    return json is Map && json['accepted'] == true;
  }

  @override
  void promoteQueued(int index) {
    unawaited(
      _api.sendJson('POST', '/chats/$_chatId/session/queue/$index/promote'),
    );
  }

  @override
  QueuedPrompt? takeQueued(int index) {
    final items = _api._queues[_chatId];
    if (items == null || index < 0 || index >= items.length) return null;
    final item = items.removeAt(index);
    unawaited(_api.sendJson('DELETE', '/chats/$_chatId/session/queue/$index'));
    return item;
  }

  @override
  Future<bool> editUserMessage(
    String messageId,
    String newText, {
    List<AttachmentRef>? attachments,
  }) async {
    final json = await _api.sendJson(
      'POST',
      '/chats/$_chatId/session/edit',
      body: {'messageId': messageId, 'text': newText},
    );
    return json is Map && json['accepted'] == true;
  }

  @override
  Future<void> deleteAfter(String messageId) async {
    await _api.sendJson(
      'POST',
      '/chats/$_chatId/session/delete-after',
      body: {'messageId': messageId},
    );
  }

  @override
  Future<void> restoreUnanswered() => _api.openChat(_chatId);

  @override
  Future<void> compactNow({bool force = false}) async {
    await _api.sendJson(
      'POST',
      '/chats/$_chatId/session/compact',
      body: {'force': force},
    );
  }
}

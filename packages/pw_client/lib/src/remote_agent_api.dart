import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:http/http.dart' as http;
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/agent_settings_api.dart';
import 'package:pw_agent/agent/api/chat_api.dart';
import 'package:pw_agent/agent/api/hosts_api.dart';
import 'package:pw_agent/agent/api/mcp_api.dart';
import 'package:pw_agent/agent/api/projects_api.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/project.dart';
import 'package:pw_agent/agent/domain/steps_display.dart';
import 'package:pw_agent/agent/exec/active_exec_registry.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/agent/loop/prompt_queue.dart';
import 'package:pw_agent/agent/mcp/mcp_client_manager.dart';
import 'package:pw_agent/agent/mcp/mcp_service.dart';
import 'package:pw_agent/agent/policy/security_profile.dart';
import 'package:pw_agent/agent/schedule/scheduled_task.dart';
import 'package:pw_agent/agent/turn/turn_file_kind.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/domain/chat_usage.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/domain/mcp_server.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';
import 'package:uuid/uuid.dart';

/// [AgentApi] поверх HTTP/SSE.
///
/// Используется для удалённых профилей. Локальный профиль работает через
/// `LocalAgentApi` без транспорта.
class RemoteAgentApi
    implements
        AgentApi,
        ChatApi,
        HostsApi,
        ProjectsApi,
        AgentSettingsApi,
        McpApi {
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
  Map<String, dynamic>? _globalSettings;
  Future<void>? _settingsLoading;
  final _usageByChat = <String, Map<String, dynamic>>{};
  final _projectsByChat = <String, Project?>{};
  ModelCatalogState? _catalog;
  final _approvalsById = <String, ApprovalRequest>{};
  final _questionsById = <String, UserQuestion>{};
  final _editsById = <String, EditFileChangesRequest>{};
  final _events = StreamController<AgentEvent>.broadcast();
  final _approvals = StreamController<ApprovalRequest>.broadcast();
  final _questions = StreamController<UserQuestion>.broadcast();
  final _editChanges = StreamController<EditFileChangesRequest>.broadcast();
  final _catalogChanges = StreamController<ModelCatalogState>.broadcast();
  final _pinnedChanges = StreamController<List<String>>.broadcast();
  final _settingsChanges = StreamController<void>.broadcast();
  final _mcpStateChanges = StreamController<McpServerState>.broadcast();
  McpSnapshot? _mcpSnapshot;

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
  late final SettingsStore settings = _RemoteSettings(this);

  @override
  late final ProjectStore projectStore = _RemoteProjectStore(this);

  @override
  late final ProjectsStore projects = const _RemoteProjects();

  @override
  late final ModelStore models = _RemoteModels(this);

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
    await _catalogChanges.close();
    await _pinnedChanges.close();
    await _settingsChanges.close();
    await _mcpStateChanges.close();
    _client.close();
    _eventsClient.close(force: true);
  }

  @override
  Future<void> saveHost(
    Host host, {
    String? secret,
    String? privateKeyPem,
  }) async {
    await _send(
      'PUT',
      '/hosts/${host.id}',
      body: {
        ..._hostBody(host),
        'secret': ?secret,
        'privateKeyPem': ?privateKeyPem,
      },
    );
  }

  @override
  Future<void> deleteHost(String id) async {
    await _send('DELETE', '/hosts/$id');
  }

  @override
  Future<void> testHost(Host host) async {
    await _send('POST', '/hosts/${host.id}/test', body: _hostBody(host));
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
      await _loadGlobalSettings();
      await _loadChatState(chat.id);
      await _loadModels();
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
        '/chats/$chatId/forks',
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
    await _loadGlobalSettings();
    await _loadChatState(chatId);
    await _loadModels();
  }

  Future<void> _loadGlobalSettings() {
    if (_globalSettings != null) return Future<void>.value();
    return _settingsLoading ??= _fetchGlobalSettings().whenComplete(
      () => _settingsLoading = null,
    );
  }

  Future<void> _fetchGlobalSettings() async {
    try {
      _globalSettings = await _get('/settings');
      if (!_settingsChanges.isClosed) _settingsChanges.add(null);
    } on AgentApiException {
      // Настройки не критичны для чтения чата.
    }
  }

  void _publishSettings([Map<String, dynamic>? patch]) {
    if (patch != null) {
      _globalSettings = {...?_globalSettings, ...patch};
    }
    if (!_settingsChanges.isClosed) _settingsChanges.add(null);
  }

  Future<void> _loadChatState(String chatId) async {
    try {
      final usage = await _get('/chats/$chatId/usage');
      _usageByChat[chatId] = usage;
      final project = await _get('/chats/$chatId/project');
      final raw = project['project'];
      _projectsByChat[chatId] = raw is Map
          ? _project(Map<String, dynamic>.from(raw))
          : null;
    } on AgentApiException {
      // Чат всё равно можно открыть.
    }
  }

  Future<void> _loadModels() async {
    try {
      _publishCatalog(_catalogFrom(await _get('/models')));
    } on AgentApiException {
      // Каталог не критичен для журнала.
    }
  }

  @override
  Future<void> send(
    String chatId,
    String text, {
    bool sendNow = false,
    List<AttachmentRef> attachments = const [],
  }) async {
    await _send(
      'POST',
      '/chats/$chatId/messages',
      body: {
        'text': text,
        'sendNow': sendNow,
        'attachments': [
          for (final attachment in attachments) _attachmentBody(attachment),
        ],
      },
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

  AgentSettingsSnapshot? _snapshot;

  @override
  Future<AgentSettingsSnapshot> load() async {
    final json = await _get('/settings');
    _snapshot = _snapshotFrom(json);
    _publishCatalog(_snapshot!.catalog);
    return _snapshot!;
  }

  void _publishCatalog(ModelCatalogState catalog) {
    _catalog = catalog;
    if (!_catalogChanges.isClosed) _catalogChanges.add(catalog);
  }

  @override
  Stream<ModelCatalogState> watchCatalog() async* {
    if (_snapshot == null) {
      try {
        await load();
      } on AgentApiException {
        // Каталог обновится при следующем открытии или запросе.
      }
    }
    yield _catalog ?? const ModelCatalogState();
    yield* _catalogChanges.stream;
  }

  @override
  Stream<List<String>> watchPinnedModels() async* {
    if (_snapshot == null) {
      try {
        await load();
      } on AgentApiException {
        // Закрепления обновятся при следующем открытии или запросе.
      }
    }
    yield _snapshot?.pinnedModels ?? const [];
    yield* _pinnedChanges.stream;
  }

  @override
  Future<void> writeSetting(String key, String? value) async {
    await _send('PUT', '/settings/$key', body: {'value': value});
    _publishSettings({key: value});
  }

  @override
  Future<void> saveStepsDisplay(StepsDisplay value) async {
    final json = {
      'group': value.group,
      'expandWhileActive': value.expandWhileActive,
      'thoughts': value.thoughts.name,
      'tools': value.tools.name,
    };
    await _send('PUT', '/settings/steps', body: json);
    _publishSettings({'steps': json});
  }

  @override
  Future<void> savePinnedModels(List<String> ids) async {
    await _send('PUT', '/settings/pinned', body: {'pinnedModels': ids});
    _publishSettings({'pinnedModels': ids});
    if (!_pinnedChanges.isClosed) _pinnedChanges.add(ids);
  }

  @override
  Future<void> saveDenylist(List<String> patterns) async {
    await _send('PUT', '/settings/denylist', body: {'denylist': patterns});
    _publishSettings({'denylist': patterns});
  }

  @override
  Future<void> saveSecurityProfile(SecurityProfile profile) async {
    final encoded = profile.encode();
    await _send(
      'PUT',
      '/settings/security-profile',
      body: {'profile': encoded},
    );
    _publishSettings({'securityProfile': encoded});
  }

  @override
  Future<void> saveLimits(AppLimits limits) async {
    final json = limits.toMap();
    await _send('PUT', '/settings/limits', body: {'limits': json});
    _publishSettings({'limits': json});
  }

  @override
  Future<void> saveApiKey(String key) async {
    await _send('POST', '/settings/api-key', body: {'key': key});
  }

  @override
  Future<void> deleteApiKey() async {
    await _send('DELETE', '/settings/api-key');
  }

  @override
  Future<LlmKeyInfo?> checkKey() async {
    final json = await _send('POST', '/settings/api-key/check');
    if (json is! Map) return null;
    return _keyInfo(Map<String, dynamic>.from(json));
  }

  @override
  Future<void> refreshModels() async {
    await _send('POST', '/models/refresh');
    await _loadModels();
  }

  @override
  Future<void> rememberModels(List<String> ids) async {
    await _send('POST', '/models/remember', body: {'ids': ids});
  }

  @override
  Future<McpSnapshot> snapshot() async {
    final snapshot = mcpSnapshotFromJson(await _get('/mcp'));
    _mcpSnapshot = snapshot;
    for (final state in snapshot.states.values) {
      if (!_mcpStateChanges.isClosed) _mcpStateChanges.add(state);
    }
    return snapshot;
  }

  @override
  Stream<McpServerState> watchStates() async* {
    final snapshot = _mcpSnapshot;
    if (snapshot != null) yield* Stream.fromIterable(snapshot.states.values);
    yield* _mcpStateChanges.stream;
  }

  @override
  Future<void> ensureReady() async {
    await _send('POST', '/mcp/ready');
  }

  @override
  Future<void> save(McpServerConfig server) async {
    await _send(
      'PUT',
      '/mcp/servers/${server.id}',
      body: mcpServerToJson(server),
    );
  }

  @override
  Future<void> delete(McpServerConfig server) async {
    await _send('DELETE', '/mcp/servers/${server.id}');
  }

  @override
  Future<void> restart(McpServerConfig server) async {
    await _send('POST', '/mcp/servers/${server.id}/restart');
  }

  @override
  Future<void> refreshTools(McpServerConfig server) async {
    await _send('POST', '/mcp/servers/${server.id}/tools/refresh');
  }

  @override
  Future<McpImportResult> importConfig() async {
    final json = await _send('POST', '/mcp/import', body: const {});
    return mcpImportFromJson(Map<String, dynamic>.from(json as Map));
  }

  @override
  Future<McpImportResult> importConfigText(
    String raw, {
    String? sourcePath,
  }) async {
    final json = await _send(
      'POST',
      '/mcp/import',
      body: {'text': raw, 'sourcePath': ?sourcePath},
    );
    return mcpImportFromJson(Map<String, dynamic>.from(json as Map));
  }

  @override
  Future<String> exportConfig() async {
    final json = await _get('/mcp/export');
    return '${json['text'] ?? ''}';
  }

  @override
  Stream<List<Project>> watchProjects() =>
      _pollList('/projects', 'projects', _project, const Duration(seconds: 2));

  @override
  Stream<Map<String, int>> watchChatCounts() async* {
    while (!_disposed) {
      try {
        final json = await _get('/projects/counts');
        yield {
          for (final entry in (json['counts'] as Map? ?? const {}).entries)
            '${entry.key}': entry.value is num
                ? (entry.value as num).toInt()
                : 0,
        };
      } on AgentApiException {
        // Следующий тик попробует снова.
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  @override
  Stream<List<PolicyProfile>> watchPolicyProfiles() => _pollList(
    '/policy-profiles',
    'profiles',
    _policy,
    const Duration(seconds: 5),
  );

  @override
  Stream<List<ProjectFact>> watchFacts(String projectId) => _pollList(
    '/projects/$projectId/facts',
    'facts',
    _fact,
    const Duration(seconds: 2),
  );

  @override
  Stream<List<ProjectSkill>> watchSkills(String projectId) => _pollList(
    '/projects/$projectId/skills',
    'skills',
    _skill,
    const Duration(seconds: 5),
  );

  @override
  Stream<List<Chat>> watchProjectChats(String projectId) => _pollList(
    '/projects/$projectId/chats',
    'chats',
    _chat,
    const Duration(seconds: 2),
  );

  @override
  Future<void> saveProject(Project project) async {
    await _send('PUT', '/projects/${project.id}', body: _projectBody(project));
  }

  @override
  Future<void> deleteProject(String id) async {
    await _send('DELETE', '/projects/$id');
  }

  @override
  Future<void> setTrustAgentsMd(String projectId, bool trusted) async {
    final project = await _projectById(projectId);
    await saveProject(project.copyWith(trustAgentsMd: trusted));
  }

  @override
  Future<void> setSkillTrusted(
    String projectId,
    String name, {
    required bool trusted,
  }) async {
    await _send(
      'PUT',
      '/projects/$projectId/skills/$name',
      body: {'trusted': trusted},
    );
  }

  @override
  Future<void> trustWorkspace(String projectId) async {
    await _send('POST', '/projects/$projectId/trust');
  }

  @override
  Future<void> addFact(ProjectFact fact) async {
    await _send(
      'POST',
      '/projects/${fact.projectId}/facts',
      body: _factBody(fact),
    );
  }

  @override
  Future<void> deleteFact(String projectId, String factId) async {
    await _send('DELETE', '/projects/$projectId/facts/$factId');
  }

  @override
  Future<void> savePolicyProfile(PolicyProfile profile) async {
    await _send(
      'PUT',
      '/policy-profiles/${profile.id}',
      body: _policyBody(profile),
    );
  }

  @override
  Future<void> deletePolicyProfile(String id) async {
    await _send('DELETE', '/policy-profiles/$id');
  }

  @override
  Future<List<String>> readDenylist() async {
    await _loadGlobalSettings();
    return [
      for (final item in (_globalSettings?['denylist'] as List? ?? const []))
        if (item is String) item,
    ];
  }

  @override
  Future<SecurityProfile> readSecurityProfile() async {
    await _loadGlobalSettings();
    final raw = _globalSettings?['securityProfile'];
    return raw is String
        ? SecurityProfile.decode(raw)
        : const SecurityProfile();
  }

  Future<Project> _projectById(String id) async {
    final json = await _get('/projects');
    for (final item in (json['projects'] as List? ?? const [])) {
      if (item is Map && item['id'] == id) {
        return _project(Map<String, dynamic>.from(item));
      }
    }
    throw AgentApiException(404, 'project_not_found', 'project $id not found');
  }

  Stream<List<T>> _pollList<T>(
    String path,
    String key,
    T Function(Map<String, dynamic>) parse,
    Duration interval,
  ) async* {
    while (!_disposed) {
      try {
        final json = await _get(path);
        yield [
          for (final item in (json[key] as List? ?? const []))
            if (item is Map) parse(Map<String, dynamic>.from(item)),
        ];
      } on AgentApiException {
        // Следующий тик попробует снова.
      }
      await Future<void>.delayed(interval);
    }
  }

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

Project _project(Map<String, dynamic> json) => Project(
  id: _string(json, 'id'),
  hostId: _string(json, 'hostId'),
  name: _string(json, 'name'),
  workspace: _string(json, 'workspace'),
  workspaceKey: _string(json, 'workspaceKey'),
  policyProfileId: json['policyProfileId'] as String?,
  trustAgentsMd: json['trustAgentsMd'] == true,
  skillsInitialized: json['skillsInitialized'] == true,
  archivedAt: _date(json['archivedAt']),
  createdAt: _date(json['createdAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
  updatedAt: _date(json['updatedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
);

Map<String, Object?> _projectBody(Project project) => {
  'hostId': project.hostId,
  'name': project.name,
  'workspace': project.workspace,
  'workspaceKey': project.workspaceKey,
  'policyProfileId': project.policyProfileId,
  'trustAgentsMd': project.trustAgentsMd,
  'skillsInitialized': project.skillsInitialized,
  'archivedAt': project.archivedAt?.toUtc().toIso8601String(),
  'createdAt': project.createdAt.toUtc().toIso8601String(),
  'updatedAt': project.updatedAt.toUtc().toIso8601String(),
};

ProjectFact _fact(Map<String, dynamic> json) => ProjectFact(
  id: _string(json, 'id'),
  projectId: _string(json, 'projectId'),
  text: _string(json, 'text'),
  createdAt: _date(json['createdAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
);

Map<String, Object?> _factBody(ProjectFact fact) => {
  'id': fact.id,
  'text': fact.text,
  'createdAt': fact.createdAt.toUtc().toIso8601String(),
};

ProjectSkill _skill(Map<String, dynamic> json) =>
    ProjectSkill(name: _string(json, 'name'), trusted: json['trusted'] == true);

PolicyProfile _policy(Map<String, dynamic> json) => PolicyProfile(
  id: _string(json, 'id'),
  name: _string(json, 'name'),
  description: json['description'] as String?,
  profile: SecurityProfile.decode('${json['profile'] ?? '{}'}'),
  createdAt: _date(json['createdAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
  updatedAt: _date(json['updatedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
);

Map<String, Object?> _policyBody(PolicyProfile profile) => {
  'name': profile.name,
  'description': profile.description,
  'profile': profile.profile.encode(),
  'createdAt': profile.createdAt.toUtc().toIso8601String(),
  'updatedAt': profile.updatedAt.toUtc().toIso8601String(),
};

AgentSettingsSnapshot _snapshotFrom(Map<String, dynamic> json) {
  final rawLimits = json['limits'];
  final rawCatalog = json['catalog'];
  return AgentSettingsSnapshot(
    defaultModel: '${json['defaultModel'] ?? ''}',
    titleModel: '${json['titleModel'] ?? ''}',
    subagentModel: '${json['subagentModel'] ?? ''}',
    fallbackModel: '${json['fallbackModel'] ?? ''}',
    defaultPolicy: '${json['defaultPolicy'] ?? 'ask'}',
    denylist: [
      for (final item in (json['denylist'] as List? ?? const []))
        if (item is String) item,
    ],
    securityProfile: SecurityProfile.decode(
      '${json['securityProfile'] ?? '{}'}',
    ),
    limits: rawLimits is Map
        ? AppLimits.fromJson(jsonEncode(Map<String, dynamic>.from(rawLimits)))
        : const AppLimits(),
    pinnedModels: [
      for (final item in (json['pinnedModels'] as List? ?? const []))
        if (item is String) item,
    ],
    stepsDisplay: json['steps'] is Map
        ? _steps(Map<String, dynamic>.from(json['steps'] as Map))
        : StepsDisplay.defaults,
    apiKeyTail: '${json['apiKeyTail'] ?? ''}',
    catalog: rawCatalog is Map
        ? _catalogFrom(Map<String, dynamic>.from(rawCatalog))
        : const ModelCatalogState(),
  );
}

LlmKeyInfo _keyInfo(Map<String, dynamic> json) => LlmKeyInfo(
  label: '${json['label'] ?? ''}',
  usage: _double(json['usage']) ?? 0,
  limit: _double(json['limit']),
  limitRemaining: _double(json['limitRemaining']),
  limitReset: json['limitReset'] as String?,
  isFreeTier: json['isFreeTier'] == true,
  expiresAt: _date(json['expiresAt']),
);

StepsDisplay _steps(Map<String, dynamic> json) => StepsDisplay(
  group: json['group'] != false,
  expandWhileActive: json['expandWhileActive'] != false,
  thoughts: ThoughtsVisibility.values.byName('${json['thoughts'] ?? 'all'}'),
  tools: ToolsVisibility.values.byName('${json['tools'] ?? 'all'}'),
);

ModelCatalogState _catalogFrom(Map<String, dynamic> json) => ModelCatalogState(
  models: [
    for (final item in (json['models'] as List? ?? const []))
      if (item is Map) _model(Map<String, dynamic>.from(item)),
  ],
  saved: {
    for (final entry in (json['saved'] as Map? ?? const {}).entries)
      '${entry.key}': _savedModel(
        Map<String, dynamic>.from(entry.value as Map),
      ),
  },
  syncedAt: _date(json['syncedAt']),
  loading: json['loading'] == true,
  error: json['error'] as String?,
);

LlmModelInfo _model(Map<String, dynamic> json) => LlmModelInfo(
  id: _string(json, 'id'),
  name: _string(json, 'name'),
  contextLength: json['contextLength'] as int?,
  supportsTools: json['supportsTools'] == true,
  promptPrice: json['promptPrice'] as String?,
  completionPrice: json['completionPrice'] as String?,
  created: json['created'] as int?,
  inputModalities: json['inputModalities'] is List
      ? [for (final item in json['inputModalities'] as List) '$item']
      : null,
);

SavedModel _savedModel(Map<String, dynamic> json) => SavedModel(
  id: _string(json, 'id'),
  name: _string(json, 'name'),
  contextLength: json['contextLength'] as int?,
  supportsTools: json['supportsTools'] == true,
  inputModalities: json['inputModalities'] is List
      ? [for (final item in json['inputModalities'] as List) '$item']
      : null,
);

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
  createdAt: _time(json, 'createdAt'),
  updatedAt: _time(json, 'updatedAt'),
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
  createdAt: _time(json, 'createdAt'),
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
  startedAt: _time(json, 'startedAt'),
  finishedAt: _date(json['finishedAt']),
  toolCallId: json['toolCallId'] as String?,
  pendingCard: json['pendingCard'] == null
      ? null
      : jsonEncode(json['pendingCard']),
);

Map<String, Object?> _attachmentBody(AttachmentRef attachment) => {
  'name': attachment.name,
  'mode': attachment.mode.name,
  'content': attachment.content,
  'mimeType': attachment.mimeType,
  'sizeBytes': attachment.sizeBytes,
  if (attachment.bytes != null) 'bytes': base64Encode(attachment.bytes!),
};

Map<String, Object?> _hostBody(Host host) => {
  'id': host.id,
  'name': host.name,
  'kind': host.kind.name,
  'address': host.address,
  'port': host.port,
  'username': host.username,
  'authType': host.authType.name,
  'keyPath': host.keyPath,
  'hostKeyFingerprint': host.hostKeyFingerprint,
  'os': host.os.name,
  'defaultWorkspace': host.defaultWorkspace,
  'shellOverride': host.shellOverride,
  'notes': host.notes,
  'connectTimeoutSeconds': host.connectTimeoutSeconds,
  'lastCheckAt': host.lastCheckAt?.toUtc().toIso8601String(),
  'lastLatencyMs': host.lastLatencyMs,
  'lastCheckError': host.lastCheckError,
  'createdAt': host.createdAt.toUtc().toIso8601String(),
  'updatedAt': host.updatedAt.toUtc().toIso8601String(),
};

Host _host(Map<String, dynamic> json) => Host(
  id: _string(json, 'id'),
  name: _string(json, 'name'),
  kind: HostKind.values.byName(_string(json, 'kind')),
  address: json['address'] as String?,
  port: _int(json, 'port'),
  username: json['username'] as String?,
  authType: SshAuthType.values.byName('${json['authType'] ?? 'key'}'),
  keyPath: json['keyPath'] as String?,
  hostKeyFingerprint: json['hostKeyFingerprint'] as String?,
  os: HostOs.values.byName('${json['os'] ?? 'posix'}'),
  defaultWorkspace: json['defaultWorkspace'] as String?,
  shellOverride: json['shellOverride'] as String?,
  notes: json['notes'] as String?,
  connectTimeoutSeconds: json['connectTimeoutSeconds'] is num
      ? (json['connectTimeoutSeconds'] as num).toInt()
      : null,
  lastCheckAt: _date(json['lastCheckAt']),
  lastLatencyMs: json['lastLatencyMs'] is num
      ? (json['lastLatencyMs'] as num).toInt()
      : null,
  lastCheckError: json['lastCheckError'] as String?,
  createdAt:
      _date(json['createdAt']) ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  updatedAt:
      _date(json['updatedAt']) ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
);

ScheduledTask _task(Map<String, dynamic> json) => ScheduledTask(
  id: _string(json, 'id'),
  chatId: _string(json, 'chatId'),
  prompt: _string(json, 'prompt'),
  dueAt: _time(json, 'dueAt'),
  status: ScheduledTaskStatus.values.byName(_string(json, 'status')),
  error: json['error'] as String?,
  createdAt: _time(json, 'createdAt'),
  updatedAt: _time(json, 'updatedAt'),
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

DateTime? _date(Object? value) => value is String && value.isNotEmpty
    ? DateTime.tryParse(value)?.toUtc()
    : null;

DateTime _time(Map<String, dynamic> json, String key) =>
    DateTime.parse(_string(json, key)).toUtc();

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
  _RemoteSettings(this._api);

  final RemoteAgentApi _api;

  @override
  Stream<String?> watch(String key) async* {
    yield await read(key);
    yield* _api._settingsChanges.stream.map((_) => _value(key));
  }

  @override
  Future<String?> read(String key) async {
    await _api._loadGlobalSettings();
    return _value(key);
  }

  /// Значение ключа из кэша. Журналу шагов и закреплениям важно только
  /// изменение, но ключи возвращаются в том же виде, что и локальное хранилище.
  String? _value(String key) {
    final settings = _api._globalSettings;
    if (settings == null) return null;
    return switch (key) {
      SettingsRepository.keyDefaultModel => settings['defaultModel'] as String?,
      SettingsRepository.keyPinnedModels =>
        settings['pinnedModels'] == null
            ? null
            : jsonEncode(settings['pinnedModels']),
      SettingsRepository.keyStepsGroup ||
      SettingsRepository.keyStepsExpandWhileActive ||
      SettingsRepository.keyStepsThoughts ||
      SettingsRepository.keyStepsTools => jsonEncode(settings['steps']),
      _ => null,
    };
  }

  @override
  Future<List<String>> readPinnedModels() async {
    await _api._loadGlobalSettings();
    return [
      for (final id
          in (_api._globalSettings?['pinnedModels'] as List? ?? const []))
        if (id is String) id,
    ];
  }

  @override
  Future<void> savePinnedModels(List<String> ids) async {
    await _api.sendJson('PUT', '/settings/pinned', body: {'pinnedModels': ids});
    _api._publishSettings({'pinnedModels': ids});
  }

  @override
  Future<StepsDisplay> readStepsDisplay() async {
    await _api._loadGlobalSettings();
    final raw = _api._globalSettings?['steps'];
    if (raw is! Map) return StepsDisplay.defaults;
    return _steps(Map<String, dynamic>.from(raw));
  }

  @override
  Future<ChatDailyUsage> readDailyUsage(String chatId) async {
    await _api._loadChatState(chatId);
    final raw = _api._usageByChat[chatId]?['usage'];
    if (raw is! Map) return const ChatDailyUsage();
    final map = Map<String, dynamic>.from(raw);
    return ChatDailyUsage(
      promptTokens: _int(map, 'promptTokens'),
      completionTokens: _int(map, 'completionTokens'),
      costUsd: _double(map['costUsd']) ?? 0,
      requests: _int(map, 'requests'),
    );
  }

  @override
  Future<double?> readDailyBudget(String chatId) async {
    await _api._loadChatState(chatId);
    return _double(_api._usageByChat[chatId]?['budget']);
  }

  @override
  Future<void> saveDailyBudget(String chatId, double? value) async {
    await _api.sendJson(
      'PUT',
      '/chats/$chatId/budget',
      body: {'budget': value},
    );
    _api._usageByChat[chatId] = {
      ...?_api._usageByChat[chatId],
      'budget': value,
    };
  }

  @override
  Future<ChatCompactionInfo?> readCompactionInfo(String chatId) async {
    await _api._loadChatState(chatId);
    final raw = _api._usageByChat[chatId]?['compaction'];
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    return ChatCompactionInfo(
      at: DateTime.parse('${map['at']}').toUtc(),
      reason: '${map['reason'] ?? 'threshold'}',
      cutoffSeq: _int(map, 'cutoffSeq'),
      summaryChars: _int(map, 'summaryChars'),
    );
  }

  @override
  Future<void> setTrusted(
    String hostId,
    String workspace, {
    required bool trusted,
  }) async {
    await _api.sendJson(
      'PUT',
      '/hosts/$hostId/trust',
      body: {'workspace': workspace, 'trusted': trusted},
    );
  }

  @override
  AppLimits cachedLimits() {
    final raw = _api._globalSettings?['limits'];
    if (raw is! Map) return const AppLimits();
    try {
      return AppLimits.fromJson(jsonEncode(Map<String, dynamic>.from(raw)));
    } on FormatException {
      return const AppLimits();
    }
  }

  @override
  List<String> cachedPinnedModels() => [
    for (final id
        in (_api._globalSettings?['pinnedModels'] as List? ?? const []))
      if (id is String) id,
  ];

  @override
  StepsDisplay cachedStepsDisplay() {
    final raw = _api._globalSettings?['steps'];
    return raw is Map
        ? _steps(Map<String, dynamic>.from(raw))
        : StepsDisplay.defaults;
  }

  @override
  String? cached(String key) => key == 'defaultModel'
      ? (_api._globalSettings?['defaultModel'] as String?)
      : null;
}

final class _RemoteProjectStore implements ProjectStore {
  _RemoteProjectStore(this._api);

  final RemoteAgentApi _api;

  @override
  Future<Project?> forChat(String chatId) async {
    await _api._loadChatState(chatId);
    return _api._projectsByChat[chatId];
  }

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
  _RemoteModels(this._api);

  final RemoteAgentApi _api;

  @override
  ModelCatalogState get state => _api._catalog ?? const ModelCatalogState();

  @override
  Stream<ModelCatalogState> watch() async* {
    if (_api._catalog == null) await _api._loadModels();
    yield state;
    yield* _api._catalogChanges.stream;
  }

  @override
  Future<void> refresh() => _api.refreshModels();

  @override
  Future<void> remember(List<String> ids) async {
    await _api.sendJson('POST', '/models/remember', body: {'ids': ids});
  }
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
  }) => _api.send(_chatId, text, sendNow: sendNow, attachments: attachments);

  @override
  Future<void> stop({String? reason}) => _api.stop(_chatId, reason: reason);

  @override
  Future<void> continueAfterStepLimit() async {
    await _api.sendJson('PUT', '/chats/$_chatId/turn');
  }

  @override
  Future<bool> regenerateLast() async {
    final json = await _api.sendJson('POST', '/chats/$_chatId/regenerations');
    return json is Map && json['accepted'] == true;
  }

  @override
  void promoteQueued(int index) {
    unawaited(
      _api.sendJson(
        'PATCH',
        '/chats/$_chatId/queue/$index',
        body: {'position': 0},
      ),
    );
  }

  @override
  QueuedPrompt? takeQueued(int index) {
    final items = _api._queues[_chatId];
    if (items == null || index < 0 || index >= items.length) return null;
    final item = items.removeAt(index);
    unawaited(_api.sendJson('DELETE', '/chats/$_chatId/queue/$index'));
    return item;
  }

  @override
  Future<bool> editUserMessage(
    String messageId,
    String newText, {
    List<AttachmentRef>? attachments,
  }) async {
    final json = await _api.sendJson(
      'PATCH',
      '/chats/$_chatId/messages/$messageId',
      body: {'text': newText},
    );
    return json is Map && json['accepted'] == true;
  }

  @override
  Future<void> deleteAfter(String messageId) async {
    await _api.sendJson(
      'DELETE',
      '/chats/$_chatId/messages/$messageId/following',
    );
  }

  @override
  Future<void> restoreUnanswered() => _api.openChat(_chatId);

  @override
  Future<void> compactNow({bool force = false}) async {
    await _api.sendJson(
      'POST',
      '/chats/$_chatId/compactions',
      body: {'force': force},
    );
  }
}

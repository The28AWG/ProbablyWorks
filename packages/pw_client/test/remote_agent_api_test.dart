import 'dart:async';

import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/agent_settings_api.dart';
import 'package:pw_agent/agent/api/mcp_api.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/steps_display.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/agent/mcp/mcp_client_manager.dart';
import 'package:pw_agent/agent/mcp/mcp_service.dart';
import 'package:pw_agent/agent/policy/security_profile.dart';
import 'package:pw_agent/agent/schedule/scheduled_task.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/domain/mcp_server.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';
import 'package:pw_client/pw_client.dart';
import 'package:pw_server/pw_server.dart';
import 'package:test/test.dart';

const _token = 'client-token';

void main() {
  late _FakeAgent backend;
  late _FakeSettings settings;
  late _FakeMcp mcp;
  late ApiServer server;
  late RemoteAgentApi remote;

  setUp(() async {
    backend = _FakeAgent();
    settings = _FakeSettings();
    mcp = _FakeMcp();
    server = ApiServer(
      backend,
      _token,
      port: 0,
      settingsApi: settings,
      mcpApi: mcp,
    );
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

  test('parses server timestamps as UTC', () async {
    final chat = (await remote.chats()).single;
    final host = (await remote.hosts()).single;
    final message = (await remote.messages('c1')).single;

    expect(chat.createdAt.isUtc, isTrue);
    expect(chat.updatedAt.isUtc, isTrue);
    expect(message.createdAt.isUtc, isTrue);
    expect(host.createdAt.isUtc, isTrue);
    expect(host.updatedAt.isUtc, isTrue);
    expect(host.lastCheckAt?.isUtc, isTrue);
    expect(host.lastLatencyMs, 12);
  });

  test('sends a message and resolves a card', () async {
    await remote.send('c1', 'do it', sendNow: true);
    await remote.resolveApproval('a1', ApprovalAction.allowTurn);
    await remote.answerQuestion('q1', 'yes');

    expect(backend.sent, [('c1', 'do it', true)]);
    expect(backend.decisions, [ApprovalAction.allowTurn]);
    expect(backend.answers, ['yes']);
  });

  test('upserts a chat through the remote API', () async {
    await remote.saveChat(
      Chat(
        id: 'new-chat',
        hostId: 'local',
        title: 'New',
        createdAt: DateTime.utc(2026, 11, 11),
        updatedAt: DateTime.utc(2026, 11, 11),
      ),
    );

    expect(backend.savedChatId, 'new-chat');
  });

  test('updates chat fields through the remote API', () async {
    await remote.updateChat('c1', model: 'vendor/model');

    expect(backend.updatedModel, 'vendor/model');
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

  test('checks connection and reports online', () async {
    expect(await remote.checkConnection(), isTrue);
    expect(remote.status, AgentStatus.online);
  });

  test('exposes ChatApi for the remote chat screen', () async {
    final chat = await remote.chat('c1');

    expect(chat?.title, 'Test chat');
    expect(remote.draftChat(hostId: 'local').hostId, 'local');
    expect(remote.session('c1').isRunning, isFalse);
    expect(remote.chatStore, isNotNull);
  });

  test('reads and writes settings through the remote API', () async {
    final snapshot = await remote.load();

    expect(snapshot.defaultModel, 'openai/gpt-4o');
    expect(snapshot.pinnedModels, ['openai/gpt-4o']);
    expect(snapshot.catalog.loaded, isTrue);

    await remote.writeSetting('titleModel', 'openai/gpt-4o-mini');
    await remote.savePinnedModels(['a']);
    await remote.saveStepsDisplay(
      const StepsDisplay(group: false, thoughts: ThoughtsVisibility.expanded),
    );
    await remote.saveDenylist(['rm -rf']);
    await remote.saveSecurityProfile(const SecurityProfile());
    await remote.saveLimits(const AppLimits(attachmentsPerMessage: 2));
    await remote.saveApiKey('sk-or-v1-secret-abc');

    expect(settings.written['titleModel'], 'openai/gpt-4o-mini');
    expect(settings.pinned, ['a']);
    expect(settings.steps.group, isFalse);
    expect(settings.steps.thoughts, ThoughtsVisibility.expanded);
    expect(settings.denylist, ['rm -rf']);
    expect(settings.limits.attachmentsPerMessage, 2);
    expect(settings.savedKey, 'sk-or-v1-secret-abc');

    final info = await remote.checkKey();
    expect(info?.label, 'sk-or-v1-...abc');

    await remote.refreshModels();
    await remote.rememberModels(['openai/gpt-4o']);
    await remote.deleteApiKey();
    expect(settings.refreshed, 1);
    expect(settings.remembered, ['openai/gpt-4o']);
    expect(settings.savedKey, isNull);
  });

  test('streams catalog and pin updates without polling', () async {
    await remote.load();
    final catalogs = <ModelCatalogState>[];
    final pins = <List<String>>[];
    final catalogSub = remote.watchCatalog().listen(catalogs.add);
    final pinsSub = remote.watchPinnedModels().listen(pins.add);
    addTearDown(catalogSub.cancel);
    addTearDown(pinsSub.cancel);

    await Future<void>.delayed(Duration.zero);
    expect(catalogs, isNotEmpty);
    expect(pins, isNotEmpty);

    await remote.refreshModels();
    await remote.savePinnedModels(['b']);
    await Future<void>.delayed(Duration.zero);

    expect(catalogs.length, greaterThan(1));
    expect(pins.last, ['b']);
  });

  test('settings watchers reuse one snapshot and see saves', () async {
    final defaults = <String?>[];
    final steps = <String?>[];
    final defaultSub = remote.settings
        .watch(SettingsRepository.keyDefaultModel)
        .listen(defaults.add);
    final stepsSub = remote.settings
        .watch(SettingsRepository.keyStepsGroup)
        .listen(steps.add);
    addTearDown(defaultSub.cancel);
    addTearDown(stepsSub.cancel);

    await remote.settings.read(SettingsRepository.keyPinnedModels);
    await remote.settings.readStepsDisplay();
    expect(defaults, ['openai/gpt-4o']);
    expect(steps, isNotEmpty);

    await remote.writeSetting(
      SettingsRepository.keyDefaultModel,
      'openai/gpt-4o-mini',
    );
    await Future<void>.delayed(Duration.zero);

    expect(defaults.last, 'openai/gpt-4o-mini');
    expect(settings.loads, 1);
    await defaultSub.cancel();
    await stepsSub.cancel();
  });

  test('manages MCP servers through the remote API', () async {
    final snapshot = await remote.snapshot();
    expect(snapshot.servers.single.id, 'mcp-1');
    expect(snapshot.servers.single.createdAt.isUtc, isTrue);
    expect(snapshot.states['mcp-1']?.status, McpConnectionStatus.connected);

    final server = snapshot.servers.single.copyWith(name: 'Docs');
    await remote.save(server);
    await remote.restart(server);
    await remote.refreshTools(server);
    await remote.delete(server);

    expect(mcp.saved?.name, 'Docs');
    expect(mcp.saved?.createdAt.isUtc, isTrue);
    expect(mcp.restarted, 'mcp-1');
    expect(mcp.refreshed, 'mcp-1');
    expect(mcp.deleted, 'mcp-1');

    final imported = await remote.importConfigText(
      '{"mcpServers":{}}',
      sourcePath: '/tmp/mcp.json',
    );
    final exported = await remote.exportConfig();

    expect(imported.status, McpImportStatus.imported);
    expect(mcp.importedText, '{"mcpServers":{}}');
    expect(mcp.importedFrom, '/tmp/mcp.json');
    expect(exported, '{"mcpServers":{}}');
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
  String? updatedModel;
  String? savedChatId;

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
  AgentStatus get status => AgentStatus.online;

  @override
  Stream<AgentStatus> get statusChanges => const Stream<AgentStatus>.empty();

  @override
  Future<bool> checkConnection() async => true;

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
      lastCheckAt: DateTime(2026, 11, 11, 12, 30),
      lastLatencyMs: 12,
    ),
  ];

  @override
  Future<List<Chat>> chats() async => [_chat];

  @override
  Future<Chat?> chat(String id) async => id == 'c1' ? _chat : null;

  @override
  Future<Chat> createChat(String hostId) async => _chat.copyWith(id: 'c2');

  @override
  Future<void> saveChat(Chat chat) async {
    savedChatId = chat.id;
  }

  @override
  Future<void> renameChat(String chatId, String title) => Future<void>.value();

  @override
  Future<void> updateChat(
    String chatId, {
    String? title,
    String? model,
    PolicyMode? policyMode,
    String? workspace,
    bool workspaceSpecified = false,
  }) async {
    updatedModel = model;
  }

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
  Future<void> send(
    String chatId,
    String text, {
    bool sendNow = false,
    List<AttachmentRef> attachments = const [],
  }) async {
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

  @override
  Future<void> resumeAfterRestart() => Future<void>.value();
}

final class _FakeMcp implements McpApi {
  McpServerConfig? saved;
  String? deleted;
  String? restarted;
  String? refreshed;
  String? importedText;
  String? importedFrom;

  final _server = McpServerConfig(
    id: 'mcp-1',
    name: 'Search',
    transport: McpTransport.http,
    source: McpServerSource.user,
    url: 'https://example.test/mcp',
    createdAt: DateTime.utc(2026, 11, 11),
    updatedAt: DateTime.utc(2026, 11, 11),
  );

  @override
  Future<McpSnapshot> snapshot() async => McpSnapshot(
    servers: [_server],
    states: const {
      'mcp-1': McpServerState(
        serverId: 'mcp-1',
        status: McpConnectionStatus.connected,
        tools: [McpToolInfo(name: 'search', inputSchema: {})],
      ),
    },
  );

  @override
  Stream<McpServerState> watchStates() => const Stream.empty();

  @override
  Future<void> ensureReady() => Future<void>.value();

  @override
  Future<void> save(McpServerConfig server) async {
    saved = server;
  }

  @override
  Future<void> delete(McpServerConfig server) async {
    deleted = server.id;
  }

  @override
  Future<void> restart(McpServerConfig server) async {
    restarted = server.id;
  }

  @override
  Future<void> refreshTools(McpServerConfig server) async {
    refreshed = server.id;
  }

  @override
  Future<McpImportResult> importConfig() async =>
      const McpImportResult.imported('/default/mcp.json');

  @override
  Future<McpImportResult> importConfigText(
    String raw, {
    String? sourcePath,
  }) async {
    importedText = raw;
    importedFrom = sourcePath;
    return McpImportResult.imported(sourcePath);
  }

  @override
  Future<String> exportConfig() async => '{"mcpServers":{}}';
}

final class _FakeSettings implements AgentSettingsApi {
  String? savedKey;
  final written = <String, String?>{};
  var pinned = <String>['openai/gpt-4o'];
  var denylist = <String>[];
  var securityProfile = const SecurityProfile();
  var steps = const StepsDisplay();
  var limits = const AppLimits();
  var refreshed = 0;
  var remembered = <String>[];

  AgentSettingsSnapshot get _snapshot => AgentSettingsSnapshot(
    defaultModel: 'openai/gpt-4o',
    titleModel: '',
    subagentModel: '',
    fallbackModel: '',
    defaultPolicy: 'ask',
    denylist: denylist,
    securityProfile: const SecurityProfile(),
    limits: limits,
    pinnedModels: pinned,
    stepsDisplay: steps,
    apiKeyTail: savedKey == null ? '' : 'abc',
    catalog: ModelCatalogState(
      models: [
        LlmModelInfo(id: 'openai/gpt-4o', name: 'GPT-4o', supportsTools: true),
      ],
      syncedAt: DateTime.utc(2026, 11, 11),
    ),
  );

  var loads = 0;

  @override
  Future<AgentSettingsSnapshot> load() async {
    loads++;
    return _snapshot;
  }

  @override
  Stream<ModelCatalogState> watchCatalog() => Stream.value(_snapshot.catalog);

  @override
  Stream<List<String>> watchPinnedModels() => Stream.value(pinned);

  @override
  Future<void> writeSetting(String key, String? value) async {
    written[key] = value;
  }

  @override
  Future<void> saveStepsDisplay(StepsDisplay value) async {
    steps = value;
  }

  @override
  Future<void> savePinnedModels(List<String> ids) async {
    pinned = ids;
  }

  @override
  Future<void> saveDenylist(List<String> patterns) async {
    denylist = patterns;
  }

  @override
  Future<void> saveSecurityProfile(SecurityProfile profile) async {
    securityProfile = profile;
  }

  @override
  Future<void> saveLimits(AppLimits value) async {
    limits = value;
  }

  @override
  Future<void> saveApiKey(String key) async {
    savedKey = key;
  }

  @override
  Future<void> deleteApiKey() async {
    savedKey = null;
  }

  @override
  Future<LlmKeyInfo?> checkKey() async => savedKey == null
      ? null
      : LlmKeyInfo(
          label: 'sk-or-v1-...abc',
          usage: 1,
          limit: 10,
          limitRemaining: 9,
          isFreeTier: false,
        );

  @override
  Future<void> refreshModels() async {
    refreshed++;
  }

  @override
  Future<void> rememberModels(List<String> ids) async {
    remembered = ids;
  }
}

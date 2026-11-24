import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:plugin_api/plugin_api.dart' as plugins;
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/agent_settings_api.dart';
import 'package:pw_agent/agent/api/chat_api.dart';
import 'package:pw_agent/agent/api/client_session_api.dart';
import 'package:pw_agent/agent/api/data_api.dart';
import 'package:pw_agent/agent/api/mcp_api.dart';
import 'package:pw_agent/agent/api/plugin_api.dart';
import 'package:pw_agent/agent/api/projects_api.dart';
import 'package:pw_agent/agent/api/push_api.dart';
import 'package:pw_agent/agent/api/security_audit_api.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/project.dart';
import 'package:pw_agent/agent/domain/search.dart';
import 'package:pw_agent/agent/domain/steps_display.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/agent/loop/prompt_queue.dart';
import 'package:pw_agent/agent/mcp/mcp_client_manager.dart';
import 'package:pw_agent/agent/mcp/mcp_service.dart';
import 'package:pw_agent/agent/policy/security_profile.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/domain/mcp_server.dart';
import 'package:pw_agent/core/security/security_audit.dart';
import 'package:pw_agent/core/util/char_substring.dart';
import 'package:pw_agent/providers/ai/llama_cpp/llama_cpp_connection.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/local_models.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';
import 'package:pw_agent/providers/ai/model_runtime.dart';
import 'package:pw_agent/providers/ai/openrouter/openrouter_llm_provider.dart';
import 'package:pw_client/pw_client.dart';
import 'package:pw_server/pw_server.dart';
import 'package:test/test.dart';

const _token = 'client-token';

void main() {
  late _FakeAgent backend;
  late _FakeSettings settings;
  late _FakeData data;
  late _FakeMcp mcp;
  late _FakePlugins pluginsApi;
  late _FakeSecurityAudit securityAudit;
  late _FakePush push;
  late _FakeProjects projectsApi;
  late _FakeDraftStore draftStore;
  late _FakeQueueSession queueSession;
  late ApiServer server;
  late RemoteAgentApi remote;

  setUp(() async {
    backend = _FakeAgent();
    settings = _FakeSettings();
    data = _FakeData();
    mcp = _FakeMcp();
    pluginsApi = _FakePlugins();
    securityAudit = _FakeSecurityAudit();
    push = _FakePush();
    projectsApi = _FakeProjects();
    draftStore = _FakeDraftStore();
    queueSession = _FakeQueueSession();
    server = ApiServer(
      backend,
      _token,
      port: 0,
      projects: projectsApi,
      dataApi: data,
      settingsApi: settings,
      mcpApi: mcp,
      pluginApi: pluginsApi,
      securityAuditApi: securityAudit,
      pushApi: push,
      chat: _FakeDraftChatApi(store: draftStore, queueSession: queueSession),
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

  test('reads usage, clears history and resets settings', () async {
    final usage = await remote.usage();
    expect(usage.chats, 2);
    expect(usage.messages, 10);
    expect(usage.completedTasks, 2);

    final result = await remote.clearHistory(olderThanDays: 30);
    expect(result.deletedChats, 1);
    expect(result.compacted, isFalse);
    expect(data.clearedDays, 30);

    await remote.resetSettings();
    expect(data.resets, 1);
  });

  test('reads chats, hosts and journal', () async {
    final chats = await remote.chats();
    final hosts = await remote.hosts();
    final messages = await remote.messages('c1');
    final runs = await remote.runs('c1');

    expect(chats.single.title, 'Test chat');
    expect(hosts.single.id, 'local');
    expect(hosts.single.systemLabel, 'Ubuntu 24.04.1 LTS');
    expect(messages.single.text, 'hello');
    expect(runs.single.status, ToolRunStatus.done);
    expect(runs.single.resultError, isTrue);
  });

  test('load() warms the synchronous settings cache', () async {
    expect(remote.settings.cached(SettingsRepository.keyDefaultModel), isNull);

    await remote.load();

    expect(
      remote.settings.cached(SettingsRepository.keyDefaultModel),
      'openai/gpt-4o',
    );
  });

  test('draft chat uses the profile default policy', () async {
    settings.defaultPolicy = 'yolo';
    await remote.load();

    expect(remote.draftChat(hostId: 'local').policyMode, PolicyMode.yolo);
  });

  test('reads and revises project memory', () async {
    expect(await remote.watchMemory('p1').first, isNull);

    await remote.reviseMemory('p1', 'add the build command');

    final memory = await remote.watchMemory('p1').first;
    expect(memory?.summary, contains('pnpm'));
    expect(projectsApi.instruction, 'add the build command');
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
        reasoning: ReasoningPreference.high,
        createdAt: DateTime.utc(2026, 11, 11),
        updatedAt: DateTime.utc(2026, 11, 11),
      ),
    );

    expect(backend.savedChatId, 'new-chat');
    expect(backend.savedReasoning, ReasoningPreference.high);
  });

  test('searches chats and messages through the remote API', () async {
    final hits = await remote.search(
      const SearchQuery(
        text: 'alpha',
        scope: SearchScope.project,
        projectId: 'p1',
        limit: 5,
      ),
    );

    expect(hits.single.kind, SearchHitKind.chat);
    expect(hits.single.chatId, 'c1');
    expect(backend.searchQueries.single.text, 'alpha');
    expect(backend.searchQueries.single.scope, SearchScope.project);
    expect(backend.searchQueries.single.projectId, 'p1');
  });

  test('creates a new chat with the client-generated id', () async {
    await remote.chatStore.createChat(
      Chat(
        id: 'draft-chat',
        hostId: 'local',
        title: 'New',
        createdAt: DateTime.utc(2026, 11, 11),
        updatedAt: DateTime.utc(2026, 11, 11),
      ),
    );

    expect(backend.savedChatId, 'draft-chat');
  });

  test('updates chat fields through the remote API', () async {
    await remote.updateChat('c1', model: 'vendor/model');

    expect(draftStore.model, 'vendor/model');
  });

  test('reads pending tasks and passes the fork choice', () async {
    backend.pendingTasks = 3;
    expect(await remote.pendingScheduledTasks('c1', untilMessageId: 'a1'), 3);
    expect(backend.countsUntilMessageId, 'a1');

    await remote.forkChat('c1', untilMessageId: 'a1', copyPendingTasks: true);
    expect(backend.copiedPendingTasks, isTrue);
    expect(backend.forkedUntilMessageId, 'a1');

    await remote.forkChat('c1');
    expect(backend.copiedPendingTasks, isFalse);
  });

  test('round-trips the scheduled task count of a rewind card', () async {
    backend.editRequests.add(
      const EditFileChangesRequest(
        id: 'e1',
        chatId: 'c1',
        files: [],
        shellMayHaveChangedFiles: false,
        scheduledTasks: 2,
      ),
    );

    final request = (await remote.pendingEditFileChanges('c1')).single;

    expect(request.scheduledTasks, 2);
    expect(request.files, isEmpty);
  });

  test('maps missing resources to null and 404 errors', () async {
    expect(await remote.chat('missing'), isNull);
    await expectLater(
      remote.messages('missing'),
      throwsA(
        isA<AgentApiException>()
            .having((error) => error.status, 'status', 404)
            .having((error) => error.requestId, 'requestId', isNotNull),
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

  test('receives local model downloads over SSE', () async {
    await remote.startEvents();
    await remote.eventsReady.timeout(const Duration(seconds: 3));
    final states = <LocalModelsState>[];
    final sub = remote.localModels.watch().listen(states.add);
    addTearDown(sub.cancel);

    settings.localModelsApi.publish(
      const LocalModelsState(
        downloads: [
          LocalModelDownload(
            id: 'd',
            name: 'Qwen 4B',
            source: 'hf://owner/repo/qwen.gguf',
            receivedBytes: 10,
            totalBytes: 100,
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(states.last.downloads.single.receivedBytes, 10);
  });

  test('manages local model files through the remote API', () async {
    final state = await remote.localModels.watch().first;
    expect(state.supported, isTrue);

    await remote.localModels.startInstall(
      'hf://owner/repo/model.gguf',
      name: 'M',
    );
    expect(settings.localModelsApi.installs, ['hf://owner/repo/model.gguf']);

    await remote.localModels.importPath('/models/local.gguf');
    expect(settings.localModelsApi.imports, ['/models/local.gguf']);

    await remote.localModels.updateSettings(
      'model-1',
      const LocalModelSettings(contextSize: 8192),
    );
    expect(settings.localModelsApi.settings?.contextSize, 8192);

    await remote.localModels.saveAutoUnload(30);
    expect(settings.localModelsApi.autoUnload, 30);

    await remote.localModels.delete('model-1');
    expect(settings.localModelsApi.deleted, ['model-1']);

    await remote.localModels.clearCache();
    expect(settings.localModelsApi.cleared, 1);
  });

  test('reads and writes settings through the remote API', () async {
    final snapshot = await remote.load();

    expect(snapshot.defaultModel, 'openai/gpt-4o');
    expect(snapshot.defaultReasoning, ReasoningPreference.high);
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
    await remote.saveProviderApiKey(
      openRouterProviderId,
      'sk-or-v1-secret-abc',
    );

    expect(settings.written['titleModel'], 'openai/gpt-4o-mini');
    expect(settings.pinned, ['a']);
    expect(settings.steps.group, isFalse);
    expect(settings.steps.thoughts, ThoughtsVisibility.expanded);
    expect(settings.denylist, ['rm -rf']);
    expect(settings.limits.attachmentsPerMessage, 2);
    expect(settings.statuses[openRouterProviderId]!.apiKeySet, isTrue);

    final info = await remote.checkProvider(openRouterProviderId);
    expect(info.keyInfo?.label, 'sk-or-v1-...abc');

    await remote.refreshModels();
    await remote.rememberModels(['openai/gpt-4o']);
    await remote.deleteProviderApiKey(openRouterProviderId);
    expect(settings.refreshed, 1);
    expect(settings.remembered, ['openai/gpt-4o']);
    expect(settings.statuses[openRouterProviderId]!.apiKeySet, isFalse);
  });

  test('reads and writes llama.cpp settings through the remote API', () async {
    final snapshot = await remote.load();
    final llama = snapshot.catalog.providerStatuses[llamaCppProviderId]!;
    expect(llama.enabled, isTrue);
    expect(llama.baseUrl, llamaCppDefaultBaseUrl);
    expect(llama.available, isTrue);

    await remote.saveProviderBaseUrl(
      llamaCppProviderId,
      'http://127.0.0.1:9000',
    );
    await remote.setProviderEnabled(llamaCppProviderId, false);
    await remote.saveProviderApiKey(llamaCppProviderId, 'secret-key');
    final status = await remote.checkProvider(llamaCppProviderId);
    expect(status.enabled, isFalse);
    expect(status.baseUrl, 'http://127.0.0.1:9000');
    expect(status.apiKeySet, isTrue);
    expect(status.apiKeyTail, 'key');
    expect(settings.llamaCppChecked, 1);

    await remote.deleteProviderApiKey(llamaCppProviderId);
    expect(settings.statuses[llamaCppProviderId]!.apiKeySet, isFalse);
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
    final snapshot = await remote.mcpSnapshot();
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

  test('manages plugins through the remote API', () async {
    final snapshot = await remote.pluginSnapshot();
    expect(snapshot.plugins.first.id, 'first');
    expect(snapshot.enabled, {'first'});
    expect(await remote.missingDependencies('second'), {'first'});
    expect(await remote.dependents('first'), {'second'});

    await remote.setEnabled({'first', 'second'}, enabled: false);
    expect(pluginsApi.lastIds, {'first', 'second'});

    final settings = remote.settingsFor('first');
    expect(await settings.read(), {'version': 1});
    await settings.save({'commands': []});
    expect(pluginsApi.savedSettings, {'commands': []});
    expect(await settings.hasSecret('searchKey'), isFalse);
    await settings.writeSecret('searchKey', 'secret');
    expect(await settings.hasSecret('searchKey'), isTrue);
    await settings.writeSecret('searchKey', null);
    expect(pluginsApi.secrets, isEmpty);
    await remote.refresh();
    expect(pluginsApi.refreshed, 1);

    pluginsApi.busy = true;
    await expectLater(
      remote.setEnabled({'first'}, enabled: false),
      throwsA(
        isA<AgentApiException>().having(
          (error) => error.code,
          'code',
          'agent_busy',
        ),
      ),
    );
  });

  test('refreshes watched chats after a state change', () async {
    await remote.startEvents();
    await remote.eventsReady;
    final snapshots = <List<Chat>>[];
    final changed = Completer<void>();
    final sub = remote.watchChats().listen((chats) {
      snapshots.add(chats);
      if (snapshots.length > 1 && !changed.isCompleted) changed.complete();
    });
    addTearDown(sub.cancel);
    await remote.chats();
    await Future<void>.delayed(Duration.zero);

    await remote.updateChat('c1', model: 'vendor/model');
    await changed.future.timeout(const Duration(seconds: 3));

    expect(snapshots.length, greaterThan(1));
    expect(snapshots.last.single.id, 'c1');
  });

  test('reads the server security report', () async {
    final report = await remote.run();

    expect(report.status, SecurityStatus.baseline);
    expect(report.mode, SecurityRunMode.headless);
    expect(report.generatedAt.isUtc, isTrue);
    expect(report.findings.single.code, SecurityFindingCode.headlessApi);
  });

  test('reads and saves push settings over HTTP', () async {
    final current = await remote.pushSettings();
    expect(current.enabled, isFalse);
    expect(current.hasToken, isFalse);

    await remote.savePush(
      const PushSettings(enabled: true, relayUrl: 'https://relay.test'),
      token: 'relay-token',
    );
    expect(push.saved?.enabled, isTrue);
    expect(push.saved?.relayUrl, 'https://relay.test');
    expect(push.token, 'relay-token');

    await remote.testPush();
    expect(push.tested, isTrue);
  });

  test('saves draft revisions through the remote chat store', () async {
    final revision = await remote.chatStore.saveDraft(
      'c1',
      const ChatDraft(text: 'hello'),
    );
    expect(revision, 1);
    final editsRevision = await remote.chatStore.saveMessageEdits('c1', {
      'm1': const ChatDraft(text: 'edited'),
    });
    expect(editsRevision, 2);
  });

  test('streams draft changes from another client', () async {
    await remote.startEvents();
    await remote.eventsReady;
    final changed = Completer<String>();
    final sub = remote.chatStore.watchDraftChanges().listen((chatId) {
      if (!changed.isCompleted) changed.complete(chatId);
    });
    addTearDown(sub.cancel);

    await remote.chatStore.saveDraft(
      'c1',
      const ChatDraft(text: 'from another client'),
    );

    expect(await changed.future.timeout(const Duration(seconds: 3)), 'c1');
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
        const AgentUsageUpdated('c1', 123, 32000, contextWindowKnown: false),
      )
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

    expect(events, hasLength(2));
    expect(events.first, isA<AgentTurnStarted>());
    final usage = events.last as AgentUsageUpdated;
    expect(usage.contextWindowKnown, false);
    expect(approvals.single.id, 'a1');
  });

  test('applies queue and live turn snapshots from SSE', () async {
    await remote.startEvents();
    await remote.eventsReady;
    final session = remote.session('c1');
    final queueChanged = Completer<void>();
    final snapshotSeen = Completer<void>();
    final sub = session.events.listen((event) {
      if (event is AgentQueueChanged && !queueChanged.isCompleted) {
        queueChanged.complete();
      }
      if (event is AgentTurnSnapshot && !snapshotSeen.isCompleted) {
        snapshotSeen.complete();
      }
    });
    addTearDown(sub.cancel);

    backend.emit(
      AgentQueueChanged('c1', [const QueuedPrompt.user('queued')], revision: 3),
    );
    await queueChanged.future.timeout(const Duration(seconds: 3));
    expect(session.queue.single.text, 'queued');
    expect(session.queueRevision, 3);

    backend.emit(
      const AgentTurnSnapshot('c1', text: 'partial', reasoning: 'thinking'),
    );
    await snapshotSeen.future.timeout(const Duration(seconds: 3));
    expect(session.turnSnapshot.text, 'partial');
    expect(session.turnSnapshot.reasoning, 'thinking');
    expect(session.isRunning, isTrue);
  });

  test(
    'queue actions use item ids and repeat once on a stale revision',
    () async {
      await remote.startEvents();
      await remote.eventsReady;
      final session = remote.session('c1');
      final queueChanged = Completer<void>();
      final sub = session.events.listen((event) {
        if (event is AgentQueueChanged && !queueChanged.isCompleted) {
          queueChanged.complete();
        }
      });
      addTearDown(sub.cancel);

      backend.emit(
        AgentQueueChanged('c1', const [
          QueuedPrompt.user('a', id: 'q1'),
          QueuedPrompt.user('b', id: 'q2'),
          QueuedPrompt.user('c', id: 'q3'),
        ], revision: 3),
      );
      await queueChanged.future.timeout(const Duration(seconds: 3));

      // Устаревшая ревизия: клиент перечитывает снимок и повторяет действие
      // по id, поэтому промпт всё равно отправляется сейчас.
      expect(await session.promoteQueued('q3', expectedRevision: 2), isTrue);
      expect(queueSession.promoted, ['q3']);
      // Снимок обновлён сразу, не дожидаясь SSE: следующее действие увидит
      // свежую ревизию и порядок.
      expect(session.queueRevision, 4);
      expect([for (final item in session.queue) item.id], ['q3', 'q1', 'q2']);

      // Исчезнувший элемент: повторять нечего, действие не применяется.
      final promotedBefore = [...queueSession.promoted];
      final revisionBefore = session.queueRevision;
      expect(
        await session.promoteQueued('missing', expectedRevision: 4),
        isFalse,
      );
      expect(queueSession.promoted, promotedBefore);
      expect(session.queueRevision, revisionBefore);

      // Удаление тоже адресуется id и повторяется на свежей ревизии.
      final taken = await session.takeQueued('q1', expectedRevision: 3);
      expect(taken?.text, 'a');
      expect(session.queueRevision, 5);
      expect([for (final item in session.queue) item.id], ['q3', 'q2']);

      // Удалённый ранее элемент не находится в снимке и не трогает остальные.
      final revisionAfterDelete = session.queueRevision;
      expect(await session.takeQueued('q1', expectedRevision: 5), isNull);
      expect(session.queueRevision, revisionAfterDelete);
      expect(session.queue.any((item) => item.id == 'q1'), isFalse);
    },
  );

  test('stops SSE reconnects after an unauthorized response', () async {
    final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    httpServer.listen((request) {
      requests++;
      request.response.statusCode = HttpStatus.unauthorized;
      request.response.close();
    });
    final unauthorized = RemoteAgentApi(
      baseUri: Uri.parse('http://127.0.0.1:${httpServer.port}'),
      token: 'bad',
      reconnectBaseDelay: const Duration(milliseconds: 10),
      reconnectMaxDelay: const Duration(milliseconds: 40),
      reconnectJitter: 0,
    );
    addTearDown(() async {
      await unauthorized.dispose();
      await httpServer.close(force: true);
    });

    await unauthorized.startEvents();
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(requests, 1);
    expect(unauthorized.status, AgentStatus.offline);
  });

  test('grows the SSE reconnect delay between failed attempts', () async {
    final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final attempts = <DateTime>[];
    httpServer.listen((request) {
      attempts.add(DateTime.now());
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.close();
    });
    final retrying = RemoteAgentApi(
      baseUri: Uri.parse('http://127.0.0.1:${httpServer.port}'),
      token: 'token',
      reconnectBaseDelay: const Duration(milliseconds: 30),
      reconnectMaxDelay: const Duration(milliseconds: 120),
      reconnectJitter: 0,
    );
    addTearDown(() async {
      await retrying.dispose();
      await httpServer.close(force: true);
    });

    await retrying.startEvents();
    await Future<void>.delayed(const Duration(milliseconds: 700));

    expect(attempts.length, greaterThanOrEqualTo(3));
    final firstGap = attempts[1].difference(attempts.first).inMilliseconds;
    final secondGap = attempts[2].difference(attempts[1]).inMilliseconds;
    expect(secondGap, greaterThan(firstGap));
  });

  test('lists client sessions and keeps the current one marked', () async {
    final sessions = await remote.refreshClientSessions();

    expect(sessions, hasLength(1));
    expect(sessions.single.current, isTrue);
    expect(sessions.single.id, remote.sessionId);
  });

  test('presence refresh reads the session list back', () async {
    final list = Completer<List<ClientSessionView>>();
    final sub = remote.clientSessions.listen((items) {
      if (!list.isCompleted) list.complete(items);
    });
    addTearDown(sub.cancel);

    remote.setPresence(focused: true);

    final sessions = await list.future.timeout(const Duration(seconds: 2));
    expect(sessions.single.current, isTrue);
    expect(sessions.single.focused, isTrue);
  });

  test(
    'a stale session list response does not overwrite a newer one',
    () async {
      final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var sessionsCalls = 0;
      final firstStarted = Completer<void>();
      final expiresAt = DateTime.now()
          .toUtc()
          .add(const Duration(minutes: 1))
          .toIso8601String();
      Map<String, Object?> sessionJson(String id) => {
        'id': id,
        'deviceId': 'device-$id',
        'clientApp': 'ProbablyWorks',
        'clientVersion': '1.0.0',
        'clientBuild': '1',
        'clientPlatform': 'web',
        'createdAt': expiresAt,
        'lastSeenAt': expiresAt,
        'expiresAt': expiresAt,
        'focused': false,
        'online': true,
        'current': id == 's1',
      };
      httpServer.listen((request) async {
        await request.drain<void>();
        final response = request.response;
        response.headers.contentType = ContentType.json;
        if (request.uri.path == '/api/v1/client/handshake') {
          response.write(
            jsonEncode({
              'sessionId': 's1',
              'instanceId': 'instance-1',
              'deviceId': 'device-1',
              'protocol': 1,
              'expiresAt': expiresAt,
              'heartbeatIntervalMs': 60000,
            }),
          );
        } else if (request.uri.path == '/api/v1/client/sessions') {
          sessionsCalls++;
          final call = sessionsCalls;
          if (call == 1) firstStarted.complete();
          // Первый ответ медленнее: он приходит позже и содержит старый снимок.
          await Future<void>.delayed(
            Duration(milliseconds: call == 1 ? 150 : 10),
          );
          final ids = call == 1 ? ['s1', 's2'] : ['s1', 's2', 's3'];
          response.write(
            jsonEncode({
              'currentSessionId': 's1',
              'sessions': [for (final id in ids) sessionJson(id)],
            }),
          );
        } else {
          response.statusCode = HttpStatus.notFound;
        }
        await response.close();
      });
      addTearDown(() => httpServer.close(force: true));
      final api = RemoteAgentApi(
        baseUri: Uri.parse('http://127.0.0.1:${httpServer.port}'),
        token: _token,
      );
      addTearDown(api.dispose);
      final emitted = <List<ClientSessionView>>[];
      final sub = api.clientSessions.listen(emitted.add);
      addTearDown(sub.cancel);

      final first = api.refreshClientSessions();
      await firstStarted.future;
      final second = api.refreshClientSessions();
      final results = await Future.wait([first, second]);

      // Старый ответ не попал в поток: остался только свежий снимок на три экрана.
      expect(emitted, hasLength(1));
      expect(emitted.single, hasLength(3));
      // И вызывающему тоже не отдан устаревший снимок на два экрана.
      expect(results.first, hasLength(3));
      expect(results.last, hasLength(3));
    },
  );

  test('handshakes and exposes the session and instance ids', () async {
    await remote.chats();

    expect(remote.sessionId, isNotNull);
    expect(remote.instanceId, isNotNull);
  });

  test('reuses the stored session for a new client instance', () async {
    final store = MemoryClientSessionStore();
    final first = RemoteAgentApi(
      baseUri: remote.baseUri,
      token: _token,
      sessionStore: store,
      sessionKey: 'profile-1',
    );
    addTearDown(first.dispose);
    await first.chats();
    final sessionId = first.sessionId;
    expect(sessionId, isNotNull);

    final second = RemoteAgentApi(
      baseUri: remote.baseUri,
      token: _token,
      sessionStore: store,
      sessionKey: 'profile-1',
    );
    addTearDown(second.dispose);
    await second.chats();

    expect(second.sessionId, sessionId);
  });

  test('re-handshakes after the server expires the session', () async {
    final store = MemoryClientSessionStore();
    var now = DateTime.utc(2026, 11, 24, 12);
    final sessions = ClientSessionRegistry(
      ttl: const Duration(seconds: 60),
      sweepInterval: const Duration(hours: 1),
      now: () => now,
    );
    addTearDown(sessions.dispose);
    final expiringServer = ApiServer(
      backend,
      _token,
      port: 0,
      chat: _FakeDraftChatApi(store: _FakeDraftStore()),
      clientSessions: sessions,
    );
    final port = await expiringServer.start();
    addTearDown(expiringServer.stop);
    final expiring = RemoteAgentApi(
      baseUri: Uri.parse('http://127.0.0.1:$port'),
      token: _token,
      sessionStore: store,
      sessionKey: 'profile-expiring',
    );
    addTearDown(expiring.dispose);

    await expiring.chats();
    final firstSession = expiring.sessionId;
    expect(firstSession, isNotNull);

    now = now.add(const Duration(seconds: 61));
    await expiring.chats();

    expect(expiring.sessionId, isNot(firstSession));
  });

  test('retries a request that lost the session before the route', () async {
    final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var handshakes = 0;
    var chats = 0;
    httpServer.listen((request) async {
      await request.drain<void>();
      final response = request.response;
      response.headers.contentType = ContentType.json;
      if (request.uri.path == '/api/v1/client/handshake') {
        handshakes++;
        response.write(
          jsonEncode({
            'sessionId': 's$handshakes',
            'instanceId': 'instance-1',
            'deviceId': 'device-1',
            'protocol': 1,
            'expiresAt': DateTime.now()
                .toUtc()
                .add(const Duration(minutes: 1))
                .toIso8601String(),
            'heartbeatIntervalMs': 60000,
          }),
        );
      } else if (request.uri.path == '/api/v1/chats') {
        chats++;
        final session = request.headers.value('x-client-session');
        if (session == 's1') {
          response
            ..statusCode = HttpStatus.badRequest
            ..write(
              jsonEncode({
                'error': {
                  'code': 'session_required',
                  'message': 'session is required',
                },
                'requestId': 'test',
              }),
            );
        } else {
          response.write(jsonEncode({'chats': []}));
        }
      } else {
        response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
    addTearDown(() => httpServer.close(force: true));

    final remote = RemoteAgentApi(
      baseUri: Uri.parse('http://127.0.0.1:${httpServer.port}'),
      token: _token,
    );
    addTearDown(remote.dispose);

    expect(await remote.chats(), isEmpty);
    expect(handshakes, 2);
    expect(chats, 2);
  });

  test('a recovered instance change notifies subscribers once', () async {
    var healthCalls = 0;
    final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    httpServer.listen((request) async {
      await request.drain<void>();
      final response = request.response;
      response.headers.contentType = ContentType.json;
      switch (request.uri.path) {
        case '/api/v1/client/handshake':
          response.write(
            jsonEncode({
              'sessionId': 's1',
              'instanceId': 'instance-1',
              'deviceId': 'device-1',
              'protocol': 1,
              'expiresAt': DateTime.now()
                  .toUtc()
                  .add(const Duration(minutes: 1))
                  .toIso8601String(),
              'heartbeatIntervalMs': 60000,
            }),
          );
        case '/api/v1/chats':
          response.write(jsonEncode({'chats': <Object>[]}));
        case '/api/v1/health':
          healthCalls++;
          if (healthCalls == 1) {
            response.statusCode = HttpStatus.internalServerError;
          } else {
            response.write(
              jsonEncode({
                'ok': true,
                'version': '1',
                'instanceId': 'instance-2',
              }),
            );
          }
        default:
          response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
    addTearDown(() => httpServer.close(force: true));

    final api = RemoteAgentApi(
      baseUri: Uri.parse('http://127.0.0.1:${httpServer.port}'),
      token: _token,
    );
    addTearDown(api.dispose);
    final reconnects = <void>[];
    final sub = api.reconnects.listen(reconnects.add);
    addTearDown(sub.cancel);

    await api.chats();
    expect(api.instanceId, 'instance-1');

    expect(await api.checkConnection(), isFalse);
    expect(await api.checkConnection(), isTrue);

    // Статус поднялся после offline и instanceId сменился: оба пути должны
    // схлопнуться в одно уведомление.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(reconnects, hasLength(1));
  });

  test('dispose keeps a session stored by another instance', () async {
    final store = MemoryClientSessionStore();
    final releaseDelete = Completer<void>();
    final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    httpServer.listen((request) async {
      await request.drain<void>();
      final response = request.response;
      response.headers.contentType = ContentType.json;
      switch (request.uri.path) {
        case '/api/v1/client/handshake':
          response.write(
            jsonEncode({
              'sessionId': 's1',
              'instanceId': 'instance-1',
              'deviceId': 'device-1',
              'protocol': 1,
              'expiresAt': DateTime.now()
                  .toUtc()
                  .add(const Duration(minutes: 1))
                  .toIso8601String(),
              'heartbeatIntervalMs': 60000,
            }),
          );
        case '/api/v1/chats':
          response.write(jsonEncode({'chats': <Object>[]}));
        case '/api/v1/client/session':
          // Закрытие сессии задерживается: за это время другой экземпляр
          // профиля успевает записать свой id в то же хранилище.
          await releaseDelete.future;
          response.statusCode = HttpStatus.noContent;
        default:
          response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
    addTearDown(() => httpServer.close(force: true));

    final api = RemoteAgentApi(
      baseUri: Uri.parse('http://127.0.0.1:${httpServer.port}'),
      token: _token,
      sessionStore: store,
      sessionKey: 'profile-1',
    );
    await api.chats();
    expect(store.read('profile-1'), 's1');

    final disposal = api.dispose();
    store.write('profile-1', 's2');
    releaseDelete.complete();
    await disposal;

    expect(store.read('profile-1'), 's2');
  });
}

final class _FakeData implements DataApi {
  int? clearedDays;
  var resets = 0;

  @override
  Future<DataUsage> usage() async => const DataUsage(
    chats: 2,
    subagentChats: 1,
    messages: 10,
    toolRuns: 3,
    scheduledTasks: 1,
    completedTasks: 2,
    failedTasks: 0,
    cancelledTasks: 0,
    chatFilesBytes: 1024,
    databaseBytes: 2048,
  );

  @override
  Future<HistoryClearResult> clearHistory({int? olderThanDays}) async {
    clearedDays = olderThanDays;
    return const HistoryClearResult(
      deletedChats: 1,
      freedBytes: 512,
      compacted: false,
    );
  }

  @override
  Future<void> resetSettings() async => resets++;
}

final class _FakeAgent implements AgentApi {
  final _events = StreamController<AgentEvent>.broadcast();
  final _approvals = StreamController<ApprovalRequest>.broadcast();
  final _questions = StreamController<UserQuestion>.broadcast();
  final _editChanges = StreamController<EditFileChangesRequest>.broadcast();

  final sent = <(String, String, bool)>[];
  final decisions = <ApprovalAction>[];
  final answers = <String?>[];
  final searchQueries = <SearchQuery>[];
  String? updatedModel;
  String? savedChatId;
  ReasoningPreference? savedReasoning;
  int pendingTasks = 0;
  bool? copiedPendingTasks;
  String? forkedUntilMessageId;

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
      systemLabel: 'Ubuntu 24.04.1 LTS',
      lastCheckAt: DateTime(2026, 11, 11, 12, 30),
      lastLatencyMs: 12,
    ),
  ];

  @override
  Future<List<Chat>> chats() async => [_chat];

  @override
  Future<List<SearchHit>> search(SearchQuery query) async {
    searchQueries.add(query);
    return const [
      SearchHit(
        kind: SearchHitKind.chat,
        title: 'Test chat',
        chatId: 'c1',
        chatTitle: 'Test chat',
        projectId: 'p1',
        score: 1,
      ),
    ];
  }

  @override
  Future<Chat?> chat(String id) async => id == 'c1' ? _chat : null;

  @override
  Future<Chat> createChat(String hostId) async => _chat.copyWith(id: 'c2');

  @override
  Future<void> saveChat(Chat chat) async {
    savedChatId = chat.id;
    savedReasoning = chat.reasoning;
  }

  @override
  Future<void> renameChat(String chatId, String title) => Future<void>.value();

  @override
  Future<void> updateChat(
    String chatId, {
    String? title,
    String? model,
    ReasoningPreference? reasoning,
    PolicyMode? policyMode,
    String? workspace,
    bool workspaceSpecified = false,
  }) async {
    updatedModel = model;
  }

  @override
  Future<Chat?> forkChat(
    String chatId, {
    String? title,
    String? untilMessageId,
    bool copyPendingTasks = false,
  }) async {
    copiedPendingTasks = copyPendingTasks;
    forkedUntilMessageId = untilMessageId;
    return _chat;
  }

  String? countsUntilMessageId;

  @override
  Future<int> pendingScheduledTasks(
    String chatId, {
    String? untilMessageId,
  }) async {
    countsUntilMessageId = untilMessageId;
    return pendingTasks;
  }

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
    final start = DateTime.utc(2026, 11, 11);
    return [
      ToolRun(
        id: 'r1',
        chatId: chatId,
        messageId: 'm1',
        toolName: 'run_command',
        argsJson: '{"command":"false"}',
        command: 'false',
        status: ToolRunStatus.done,
        resultError: true,
        exitCode: 1,
        startedAt: start,
        finishedAt: start.add(const Duration(seconds: 1)),
      ),
    ];
  }

  @override
  Future<void> openChat(String chatId) => Future<void>.value();

  @override
  Future<void> send(
    String chatId,
    String text, {
    bool sendNow = false,
    List<AttachmentRef> attachments = const [],
    List<MentionRef> mentions = const [],
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

  final editRequests = <EditFileChangesRequest>[];

  @override
  Future<List<EditFileChangesRequest>> pendingEditFileChanges(
    String chatId,
  ) async => editRequests;

  @override
  Future<void> resumeAfterRestart() => Future<void>.value();
}

final class _FakeSecurityAudit implements SecurityAuditApi {
  @override
  Future<SecurityReport> run({
    SecurityRunMode mode = SecurityRunMode.gui,
  }) async => SecurityReport(
    generatedAt: DateTime.utc(2026, 11, 12, 10, 0),
    mode: SecurityRunMode.headless,
    platform: 'test',
    status: SecurityStatus.baseline,
    findings: const [
      SecurityFinding(
        code: SecurityFindingCode.headlessApi,
        severity: SecuritySeverity.info,
      ),
    ],
  );
}

final class _FakePush implements PushApi {
  PushSettings? saved;
  String? token;
  var tested = false;

  @override
  Future<PushSettings> pushSettings() async => saved ?? const PushSettings();

  @override
  Future<void> savePush(
    PushSettings settings, {
    String? token,
    bool clearToken = false,
  }) async {
    saved = settings.copyWith(hasToken: token != null || !clearToken);
    this.token = token;
  }

  @override
  Future<void> testPush() async {
    tested = true;
  }
}

final class _FakePlugins implements PluginApi {
  var busy = false;
  var refreshed = 0;
  Set<String>? lastIds;
  Map<String, Object?>? savedSettings;
  final secrets = <String, String>{};

  @override
  Future<PluginSnapshot> pluginSnapshot() async => const PluginSnapshot(
    plugins: [
      PluginDescriptor(id: 'first', dependsOn: {}, defaultEnabled: false),
      PluginDescriptor(
        id: 'second',
        dependsOn: {'first'},
        defaultEnabled: false,
      ),
    ],
    enabled: {'first'},
  );

  @override
  Future<Set<String>> missingDependencies(String id) async =>
      id == 'second' ? {'first'} : {};

  @override
  Future<Set<String>> dependents(String id) async =>
      id == 'first' ? {'second'} : {};

  @override
  Future<void> setEnabled(Set<String> ids, {required bool enabled}) async {
    if (busy) {
      throw const AgentApiException(
        409,
        'agent_busy',
        'cannot change plugins while the agent is running',
      );
    }
    lastIds = ids;
  }

  @override
  plugins.PluginSettings settingsFor(String id) => _FakePluginSettings(this);

  @override
  Future<void> refresh() async {
    refreshed++;
  }
}

final class _FakePluginSettings implements plugins.PluginSettings {
  _FakePluginSettings(this._api);

  final _FakePlugins _api;

  @override
  Future<Map<String, Object?>> read() async => {'version': 1};

  @override
  Future<void> save(Map<String, Object?> value) async {
    _api.savedSettings = value;
  }

  @override
  Future<bool> hasSecret(String name) async => _api.secrets.containsKey(name);

  @override
  Future<void> writeSecret(String name, String? value) {
    if (value == null) {
      _api.secrets.remove(name);
    } else {
      _api.secrets[name] = value;
    }
    return Future<void>.value();
  }
}

final class _FakeDraftChatApi implements ChatApi {
  _FakeDraftChatApi({required this.store, this.queueSession});

  final _FakeDraftStore store;
  final _FakeQueueSession? queueSession;

  @override
  ChatStore get chatStore => store;

  @override
  ChatSessionApi session(String chatId) =>
      queueSession ??
      (throw UnsupportedError('queue session is not configured in this test'));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('ChatApi is not used in remote tests');
}

/// Очередь с ревизией: проверяет путь клиента через HTTP и восстановление
/// снимка после `409 queue_conflict`.
final class _FakeQueueSession implements ChatSessionApi {
  final items = <QueuedPrompt>[
    const QueuedPrompt.user('a', id: 'q1'),
    const QueuedPrompt.user('b', id: 'q2'),
    const QueuedPrompt.user('c', id: 'q3'),
  ];
  var revision = 3;
  final promoted = <String>[];

  @override
  bool get isRunning => false;

  @override
  TurnSnapshot get turnSnapshot => const TurnSnapshot();

  @override
  List<QueuedPrompt> get queue => List.unmodifiable(items);

  @override
  int get queueRevision => revision;

  @override
  Future<bool> promoteQueued(
    String itemId, {
    required int expectedRevision,
  }) async {
    if (expectedRevision != revision) return false;
    final index = items.indexWhere((item) => item.id == itemId);
    if (index < 0) return false;
    promoted.add(itemId);
    items.insert(0, items.removeAt(index));
    revision++;
    return true;
  }

  @override
  Future<QueuedPrompt?> takeQueued(
    String itemId, {
    required int expectedRevision,
  }) async {
    if (expectedRevision != revision) return null;
    final index = items.indexWhere((item) => item.id == itemId);
    if (index < 0) return null;
    revision++;
    return items.removeAt(index);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('only queue methods are used in queue tests');
}

final class _FakeDraftStore implements ChatStore {
  var revision = 0;
  ChatDraft? draft;
  String? model;
  Map<String, ChatDraft> edits = {};

  @override
  Future<Chat?> chat(String id) async => Chat(
    id: id,
    hostId: 'local',
    title: 'Chat',
    createdAt: DateTime.utc(2026, 11, 11),
    updatedAt: DateTime.utc(2026, 11, 11),
    draft: draft ?? ChatDraft.empty,
    messageEdits: edits,
    draftRevision: revision,
    model: model,
  );

  @override
  Future<List<ChatMessage>> messages(String id) async => const [];

  @override
  Future<List<ToolRun>> toolRunsForChat(String id) async => const [];

  @override
  Future<void> createChat(Chat chat) => Future<void>.value();

  @override
  Future<void> saveChat(Chat chat) => Future<void>.value();

  @override
  Future<Chat> updateChat(
    String chatId, {
    String? title,
    String? model,
    ReasoningPreference? reasoning,
    PolicyMode? policyMode,
    String? workspace,
    bool workspaceSpecified = false,
    int? expectedRevision,
  }) async {
    revision++;
    this.model = model ?? this.model;
    return Chat(
      id: chatId,
      hostId: 'local',
      title: title ?? 'Chat',
      model: model,
      reasoning: reasoning ?? ReasoningPreference.inherit,
      policyMode: policyMode ?? PolicyMode.ask,
      workspace: workspace,
      draft: draft ?? ChatDraft.empty,
      messageEdits: edits,
      draftRevision: revision,
      messageEditsRevision: revision,
      revision: revision,
      createdAt: DateTime.utc(2026, 11, 11),
      updatedAt: DateTime.utc(2026, 11, 11),
    );
  }

  @override
  Stream<String> watchDraftChanges() => const Stream.empty();

  @override
  Future<int> saveDraft(
    String chatId,
    ChatDraft value, {
    int? expectedRevision,
  }) async {
    if (expectedRevision != null && expectedRevision != revision) {
      throw const AgentApiException(409, 'draft_conflict', 'draft changed');
    }
    revision++;
    draft = value;
    return revision;
  }

  @override
  Future<int> saveMessageEdits(
    String chatId,
    Map<String, ChatDraft> value, {
    int? expectedRevision,
  }) async {
    if (expectedRevision != null && expectedRevision != revision) {
      throw const AgentApiException(409, 'draft_conflict', 'draft changed');
    }
    revision++;
    edits = value;
    return revision;
  }
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
  Future<McpSnapshot> mcpSnapshot() async => McpSnapshot(
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

final class _FakeLocalModels implements LocalModelsSource {
  final installs = <String>[];
  final imports = <String>[];
  final deleted = <String>[];
  final changes = StreamController<LocalModelsState>.broadcast();
  LocalModelSettings? settings;
  var autoUnload = 0;
  var cleared = 0;
  LocalModelsState _state = const LocalModelsState();

  @override
  LocalModelsState get state => _state;

  void publish(LocalModelsState state) {
    _state = state;
    changes.add(state);
  }

  @override
  Stream<LocalModelsState> watch() => Stream.multi((controller) {
    controller.add(_state);
    final sub = changes.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = sub.cancel;
  });

  @override
  Future<void> refresh() => Future<void>.value();

  Future<String> install(String source, {String? name, String? sha256}) =>
      startInstall(source, name: name, sha256: sha256);

  @override
  Future<String> startInstall(
    String source, {
    String? name,
    String? sha256,
  }) async {
    installs.add(source);
    publish(
      LocalModelsState(
        models: [
          LocalModelFile(
            id: 'model-1',
            name: name ?? 'Model',
            source: source,
            sourceKind: LocalModelSourceKind.huggingFace,
            cacheKey: 'cache-1',
            settings: const LocalModelSettings(),
            createdAt: DateTime.utc(2026),
          ),
        ],
      ),
    );
    return 'model-1';
  }

  @override
  Future<void> cancelInstall(String id) => Future<void>.value();

  @override
  Future<String> importPath(String path, {String? name}) async {
    imports.add(path);
    return 'model-2';
  }

  @override
  Future<void> delete(String id) async {
    deleted.add(id);
    _state = const LocalModelsState();
  }

  @override
  Future<void> updateSettings(String id, LocalModelSettings value) async {
    settings = value;
  }

  @override
  Future<void> clearCache() async => cleared++;

  @override
  Future<void> saveAutoUnload(int minutes) async => autoUnload = minutes;
}

final class _FakeSettings implements AgentSettingsApi {
  final written = <String, String?>{};
  var pinned = <String>['openai/gpt-4o'];
  var denylist = <String>[];
  var securityProfile = const SecurityProfile();
  var steps = const StepsDisplay();
  var limits = const AppLimits();
  var defaultPolicy = 'ask';
  var refreshed = 0;
  var remembered = <String>[];
  var llamaCppChecked = 0;

  @override
  ModelRuntimeSource get modelRuntime => _FakeRuntime();

  final localModelsApi = _FakeLocalModels();

  @override
  LocalModelsSource get localModels => localModelsApi;

  final statuses = <String, LlmProviderStatus>{
    openRouterProviderId: const LlmProviderStatus(
      id: openRouterProviderId,
      available: true,
    ),
    llamaCppProviderId: LlmProviderStatus(
      id: llamaCppProviderId,
      baseUrl: llamaCppDefaultBaseUrl,
      available: true,
      modelCount: 1,
      checkedAt: DateTime.utc(2026, 11, 14),
    ),
  };

  AgentSettingsSnapshot get _snapshot => AgentSettingsSnapshot(
    defaultModel: 'openai/gpt-4o',
    titleModel: '',
    memoryModel: '',
    subagentModel: '',
    fallbackModel: '',
    defaultReasoning: ReasoningPreference.high,
    memoryReasoning: ReasoningPreference.auto,
    subagentReasoning: ReasoningPreference.auto,
    fallbackReasoning: ReasoningPreference.auto,
    defaultPolicy: defaultPolicy,
    denylist: denylist,
    securityProfile: const SecurityProfile(),
    limits: limits,
    pinnedModels: pinned,
    stepsDisplay: steps,
    catalog: ModelCatalogState(
      models: [
        LlmModelInfo(id: 'openai/gpt-4o', name: 'GPT-4o', supportsTools: true),
      ],
      syncedAt: DateTime.utc(2026, 11, 11),
      providers: const [openRouterDescriptor, llamaCppDescriptor],
      providerStatuses: Map.of(statuses),
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
  Future<void> refreshModels() async {
    refreshed++;
  }

  @override
  Future<void> rememberModels(List<String> ids) async {
    remembered = ids;
  }

  @override
  Future<List<LlmProviderStatus>> providerStatuses() async =>
      statuses.values.toList();

  @override
  Future<LlmProviderStatus> checkProvider(String providerId) async {
    if (providerId == llamaCppProviderId) llamaCppChecked++;
    final current = statuses[providerId]!;
    final next = current.copyWith(checkedAt: DateTime.utc(2026, 11, 14));
    statuses[providerId] = next;
    return next;
  }

  @override
  Future<void> saveProviderBaseUrl(String providerId, String? baseUrl) async {
    statuses[providerId] = statuses[providerId]!.copyWith(baseUrl: baseUrl);
  }

  @override
  Future<LlmProviderStatus> saveProviderApiKey(
    String providerId,
    String key,
  ) async {
    final current = statuses[providerId]!;
    final next = current.copyWith(
      apiKeySet: true,
      apiKeyTail: charSuffix(key, 3),
      available: true,
      clearError: true,
      keyInfo: providerId == openRouterProviderId
          ? const LlmKeyInfo(
              label: 'sk-or-v1-...abc',
              usage: 1,
              limit: 10,
              limitRemaining: 9,
            )
          : null,
    );
    statuses[providerId] = next;
    return next;
  }

  @override
  Future<void> deleteProviderApiKey(String providerId) async {
    statuses[providerId] = statuses[providerId]!.copyWith(
      apiKeySet: false,
      apiKeyTail: '',
      clearKeyInfo: true,
    );
  }

  @override
  Future<void> setProviderEnabled(String providerId, bool enabled) async {
    statuses[providerId] = statuses[providerId]!.copyWith(enabled: enabled);
  }
}

final class _FakeRuntime implements ModelRuntimeSource {
  @override
  ModelRuntimeState get runtime => const ModelRuntimeState();

  @override
  Stream<ModelRuntimeState> watchRuntime() =>
      Stream.value(const ModelRuntimeState());

  @override
  Future<void> refreshRuntime() => Future<void>.value();

  @override
  Future<void> loadModel(String modelId) => Future<void>.value();

  @override
  Future<void> unloadModel(String modelId) => Future<void>.value();
}

final class _FakeProjects implements ProjectsApi {
  ProjectMemory? memory;
  String? instruction;

  @override
  Stream<ProjectMemory?> watchMemory(String projectId) => Stream.value(memory);

  @override
  Future<void> reviseMemory(String projectId, String instruction) async {
    this.instruction = instruction;
    memory = ProjectMemory(
      projectId: projectId,
      summary: '## Build\n- pnpm',
      updatedAt: DateTime.utc(2026, 11, 13),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('ProjectsApi is not used in this test');
}

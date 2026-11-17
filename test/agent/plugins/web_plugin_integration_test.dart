import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_api/plugin_api.dart';
import 'package:plugin_web_core/plugin_web_core.dart';
import 'package:probably_works/test_support/pipe_pty_launcher.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/exec/active_exec_registry.dart';
import 'package:pw_agent/agent/exec/command_executor.dart';
import 'package:pw_agent/agent/exec/exec_log_store.dart';
import 'package:pw_agent/agent/exec/live_output_bus.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/plugins/plugin_tool_source.dart';
import 'package:pw_agent/agent/policy/command_classifier.dart';
import 'package:pw_agent/agent/policy/policy_engine.dart';
import 'package:pw_agent/agent/state/session_state_service.dart';
import 'package:pw_agent/agent/tools/self_tool_handler.dart';
import 'package:pw_agent/agent/tools/tool_executor.dart';
import 'package:pw_agent/agent/turn/turn_changeset_service.dart';
import 'package:pw_agent/agent/turn/turn_changeset_store.dart';
import 'package:pw_agent/agent/workspace/workspace_context_loader.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/core/data/chat_repository.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/data/project_repository.dart';
import 'package:pw_agent/core/data/saved_model_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/data/virtual_host_provisioner.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/host/host_diagnostics.dart';
import 'package:pw_agent/host/host_runtime_factory.dart';
import 'package:pw_agent/host/ssh_connection_pool.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';

import '../../test_support/fake_appearance.dart';

/// Настройки веб-плагина без сохранённого поискового ключа.
final class _Settings implements PluginSettings {
  Map<String, Object?>? saved;
  final secrets = <String, String>{};

  @override
  Future<Map<String, Object?>> read() async => const {};

  @override
  Future<void> save(Map<String, Object?> value) async {
    saved = value;
  }

  @override
  Future<bool> hasSecret(String name) async => secrets.containsKey(name);

  @override
  Future<void> writeSecret(String name, String? value) async {
    if (value == null) {
      secrets.remove(name);
    } else {
      secrets[name] = value;
    }
  }
}

final class _NoNetworkLlm extends LlmProviderBase {
  _NoNetworkLlm()
    : super(const LlmProviderDescriptor(id: 'test', label: 'Test'));

  @override
  Stream<LlmEvent> stream(LlmRequest request) =>
      throw UnsupportedError('no network in tests');

  @override
  Future<List<LlmModelInfo>> listModels() async => const [];
}

/// Проверяет путь веб-плагина через общий ToolExecutor, policy и карточку
/// подтверждения. Сеть не нужна: страница уже лежит в WebPageStore.
void main() {
  late AppDatabase db;
  late Directory tmp;
  late ChatRepository chats;
  late InteractionBroker broker;
  late ToolExecutor executor;
  late ToolContext context;
  late List<ToolRun> backgroundRuns;

  const chatId = 'c1';
  const turnId = 'u1';
  const assistantId = 'a1';

  setUp(() async {
    db = openInMemoryDatabase();
    tmp = Directory.systemTemp.createTempSync('pw_web_plugin');
    backgroundRuns = [];
    chats = ChatRepository(db);
    final secrets = MemorySecretStore();
    final hosts = HostRepository(db, secrets);
    final settings = SettingsRepository(db);
    await settings.preload();
    await hosts.ensureLocalHost(DateTime.now());
    final local = (await hosts.byId(HostRepository.localHostId))!;
    final runtimes = HostRuntimeFactory(
      SshConnectionPool(hosts, secrets, settings, HostKeyConfirmations()),
      const PipePtyLauncher(),
      VirtualHostProvisioner(db),
    );
    broker = InteractionBroker();
    final self = SelfToolHandler(
      hosts,
      settings,
      FakeAppearance(),
      ModelCatalogService(SavedModelRepository(db), _NoNetworkLlm()),
      HostDiagnostics(hosts, secrets, settings, runtimes),
    );
    final commands = CommandExecutor(
      ExecLogStore(tmp),
      ActiveExecRegistry(),
      LiveOutputBus(),
    );
    executor = ToolExecutor(
      chats,
      commands,
      broker,
      SessionStateService(chats),
      WorkspaceContextLoader(settings),
      self,
      ProjectRepository(db),
      TurnChangesetService(TurnChangesetStore(tmp)),
    );

    final now = DateTime.now();
    await chats.saveChat(
      Chat(
        id: chatId,
        hostId: HostRepository.localHostId,
        title: 't',
        createdAt: now,
        updatedAt: now,
        policyMode: PolicyMode.ask,
      ),
    );
    await chats.insertMessage(
      ChatMessage(
        id: turnId,
        chatId: chatId,
        seq: 1,
        role: MessageRole.user,
        createdAt: now,
        text: 'go',
      ),
    );
    await chats.insertMessage(
      ChatMessage(
        id: assistantId,
        chatId: chatId,
        seq: 2,
        role: MessageRole.assistant,
        createdAt: now,
      ),
    );
    final policy = PolicyEngine(
      classifier: CommandClassifier(
        denylist: SettingsRepository.defaultDenylist,
      ),
      mode: PolicyMode.ask,
    );
    context = ToolContext(
      chat: (await chats.chat(chatId))!,
      messageId: assistantId,
      turnUserMessageId: turnId,
      host: local,
      runtime: runtimes.forHost(local),
      limits: AppLimits.defaults,
      policy: policy,
      onBackgroundDone: (run, _) => backgroundRuns.add(run),
    );
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  test('web plugin tool goes through policy and executor', () async {
    final pages = WebPageStore();
    final snapshot = pages.put(
      chatId: chatId,
      document: const PageDocument(
        requestedUrl: 'https://example.com/page',
        finalUrl: 'https://example.com/page',
        title: 'Example',
        text: 'Hello from the page',
        cleanedHtml: '<html><body><p>Hello from the page</p></body></html>',
        outline: [],
      ),
      mode: 'article',
    );
    final plugin = WebPlugin(pages: pages);
    final tools = await plugin.createTools(_Settings());
    final source = PluginToolSource(
      plugin: plugin,
      tools: tools,
      commands: CommandExecutor(
        ExecLogStore(tmp),
        ActiveExecRegistry(),
        LiveOutputBus(),
      ),
      secrets: MemorySecretStore(),
    );
    executor.registerToolSource(source);
    addTearDown(() => executor.unregisterToolSource(source.id));

    final call = LlmToolCall(
      id: 'w1',
      name: 'plugin_web_read',
      arguments: jsonEncode({
        'page_id': snapshot.id,
        'mode': 'chunk',
        'limit': 100,
      }),
    );
    final pending = executor.execute(call, context);

    final approval = await broker.approvalRequests.first;
    expect(approval.toolName, 'plugin_web_read');
    broker.resolveApproval(approval.id, const ApprovalDecision.allowOnce());

    final result = await pending;
    expect(result.isError, isFalse);
    expect(result.text, contains('Hello from the page'));
    expect(backgroundRuns, isEmpty);
  });
}

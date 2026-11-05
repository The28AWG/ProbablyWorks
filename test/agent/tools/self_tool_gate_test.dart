import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/exec/active_exec_registry.dart';
import 'package:probably_works/agent/exec/command_executor.dart';
import 'package:probably_works/agent/exec/exec_log_store.dart';
import 'package:probably_works/agent/exec/live_output_bus.dart';
import 'package:probably_works/agent/interaction/interaction_broker.dart';
import 'package:probably_works/agent/policy/command_classifier.dart';
import 'package:probably_works/agent/policy/policy_engine.dart';
import 'package:probably_works/agent/skills/builtin_skills.dart';
import 'package:probably_works/agent/state/session_state_service.dart';
import 'package:probably_works/agent/tools/self_tool_handler.dart';
import 'package:probably_works/agent/tools/tool_catalog.dart';
import 'package:probably_works/agent/tools/tool_executor.dart';
import 'package:probably_works/agent/workspace/workspace_context_loader.dart';
import 'package:probably_works/app/locale/locale_controller.dart';
import 'package:probably_works/app/theme/theme_controller.dart';
import 'package:probably_works/core/config/app_limits.dart';
import 'package:probably_works/core/data/chat_repository.dart';
import 'package:probably_works/core/data/host_repository.dart';
import 'package:probably_works/core/data/saved_model_repository.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/data/virtual_host_provisioner.dart';
import 'package:probably_works/core/db/app_database.dart';
import 'package:probably_works/core/db/db_connection.dart';
import 'package:probably_works/core/security/secret_store.dart';
import 'package:probably_works/host/host_diagnostics.dart';
import 'package:probably_works/host/host_runtime_factory.dart';
import 'package:probably_works/host/ssh_connection_pool.dart';
import 'package:probably_works/providers/ai/llm_port.dart';
import 'package:probably_works/providers/ai/model_catalog.dart';
import 'package:probably_works/test_support/pipe_pty_launcher.dart';

class _NoNetworkLlm implements LlmProvider {
  @override
  Stream<LlmEvent> stream(LlmRequest request) =>
      throw UnsupportedError('no network in tests');

  @override
  Future<List<LlmModelInfo>> listModels() async => const [];

  @override
  Future<LlmKeyInfo> checkKey() =>
      Future.value(const LlmKeyInfo(label: 'test', usage: 0));
}

void main() {
  late AppDatabase db;
  late Directory tmp;
  late ChatRepository chats;
  late HostRepository hosts;
  late InteractionBroker broker;
  late ToolExecutor tools;
  late ToolContext ctx;
  final backgroundDone = <ToolRun>[];

  const chatId = 'c1';
  const assistantId = 'a1';

  setUp(() async {
    db = openInMemoryDatabase();
    tmp = Directory.systemTemp.createTempSync('pw_gate');
    chats = ChatRepository(db);
    final secrets = MemorySecretStore();
    hosts = HostRepository(db, secrets);
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
      LocaleController(),
      ThemeController(),
      ModelCatalogService(SavedModelRepository(db), _NoNetworkLlm()),
      HostDiagnostics(hosts, secrets, settings, runtimes),
    );
    tools = ToolExecutor(
      chats,
      CommandExecutor(ExecLogStore(tmp), ActiveExecRegistry(), LiveOutputBus()),
      broker,
      SessionStateService(chats),
      WorkspaceContextLoader(settings),
      self,
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
        id: assistantId,
        chatId: chatId,
        seq: 1,
        role: MessageRole.assistant,
        createdAt: now,
      ),
    );
    ctx = ToolContext(
      chat: (await chats.chat(chatId))!,
      messageId: assistantId,
      host: local,
      runtime: runtimes.forHost(local),
      limits: AppLimits.defaults,
      policy: PolicyEngine(
        classifier: CommandClassifier(
          denylist: SettingsRepository.defaultDenylist,
        ),
        mode: PolicyMode.ask,
      ),
      onBackgroundDone: (run, _) => backgroundDone.add(run),
    );
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  LlmToolCall call(String id, String name, Map<String, Object?> args) =>
      LlmToolCall(id: id, name: name, arguments: jsonEncode(args));

  Future<void> namedByUser(String text) => chats.insertMessage(
    ChatMessage(
      id: 'u1',
      chatId: chatId,
      seq: 2,
      role: MessageRole.user,
      createdAt: DateTime.now(),
      text: text,
    ),
  );

  test('self read tool works without loading any skill', () async {
    final result = await tools.execute(call('x', ToolNames.hostList, {}), ctx);
    expect(result.isError, isFalse);
    expect(result.text, contains(HostRepository.localHostId));
  });

  test('load_skill returns the builtin body as plain text', () async {
    final result = await tools.execute(
      call('x', ToolNames.loadSkill, {
        'name': BuiltinSkills.probablyWorks.name,
      }),
      ctx,
    );
    expect(result.isError, isFalse);
    expect(result.text, BuiltinSkills.probablyWorks.body);
  });

  test(
    'host_add with a key path the user named runs without approval',
    () async {
      await namedByUser('add host prod at 10.0.0.5 with key ~/.ssh/id_ed25519');
      var asked = false;
      broker.approvalRequests.listen((_) => asked = true);

      final result = await tools.execute(
        call('x', ToolNames.hostAdd, {
          'name': 'prod',
          'address': '10.0.0.5',
          'keyPath': '~/.ssh/id_ed25519',
        }),
        ctx,
      );

      expect(asked, isFalse);
      expect(result.isError, isFalse);
      expect(result.text, startsWith('host added'));
    },
  );

  test('host_add with a key path the agent found asks in every mode', () async {
    final request = broker.approvalRequests.first;
    final pending = tools.execute(
      call('x', ToolNames.hostAdd, {
        'name': 'prod',
        'address': '10.0.0.5',
        'keyPath': '/home/me/.ssh/id_rsa',
      }),
      ctx,
    );

    final approval = await request;
    expect(approval.reason, contains('found by the agent'));
    expect(approval.summary, contains('/home/me/.ssh/id_rsa'));
    broker.resolveApproval(approval.id, allow: false);

    final result = await pending;
    expect(result.isError, isTrue);
    expect(await hosts.all(), hasLength(1), reason: 'no host was added');
  });

  test('host_add in Ask mode without a key path asks for approval', () async {
    final request = broker.approvalRequests.first;
    final pending = tools.execute(
      call('x', ToolNames.hostAdd, {'name': 'prod', 'address': '10.0.0.5'}),
      ctx,
    );

    final approval = await request;
    broker.resolveApproval(approval.id, allow: true);
    final result = await pending;
    expect(result.isError, isFalse);
    expect(await hosts.all(), hasLength(2));
  });
}

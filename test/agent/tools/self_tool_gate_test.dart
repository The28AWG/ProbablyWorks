import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/test_support/pipe_pty_launcher.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/exec/active_exec_registry.dart';
import 'package:pw_agent/agent/exec/command_executor.dart';
import 'package:pw_agent/agent/exec/exec_log_store.dart';
import 'package:pw_agent/agent/exec/live_output_bus.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/policy/command_classifier.dart';
import 'package:pw_agent/agent/policy/policy_engine.dart';
import 'package:pw_agent/agent/skills/builtin_skills.dart';
import 'package:pw_agent/agent/state/session_state_service.dart';
import 'package:pw_agent/agent/tools/self_tool_handler.dart';
import 'package:pw_agent/agent/tools/tool_catalog.dart';
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
      FakeAppearance(),
      ModelCatalogService(SavedModelRepository(db), _NoNetworkLlm()),
      HostDiagnostics(hosts, secrets, settings, runtimes),
    );
    final turnChangesets = TurnChangesetService(TurnChangesetStore(tmp));
    tools = ToolExecutor(
      chats,
      CommandExecutor(ExecLogStore(tmp), ActiveExecRegistry(), LiveOutputBus()),
      broker,
      SessionStateService(chats),
      WorkspaceContextLoader(settings),
      self,
      ProjectRepository(db),
      turnChangesets,
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
    broker.resolveApproval(approval.id, const ApprovalDecision.deny());

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
    broker.resolveApproval(approval.id, const ApprovalDecision.allowOnce());
    final result = await pending;
    expect(result.isError, isFalse);
    expect(await hosts.all(), hasLength(2));
  });

  ToolContext contextWithMode(PolicyMode mode) => ToolContext(
    chat: ctx.chat,
    messageId: ctx.messageId,
    host: ctx.host,
    runtime: ctx.runtime,
    limits: ctx.limits,
    policy: PolicyEngine(
      classifier: CommandClassifier(
        denylist: SettingsRepository.defaultDenylist,
      ),
      mode: mode,
    ),
    onBackgroundDone: ctx.onBackgroundDone,
    project: ctx.project,
    turnUserMessageId: ctx.turnUserMessageId,
  );

  test('reading outside the workspace asks for approval', () async {
    final request = broker.approvalRequests.first;
    final pending = tools.execute(
      call('r', ToolNames.readFile, {'path': '/etc/os-release'}),
      ctx,
    );

    final approval = await request;
    expect(approval.reason, contains('outside the project workspace'));
    broker.resolveApproval(approval.id, const ApprovalDecision.deny());

    final result = await pending;
    expect(result.isError, isTrue);
  });

  test('sensitive path asks even in YOLO and has no stored grant', () async {
    final request = broker.approvalRequests.first;
    final pending = tools.execute(
      call('s', ToolNames.readFile, {'path': '~/.ssh/id_rsa'}),
      contextWithMode(PolicyMode.yolo),
    );

    final approval = await request;
    expect(approval.reason, contains('sensitive path'));
    expect(approval.grantable, isFalse);
    broker.resolveApproval(approval.id, const ApprovalDecision.deny());

    final result = await pending;
    expect(result.isError, isTrue);
  });
}

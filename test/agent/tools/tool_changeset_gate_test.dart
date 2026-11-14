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
import 'package:pw_agent/agent/state/session_state_service.dart';
import 'package:pw_agent/agent/tools/self_tool_handler.dart';
import 'package:pw_agent/agent/tools/tool_catalog.dart';
import 'package:pw_agent/agent/tools/tool_executor.dart';
import 'package:pw_agent/agent/tools/tool_source.dart';
import 'package:pw_agent/agent/turn/turn_changeset.dart';
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

final class _FakeToolSource extends ToolSource {
  _FakeToolSource({this.mutatesHost = true});

  int calls = 0;

  @override
  final bool mutatesHost;

  @override
  String get id => 'fake';

  @override
  List<LlmToolSpec> get specs => const [
    LlmToolSpec(
      name: 'fake_tool',
      description: 'fake',
      parameters: {'type': 'object'},
    ),
  ];

  @override
  Future<ToolResult> call(
    LlmToolCall call,
    Map<String, dynamic> arguments,
    ToolContext context,
  ) async {
    calls++;
    return const ToolResult('fake ok');
  }

  @override
  String summaryFor(LlmToolCall call, Map<String, dynamic> arguments) =>
      'fake summary';

  @override
  String reasonFor(LlmToolCall call) => 'fake reason';
}

final class _DenyPolicy extends PolicyEngine {
  _DenyPolicy()
    : super(
        classifier: CommandClassifier(
          denylist: SettingsRepository.defaultDenylist,
        ),
        mode: PolicyMode.ask,
      );

  @override
  PolicyDecision decide(String toolName, Map<String, dynamic> args) =>
      PolicyDecision.deny;
}

class _NoNetworkLlm extends LlmProviderBase {
  _NoNetworkLlm()
    : super(const LlmProviderDescriptor(id: 'test', label: 'Test'));

  @override
  Stream<LlmEvent> stream(LlmRequest request) =>
      throw UnsupportedError('no network in tests');

  @override
  Future<List<LlmModelInfo>> listModels() async => const [];
}

void main() {
  late AppDatabase db;
  late Directory tmp;
  late ChatRepository chats;
  late InteractionBroker broker;
  late ToolExecutor tools;
  late TurnChangesetService turnChangesets;
  late ToolContext ctx;

  const chatId = 'c1';
  const turnId = 'u1';
  const assistantId = 'a1';

  setUp(() async {
    db = openInMemoryDatabase();
    tmp = Directory.systemTemp.createTempSync('pw_changeset_gate');
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
    turnChangesets = TurnChangesetService(TurnChangesetStore(tmp));
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
    ctx = ToolContext(
      chat: (await chats.chat(chatId))!,
      messageId: assistantId,
      turnUserMessageId: turnId,
      host: local,
      runtime: runtimes.forHost(local),
      limits: AppLimits.defaults,
      policy: PolicyEngine(
        classifier: CommandClassifier(
          denylist: SettingsRepository.defaultDenylist,
        ),
        mode: PolicyMode.ask,
      ),
      onBackgroundDone: (_, outcome) {
        // Фоновые команды в этом наборе не проверяются.
        expect(outcome, isNotNull);
      },
    );
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  LlmToolCall call(String id, String name, Map<String, Object?> args) =>
      LlmToolCall(id: id, name: name, arguments: jsonEncode(args));

  Future<TurnChangeset?> turnCs() => turnChangesets.get(chatId, turnId);

  ToolContext contextWith(PolicyEngine policy) => ToolContext(
    chat: ctx.chat,
    messageId: ctx.messageId,
    turnUserMessageId: ctx.turnUserMessageId,
    host: ctx.host,
    runtime: ctx.runtime,
    limits: ctx.limits,
    policy: policy,
    project: ctx.project,
    onBackgroundDone: ctx.onBackgroundDone,
  );

  test('rejected write_file leaves changeset empty', () async {
    final path = '${tmp.path}/rejected.txt';
    final pending = tools.execute(
      call('w', ToolNames.writeFile, {'path': path, 'content': 'nope'}),
      ctx,
    );
    final approval = await broker.approvalRequests.first;
    broker.resolveApproval(approval.id, const ApprovalDecision.deny());
    final result = await pending;
    expect(result.isError, isTrue);
    expect(await turnCs(), isNull);
    expect(File(path).existsSync(), isFalse);
  });

  test('failed create when file appeared leaves changeset empty', () async {
    final path = '${tmp.path}/appeared.txt';

    final pending = tools.execute(
      call('w', ToolNames.writeFile, {'path': path, 'content': 'new'}),
      ctx,
    );
    final approval = await broker.approvalRequests.first;
    File(path).writeAsStringSync('surprise');
    broker.resolveApproval(approval.id, const ApprovalDecision.allowOnce());
    final result = await pending;
    expect(result.isError, isTrue);
    expect(await turnCs(), isNull);
    expect(File(path).readAsStringSync(), 'surprise');
  });

  test('external tool waits for approval and blocks rollback', () async {
    final source = _FakeToolSource();
    tools.registerToolSource(source);
    addTearDown(() => tools.unregisterToolSource(source.id));

    final pending = tools.execute(call('e', 'fake_tool', const {}), ctx);
    final approval = await broker.approvalRequests.first;
    expect(source.calls, 0);
    expect(approval.toolName, 'fake_tool');
    expect(approval.summary, 'fake summary');
    expect(approval.reason, 'fake reason');

    broker.resolveApproval(approval.id, const ApprovalDecision.allowOnce());
    final result = await pending;

    expect(result.text, 'fake ok');
    expect(source.calls, 1);
    expect((await turnCs())?.nonRecoverable, isTrue);
  });

  test('external tool denied by policy never reaches the source', () async {
    final source = _FakeToolSource();
    tools.registerToolSource(source);
    addTearDown(() => tools.unregisterToolSource(source.id));

    final result = await tools.execute(
      call('e', 'fake_tool', const {}),
      contextWith(_DenyPolicy()),
    );

    expect(result.isError, isTrue);
    expect(source.calls, 0);
  });

  test('read-only external tool does not block rollback', () async {
    final source = _FakeToolSource(mutatesHost: false);
    tools.registerToolSource(source);
    addTearDown(() => tools.unregisterToolSource(source.id));

    final pending = tools.execute(call('e', 'fake_tool', const {}), ctx);
    final approval = await broker.approvalRequests.first;
    broker.resolveApproval(approval.id, const ApprovalDecision.allowOnce());
    await pending;

    expect(await turnCs(), isNull);
  });
}

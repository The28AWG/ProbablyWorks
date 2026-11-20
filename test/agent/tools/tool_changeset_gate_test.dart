import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_api/plugin_api.dart';
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
import 'package:pw_agent/core/util/redactor.dart';
import 'package:pw_agent/host/host_diagnostics.dart';
import 'package:pw_agent/host/host_runtime_factory.dart';
import 'package:pw_agent/host/ssh_connection_pool.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';

import '../../test_support/fake_appearance.dart';

final class _FakeToolSource extends ToolSource {
  _FakeToolSource({this.mutatesHost = true, this.resultText = 'fake ok'});

  int calls = 0;

  @override
  final bool mutatesHost;
  final String resultText;

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
    return ToolResult(resultText);
  }

  @override
  String summaryFor(LlmToolCall call, Map<String, dynamic> arguments) =>
      'fake summary';

  @override
  String reasonFor(LlmToolCall call) => 'fake reason';
}

/// Плагин, который читает и пишет файлы только через [PluginHost].
final class _FilePlugin implements Plugin {
  const _FilePlugin();

  @override
  String get id => 'files';

  @override
  Set<String> get dependsOn => const {};

  @override
  bool get defaultEnabled => true;

  @override
  Future<List<PluginTool>> createTools(PluginSettings settings) async => [
    PluginTool(
      name: 'read',
      title: 'Read file',
      description: 'Reads a whole file through the host',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
        },
        'required': ['path'],
      },
      run: (args, host) async {
        final result = await host.readAll(args['path'] as String);
        return PluginToolResult(result.text, isError: result.isError);
      },
    ),
    PluginTool(
      name: 'read_loop',
      title: 'Read file in chunks',
      description: 'Reads a file chunk by chunk through the host',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
        },
        'required': ['path'],
      },
      run: (args, host) async {
        final reader = await host.readFile(args['path'] as String);
        while (!reader.done) {
          await reader.next();
        }
        return PluginToolResult(reader.text, isError: reader.isError);
      },
    ),
    PluginTool(
      name: 'write',
      title: 'Write file',
      description: 'Proposes a file write through the host',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'content': {'type': 'string'},
        },
        'required': ['path', 'content'],
      },
      run: (args, host) async {
        final result = await host.writeFile(
          args['path'] as String,
          args['content'] as String,
        );
        return PluginToolResult(result.text, isError: result.isError);
      },
    ),
  ];
}

final class _NoopSettings implements PluginSettings {
  const _NoopSettings();

  @override
  Future<Map<String, Object?>> read() async => const {};

  @override
  Future<void> save(Map<String, Object?> value) => Future<void>.value();

  @override
  Future<bool> hasSecret(String name) async => false;

  @override
  Future<void> writeSecret(String name, String? value) => Future<void>.value();
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
        workspace: tmp.path,
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

  test('external tool output is redacted before it is saved', () async {
    const secret = 'q7Yp2Lm9RandomToken';
    Redactor.registerSecret(secret);
    addTearDown(Redactor.clearRegisteredSecrets);

    final source = _FakeToolSource(resultText: 'result: $secret');
    tools.registerToolSource(source);
    addTearDown(() => tools.unregisterToolSource(source.id));

    final pending = tools.execute(
      call('e', 'fake_tool', {'value': secret}),
      ctx,
    );
    final approval = await broker.approvalRequests.first;
    broker.resolveApproval(approval.id, const ApprovalDecision.allowOnce());
    await pending;

    final run = (await chats.toolRunsForChat(chatId)).single;
    expect(run.argsJson, isNot(contains(secret)));
    expect(run.outputText, isNot(contains(secret)));
    expect(run.resultPreview, isNot(contains(secret)));
  });

  Future<PluginToolSource> fileSource() async => PluginToolSource(
    plugin: const _FilePlugin(),
    tools: await const _FilePlugin().createTools(const _NoopSettings()),
    commands: CommandExecutor(
      ExecLogStore(tmp),
      ActiveExecRegistry(),
      LiveOutputBus(),
    ),
    files: tools,
    secrets: MemorySecretStore(),
  );

  /// Выполняет инструмент плагина, подтверждая внешний вызов.
  Future<ToolResult> runPlugin(
    String id,
    String name,
    Map<String, Object?> args,
  ) async {
    final pending = tools.execute(call(id, name, args), ctx);
    final approval = await broker.approvalRequests.first;
    broker.resolveApproval(approval.id, const ApprovalDecision.allowOnce());
    return pending;
  }

  test('plugin read returns the whole file exactly', () async {
    const content = 'строка 1\nстрока 2\r\nбез перевода в конце ✓';
    File('${tmp.path}/note.txt').writeAsStringSync(content);
    final source = await fileSource();
    tools.registerToolSource(source);
    addTearDown(() => tools.unregisterToolSource(source.id));

    final result = await runPlugin('p1', 'plugin_files_read', {
      'path': 'note.txt',
    });

    expect(result.isError, isFalse);
    expect(result.text, content);
  });

  test('plugin cursor reads a large file in chunks exactly', () async {
    final content =
        '${List.generate(1000, (i) => 'line ${i.toString().padLeft(4, '0')}').join('\n')}\n';
    File('${tmp.path}/large.txt').writeAsStringSync(content);
    final source = await fileSource();
    tools.registerToolSource(source);
    addTearDown(() => tools.unregisterToolSource(source.id));

    final result = await runPlugin('p2', 'plugin_files_read_loop', {
      'path': 'large.txt',
    });

    expect(result.isError, isFalse);
    expect(result.text, content);
  });

  test('plugin write then read round-trips content exactly', () async {
    const content = 'первая строка\r\nвторая\nбез перевода в конце';
    final source = await fileSource();
    tools.registerToolSource(source);
    addTearDown(() => tools.unregisterToolSource(source.id));

    final writePending = tools.execute(
      call('w1', 'plugin_files_write', {
        'path': 'round-trip.txt',
        'content': content,
      }),
      ctx,
    );
    final writeOuter = await broker.approvalRequests.first;
    broker.resolveApproval(writeOuter.id, const ApprovalDecision.allowOnce());
    final writeInner = await broker.approvalRequests.first;
    broker.resolveApproval(writeInner.id, const ApprovalDecision.allowOnce());
    expect((await writePending).isError, isFalse);

    final result = await runPlugin('r1', 'plugin_files_read', {
      'path': 'round-trip.txt',
    });

    expect(result.isError, isFalse);
    expect(result.text, content);
  });

  test('plugin write applies after approval and records the file', () async {
    final path = '${tmp.path}/plugin-out.txt';
    final source = await fileSource();
    tools.registerToolSource(source);
    addTearDown(() => tools.unregisterToolSource(source.id));

    final pending = tools.execute(
      call('p3', 'plugin_files_write', {
        'path': 'plugin-out.txt',
        'content': 'from plugin',
      }),
      ctx,
    );
    final outer = await broker.approvalRequests.first;
    expect(outer.toolName, 'plugin_files_write');
    broker.resolveApproval(outer.id, const ApprovalDecision.allowOnce());
    // Запись — отдельное действие: приложение спрашивает на неё второй раз.
    final inner = await broker.approvalRequests.first;
    expect(inner.toolName, ToolNames.writeFile);
    expect(inner.diff, contains('from plugin'));
    broker.resolveApproval(inner.id, const ApprovalDecision.allowOnce());
    final result = await pending;

    expect(result.isError, isFalse);
    expect(File(path).readAsStringSync(), 'from plugin');
    expect((await turnCs())?.files.containsKey(path), isTrue);
  });

  test('rejected plugin write leaves the file untouched', () async {
    final path = '${tmp.path}/plugin-rejected.txt';

    final pending = tools.writeFileForPlugin(ctx, path, 'nope');
    final approval = await broker.approvalRequests.first;
    broker.resolveApproval(approval.id, const ApprovalDecision.deny());
    final result = await pending;

    expect(result.isError, isTrue);
    expect(File(path).existsSync(), isFalse);
    expect((await turnCs())?.files ?? const {}, isEmpty);
  });

  test('plugin write accepts empty content', () async {
    final path = '${tmp.path}/plugin-empty.txt';

    final pending = tools.writeFileForPlugin(ctx, path, '');
    final approval = await broker.approvalRequests.first;
    broker.resolveApproval(approval.id, const ApprovalDecision.allowOnce());
    final result = await pending;

    expect(result.isError, isFalse);
    expect(File(path).existsSync(), isTrue);
    expect(File(path).lengthSync(), 0);
  });
}

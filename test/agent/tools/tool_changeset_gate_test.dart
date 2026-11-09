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
import 'package:probably_works/agent/state/session_state_service.dart';
import 'package:probably_works/agent/tools/self_tool_handler.dart';
import 'package:probably_works/agent/tools/tool_catalog.dart';
import 'package:probably_works/agent/tools/tool_executor.dart';
import 'package:probably_works/agent/turn/turn_changeset.dart';
import 'package:probably_works/agent/turn/turn_changeset_service.dart';
import 'package:probably_works/agent/turn/turn_changeset_store.dart';
import 'package:probably_works/agent/workspace/workspace_context_loader.dart';
import 'package:probably_works/app/locale/locale_controller.dart';
import 'package:probably_works/app/theme/theme_controller.dart';
import 'package:probably_works/core/config/app_limits.dart';
import 'package:probably_works/core/data/chat_repository.dart';
import 'package:probably_works/core/data/host_repository.dart';
import 'package:probably_works/core/data/project_repository.dart';
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
      LocaleController(),
      ThemeController(),
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

  test('rejected write_file leaves changeset empty', () async {
    final path = '${tmp.path}/rejected.txt';
    final pending = tools.execute(
      call('w', ToolNames.writeFile, {'path': path, 'content': 'nope'}),
      ctx,
    );
    final approval = await broker.approvalRequests.first;
    broker.resolveApproval(approval.id, allow: false);
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
    broker.resolveApproval(approval.id, allow: true);
    final result = await pending;
    expect(result.isError, isTrue);
    expect(await turnCs(), isNull);
    expect(File(path).readAsStringSync(), 'surprise');
  });
}

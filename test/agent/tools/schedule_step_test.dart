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
import 'package:pw_agent/agent/schedule/scheduled_task_repository.dart';
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
import 'package:pw_agent/core/util/char_substring.dart';
import 'package:pw_agent/host/host_diagnostics.dart';
import 'package:pw_agent/host/host_runtime_factory.dart';
import 'package:pw_agent/host/ssh_connection_pool.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';

import '../../test_support/fake_appearance.dart';

class _NoNetworkLlm extends LlmProviderBase {
  _NoNetworkLlm()
    : super(const LlmProviderDescriptor(id: 'test', label: 'Test'));

  @override
  Stream<LlmEvent> stream(LlmRequest request) =>
      throw UnsupportedError('no network in tests');

  @override
  Future<List<LlmModelInfo>> listModels() async => const [];
}

/// Шаг журнала, который видит пользователь после инструментов расписания.
///
/// Лента чата строится из записей `ToolRun`, поэтому постановка и отмена задачи
/// должны оставлять такую запись; чтение списка — нет.
void main() {
  late AppDatabase db;
  late Directory tmp;
  late ChatRepository chats;
  late ScheduledTaskRepository tasks;
  late ToolExecutor tools;
  late ToolContext ctx;

  const chatId = 'c1';

  setUp(() async {
    db = openInMemoryDatabase();
    tmp = Directory.systemTemp.createTempSync('pw_schedule_step');
    final secrets = MemorySecretStore();
    final hosts = HostRepository(db, secrets);
    final settings = SettingsRepository(db);
    await settings.preload();
    await hosts.ensureLocalHost(DateTime.now());
    final local = (await hosts.byId(HostRepository.localHostId))!;
    chats = ChatRepository(db);
    await chats.saveChat(
      Chat(
        id: chatId,
        hostId: local.id,
        title: 't',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    );
    final runtimes = HostRuntimeFactory(
      SshConnectionPool(hosts, secrets, settings, HostKeyConfirmations()),
      const PipePtyLauncher(),
      VirtualHostProvisioner(db),
    );
    tasks = ScheduledTaskRepository(db);
    tools = ToolExecutor(
      chats,
      CommandExecutor(ExecLogStore(tmp), ActiveExecRegistry(), LiveOutputBus()),
      InteractionBroker(),
      SessionStateService(chats),
      WorkspaceContextLoader(settings),
      SelfToolHandler(
        hosts,
        settings,
        FakeAppearance(),
        ModelCatalogService(SavedModelRepository(db), _NoNetworkLlm()),
        HostDiagnostics(hosts, secrets, settings, runtimes),
      ),
      ProjectRepository(db),
      TurnChangesetService(TurnChangesetStore(tmp)),
      tasks,
    );
    ctx = ToolContext(
      chat: (await chats.chat(chatId))!,
      messageId: 'm1',
      host: local,
      runtime: runtimes.forHost(local),
      limits: AppLimits.defaults,
      policy: PolicyEngine(
        classifier: CommandClassifier(
          denylist: SettingsRepository.defaultDenylist,
        ),
        // Авто-подтверждение: эти инструменты не трогают Host и карточку не просят.
        mode: PolicyMode.yolo,
      ),
      // ignore: no-empty-block, инструменты расписания фоновые команды не запускают
      onBackgroundDone: (_, _) {},
    );
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  Future<ToolResult> run(String name, Map<String, Object?> args) =>
      tools.execute(
        LlmToolCall(id: name, name: name, arguments: jsonEncode(args)),
        ctx,
      );

  Future<List<ToolRun>> runs() => chats.toolRunsForChat(chatId);

  test('schedule_task leaves a step with a readable title', () async {
    await run(ToolNames.scheduleTask, {
      'prompt': 'remind me about the deploy',
      'delay_seconds': 600,
    });

    final step = (await runs()).single;
    expect(step.toolName, ToolNames.scheduleTask);
    expect(step.command, 'schedule in 10m · remind me about the deploy');
    expect(step.status, ToolRunStatus.done);
    expect(step.resultError, isFalse);
    // Шаг — владелец задачи: по этому id её удаляют вместе с сообщением и
    // переназначают при форке.
    final stored = (await tasks.forChat(chatId)).single;
    expect(ScheduledTaskRepository.taskIdOfRun(step), stored.id);
  });

  test('an absolute due time is shown in local time', () async {
    await run(ToolNames.scheduleTask, {
      'prompt': 'check the build',
      'due_at': '2030-01-01T09:00:00',
    });

    final step = (await runs()).single;
    expect(step.command, startsWith('schedule 2030-01-01 09:00'));
    expect(step.command, endsWith('· check the build'));
  });

  test('cancel_scheduled_task leaves a step with the short id', () async {
    final task = await tasks.create(
      chatId: chatId,
      prompt: 'x',
      dueAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
    );

    await run(ToolNames.cancelScheduledTask, {'id': task.id});

    final step = (await runs()).single;
    expect(step.command, 'cancel task ${charPrefix(task.id, 8)}');
    expect(step.outputText, contains('cancelled'));
    expect(step.resultError, isFalse);
  });

  test(
    'a rejected cancel is a step with an error text, not a call failure',
    () async {
      await run(ToolNames.cancelScheduledTask, {'id': 'missing'});

      final step = (await runs()).single;
      expect(step.status, ToolRunStatus.done);
      expect(step.resultError, isTrue);
      expect(step.outputText, contains('not found'));
    },
  );

  test('subagent chats do not get schedule tools', () {
    final subagent = Chat(
      id: 'sub',
      hostId: ctx.chat.hostId,
      title: 'sub',
      kind: ChatKind.subagent,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

    final names = [for (final spec in tools.specsFor(subagent)) spec.name];

    expect(names, isNot(contains(ToolNames.scheduleTask)));
    expect(names, isNot(contains(ToolNames.listScheduledTasks)));
    expect(names, isNot(contains(ToolNames.cancelScheduledTask)));
    // В обычном чате инструменты на месте.
    expect([
      for (final spec in tools.specsFor(ctx.chat)) spec.name,
    ], contains(ToolNames.scheduleTask));
  });

  test('listing tasks does not leave a step', () async {
    await tasks.create(
      chatId: chatId,
      prompt: 'x',
      dueAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
    );

    await run(ToolNames.listScheduledTasks, {});

    expect(await runs(), isEmpty);
  });
}

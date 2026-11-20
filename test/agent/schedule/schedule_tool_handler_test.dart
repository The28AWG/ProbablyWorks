import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/test_support/pipe_pty_launcher.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/policy/command_classifier.dart';
import 'package:pw_agent/agent/policy/policy_engine.dart';
import 'package:pw_agent/agent/schedule/schedule_tool_handler.dart';
import 'package:pw_agent/agent/schedule/scheduled_task.dart';
import 'package:pw_agent/agent/schedule/scheduled_task_repository.dart';
import 'package:pw_agent/agent/tools/tool_catalog.dart';
import 'package:pw_agent/agent/tools/tool_types.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/core/data/chat_repository.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/data/virtual_host_provisioner.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/host/host_runtime_factory.dart';
import 'package:pw_agent/host/ssh_connection_pool.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';

void main() {
  late AppDatabase db;
  late ChatRepository chats;
  late Host local;
  late ScheduledTaskRepository tasks;
  late ScheduleToolHandler handler;
  late ToolContext ctx;
  late ToolContext Function(Chat chat) openContext;

  const chatId = 'c1';

  setUp(() async {
    db = openInMemoryDatabase();
    final secrets = MemorySecretStore();
    final hosts = HostRepository(db, secrets);
    final settings = SettingsRepository(db);
    await settings.preload();
    await hosts.ensureLocalHost(DateTime.now());
    local = (await hosts.byId(HostRepository.localHostId))!;
    chats = ChatRepository(db);
    for (final id in [chatId, 'other', 'sub']) {
      await chats.saveChat(
        Chat(
          id: id,
          hostId: local.id,
          title: id,
          kind: id == 'sub' ? ChatKind.subagent : ChatKind.main,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      );
    }
    final runtimes = HostRuntimeFactory(
      SshConnectionPool(hosts, secrets, settings, HostKeyConfirmations()),
      const PipePtyLauncher(),
      VirtualHostProvisioner(db),
    );
    final policy = PolicyEngine(
      classifier: CommandClassifier(
        denylist: SettingsRepository.defaultDenylist,
      ),
      mode: PolicyMode.ask,
    );
    tasks = ScheduledTaskRepository(db);
    handler = ScheduleToolHandler(tasks);
    ToolContext contextFor(Chat chat) => ToolContext(
      chat: chat,
      messageId: 'm1',
      host: local,
      runtime: runtimes.forHost(local),
      limits: AppLimits.defaults,
      policy: policy,
      // ignore: no-empty-block, обработчик расписания фоновые команды не запускает
      onBackgroundDone: (_, _) {},
    );
    ctx = contextFor((await chats.chat(chatId))!);
    openContext = contextFor;
  });

  tearDown(() => db.close());

  LlmToolCall call(String name, Map<String, Object?> args) =>
      LlmToolCall(id: name, name: name, arguments: jsonEncode(args));

  test('schedule_task stores a pending task with a relative delay', () async {
    final result = await handler.call(
      ctx,
      call(ToolNames.scheduleTask, {
        'prompt': 'ask about deploy',
        'delay_seconds': 600,
      }),
      {'prompt': 'ask about deploy', 'delay_seconds': 600},
    );

    expect(result.isError, isFalse);
    final stored = (await tasks.forChat(chatId)).single;
    expect(stored.prompt, 'ask about deploy');
    expect(stored.status, ScheduledTaskStatus.pending);
    expect(stored.dueAt.isAfter(DateTime.now().toUtc()), isTrue);
  });

  test('schedule_task accepts an absolute due time', () async {
    await handler.call(
      ctx,
      call(ToolNames.scheduleTask, {
        'prompt': 'later',
        'due_at': '2030-01-01T09:00:00',
      }),
      {'prompt': 'later', 'due_at': '2030-01-01T09:00:00'},
    );

    final stored = (await tasks.forChat(chatId)).single;
    expect(stored.dueAt.isAtSameMomentAs(DateTime(2030, 1, 1, 9)), isTrue);
  });

  test('schedule_task without a time is rejected', () async {
    await expectLater(
      handler.call(ctx, call(ToolNames.scheduleTask, {'prompt': 'x'}), {
        'prompt': 'x',
      }),
      throwsArgumentError,
    );
  });

  test('list and cancel work on the current chat only', () async {
    final created = await tasks.create(
      chatId: chatId,
      prompt: 'x',
      dueAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
    );

    final list = await handler.call(
      ctx,
      call(ToolNames.listScheduledTasks, {}),
      {},
    );
    expect(list.text, contains(created.id));

    final cancelled = await handler.call(
      ctx,
      call(ToolNames.cancelScheduledTask, {'id': created.id}),
      {'id': created.id},
    );
    expect(cancelled.isError, isFalse);
    expect(
      (await tasks.byId(created.id))!.status,
      ScheduledTaskStatus.cancelled,
    );
  });

  test('subagent chats cannot schedule tasks', () async {
    final subagent = openContext((await chats.chat('sub'))!);

    final result = await handler.call(
      subagent,
      call(ToolNames.scheduleTask, {'prompt': 'x', 'delay_seconds': 60}),
      {'prompt': 'x', 'delay_seconds': 60},
    );

    expect(result.isError, isTrue);
    expect(result.text, contains('only in a user chat'));
    expect(await tasks.forChat('sub'), isEmpty);
  });

  test('cancel rejects a task that belongs to another chat', () async {
    final created = await tasks.create(
      chatId: 'other',
      prompt: 'x',
      dueAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
    );

    final result = await handler.call(
      ctx,
      call(ToolNames.cancelScheduledTask, {'id': created.id}),
      {'id': created.id},
    );

    expect(result.isError, isTrue);
    expect((await tasks.byId(created.id))!.status, ScheduledTaskStatus.pending);
  });
}

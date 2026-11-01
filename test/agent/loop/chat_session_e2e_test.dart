import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/agent/context/context_builder.dart';
import 'package:probably_works/agent/context/context_compactor.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/exec/active_exec_registry.dart';
import 'package:probably_works/agent/exec/command_executor.dart';
import 'package:probably_works/agent/exec/exec_log_store.dart';
import 'package:probably_works/agent/exec/live_output_bus.dart';
import 'package:probably_works/agent/interaction/interaction_broker.dart';
import 'package:probably_works/agent/loop/agent_event.dart';
import 'package:probably_works/agent/loop/agent_hub.dart';
import 'package:probably_works/agent/loop/chat_session.dart';
import 'package:probably_works/agent/state/session_state_service.dart';
import 'package:probably_works/agent/tools/tool_executor.dart';
import 'package:probably_works/agent/workspace/workspace_context_loader.dart';
import 'package:probably_works/core/data/chat_repository.dart';
import 'package:probably_works/core/data/host_repository.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/db/app_database.dart';
import 'package:probably_works/core/db/db_connection.dart';
import 'package:probably_works/core/notify/desktop_notifier.dart';
import 'package:probably_works/core/security/secret_store.dart';
import 'package:probably_works/host/host_runtime_factory.dart';
import 'package:probably_works/host/ssh_connection_pool.dart';
import 'package:probably_works/providers/ai/llm_port.dart';

/// Скриптованный LLM: каждый вызов stream() отдаёт очередной сценарий ответа.
class _FakeLlm implements LlmProvider {
  final List<List<LlmEvent>> script = [];
  final List<LlmRequest> requests = [];

  @override
  Stream<LlmEvent> stream(LlmRequest request) {
    requests.add(request);
    return Stream.fromIterable(script.removeAt(0));
  }

  @override
  Future<List<LlmModelInfo>> listModels() async => const [];
}

class _SilentNotifier extends DesktopNotifier {
  @override
  Future<void> notify({required String title, required String body}) async {
    return;
  }
}

LlmToolCall _call(String id, String name, String args) =>
    LlmToolCall(id: id, name: name, arguments: args);

void main() {
  late AppDatabase db;
  late Directory tmp;
  late _FakeLlm llm;
  late AgentHub hub;
  late InteractionBroker broker;

  setUp(() async {
    db = openInMemoryDatabase();
    tmp = Directory.systemTemp.createTempSync('pw_e2e');
    final chats = ChatRepository(db);
    final settings = SettingsRepository(db);
    final hosts = HostRepository(db);
    final pool = SshConnectionPool(
      hosts,
      MemorySecretStore(),
      settings,
      HostKeyConfirmations(),
    );
    broker = InteractionBroker();
    final registry = ActiveExecRegistry();
    final bus = LiveOutputBus();
    final logs = ExecLogStore(tmp);
    final commands = CommandExecutor(logs, registry, bus);
    final state = SessionStateService(chats);
    final workspace = WorkspaceContextLoader(settings);
    final tools = ToolExecutor(chats, commands, broker, state, workspace);
    final builder = ContextBuilder();
    llm = _FakeLlm();
    final compactor = ContextCompactor(chats, llm, builder);
    hub = AgentHub(
      chats,
      settings,
      hosts,
      HostRuntimeFactory(pool),
      llm,
      builder,
      compactor,
      tools,
      workspace,
      state,
      broker,
      registry,
      logs,
      _SilentNotifier(),
    );
    await hosts.ensureLocalHost(DateTime.now());
    await settings.write(SettingsRepository.keyDefaultModel, 'fake/model');
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  Future<String> createChat({PolicyMode mode = PolicyMode.yolo}) async {
    final now = DateTime.now();
    await hub.chats.saveChat(
      Chat(
        id: 'chat-1',
        hostId: 'local',
        title: 'test',
        titleSource: ChatTitleSource.user,
        createdAt: now,
        updatedAt: now,
        policyMode: mode,
        model: 'fake/model',
      ),
    );
    return 'chat-1';
  }

  /// Отправляет текст и ждёт конца хода.
  Future<void> runTurn(ChatSession session, String text) async {
    final finished = session.events.firstWhere((e) => e is AgentTurnFinished);
    await session.submit(text);
    await finished;
  }

  test('model calls run_command, result is stored, turn completes', () async {
    final chatId = await createChat();
    llm.script
      ..add([
        LlmCompleted(
          toolCalls: [_call('c1', 'run_command', '{"command":"echo hello"}')],
        ),
      ])
      ..add([const LlmTextDelta('done'), const LlmCompleted()]);

    await runTurn(hub.session(chatId), 'say hello');

    final messages = await hub.chats.messages(chatId);
    expect(
      [for (final m in messages) m.role],
      [
        MessageRole.user,
        MessageRole.assistant,
        MessageRole.tool,
        MessageRole.assistant,
      ],
    );
    final toolMessage = messages[2];
    expect(toolMessage.toolCallId, 'c1');
    expect(toolMessage.text, contains('status: done'));
    expect(toolMessage.text, contains('hello'));
    expect(messages.last.text, 'done');

    final runs = await hub.chats.toolRunsForChat(chatId);
    expect(runs, hasLength(1));
    expect(runs.single.status, ToolRunStatus.done);
    expect(runs.single.outputText, contains('hello'));
    expect(
      runs.single.logPath,
      isNull,
      reason: 'log must be compacted into the DB',
    );
    expect(
      llm.requests.last.messages.any((m) => m.role == LlmRole.tool),
      isTrue,
    );
  });

  test('sudo is denied by policy and the model receives the denial', () async {
    final chatId = await createChat();
    llm.script
      ..add([
        LlmCompleted(
          toolCalls: [_call('c1', 'run_command', '{"command":"sudo ls"}')],
        ),
      ])
      ..add([const LlmTextDelta('ok'), const LlmCompleted()]);

    await runTurn(hub.session(chatId), 'escalate');

    final tool = (await hub.chats.messages(chatId))
        .firstWhere((m) => m.role == MessageRole.tool);
    expect(tool.text, startsWith('denied by policy'));
  });

  test(
    'ask mode: rejected approval is returned to the model without running',
    () async {
      final chatId = await createChat(mode: PolicyMode.ask);
      final approvals = broker.approvalRequests.listen((request) {
        broker.resolveApproval(request.id, allow: false);
      });
      addTearDown(approvals.cancel);
      llm.script
        ..add([
          LlmCompleted(
            toolCalls: [
              _call(
                'c1',
                'run_command',
                '{"command":"mkdir should_not_exist"}',
              ),
            ],
          ),
        ])
        ..add([const LlmTextDelta('stopped'), const LlmCompleted()]);

      await runTurn(hub.session(chatId), 'make dir');

      final tool = (await hub.chats.messages(chatId))
          .firstWhere((m) => m.role == MessageRole.tool);
      expect(tool.text, contains('rejected'));
      final runs = await hub.chats.toolRunsForChat(chatId);
      expect(runs.single.status, ToolRunStatus.denied);
    },
  );

  test(
    'edit of a user message truncates later history and reruns the turn',
    () async {
      final chatId = await createChat();
      llm.script
        ..add([
          LlmCompleted(
            toolCalls: [_call('c1', 'run_command', '{"command":"echo first"}')],
          ),
        ])
        ..add([const LlmTextDelta('first done'), const LlmCompleted()]);
      final session = hub.session(chatId);
      await runTurn(session, 'first task');

      final userMessage = (await hub.chats.messages(chatId))
          .firstWhere((m) => m.role == MessageRole.user);
      llm.script.add([const LlmTextDelta('second done'), const LlmCompleted()]);
      final finished = session.events.firstWhere((e) => e is AgentTurnFinished);
      await session.editUserMessage(userMessage.id, 'edited task');
      await finished;

      final messages = await hub.chats.messages(chatId);
      expect(
        [for (final m in messages) m.role],
        [MessageRole.user, MessageRole.assistant],
      );
      expect(messages.first.text, 'edited task');
      expect(messages.last.text, 'second done');
      expect(await hub.chats.toolRunsForChat(chatId), isEmpty);
    },
  );
}

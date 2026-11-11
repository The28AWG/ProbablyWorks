import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:probably_works/agent/context/context_builder.dart';
import 'package:probably_works/agent/context/context_compactor.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/domain/project.dart';
import 'package:probably_works/agent/exec/active_exec_registry.dart';
import 'package:probably_works/agent/exec/command_executor.dart';
import 'package:probably_works/agent/exec/exec_log_store.dart';
import 'package:probably_works/agent/exec/live_output_bus.dart';
import 'package:probably_works/agent/interaction/edit_file_changes_request.dart';
import 'package:probably_works/agent/interaction/interaction_broker.dart';
import 'package:probably_works/agent/loop/agent_event.dart';
import 'package:probably_works/agent/loop/agent_hub.dart';
import 'package:probably_works/agent/loop/chat_session.dart';
import 'package:probably_works/agent/loop/chat_title.dart';
import 'package:probably_works/agent/mcp/mcp_client_manager.dart';
import 'package:probably_works/agent/mcp/mcp_service.dart';
import 'package:probably_works/agent/plugins/plugin_catalog.dart';
import 'package:probably_works/agent/plugins/plugin_service.dart';
import 'package:probably_works/agent/policy/command_risk.dart';
import 'package:probably_works/agent/policy/security_profile.dart';
import 'package:probably_works/agent/project/project_lifecycle.dart';
import 'package:probably_works/agent/recovery/startup_recovery.dart';
import 'package:probably_works/agent/state/session_state_service.dart';
import 'package:probably_works/agent/tools/self_tool_handler.dart';
import 'package:probably_works/agent/tools/tool_catalog.dart';
import 'package:probably_works/agent/tools/tool_executor.dart';
import 'package:probably_works/agent/turn/turn_changeset_service.dart';
import 'package:probably_works/agent/turn/turn_changeset_store.dart';
import 'package:probably_works/agent/workspace/workspace_context_loader.dart';
import 'package:probably_works/app/locale/locale_controller.dart';
import 'package:probably_works/app/theme/theme_controller.dart';
import 'package:probably_works/core/data/chat_draft_store.dart';
import 'package:probably_works/core/data/chat_repository.dart';
import 'package:probably_works/core/data/host_repository.dart';
import 'package:probably_works/core/data/mcp_server_repository.dart';
import 'package:probably_works/core/data/policy_profile_repository.dart';
import 'package:probably_works/core/data/project_repository.dart';
import 'package:probably_works/core/data/saved_model_repository.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/data/virtual_host_provisioner.dart';
import 'package:probably_works/core/db/app_database.dart';
import 'package:probably_works/core/db/db_connection.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/error/app_failure.dart';
import 'package:probably_works/core/notify/app_notifier.dart';
import 'package:probably_works/core/security/secret_store.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/host/host_capture.dart';
import 'package:probably_works/host/host_diagnostics.dart';
import 'package:probably_works/host/host_op.dart';
import 'package:probably_works/host/host_runtime_factory.dart';
import 'package:probably_works/host/read_file_output.dart';
import 'package:probably_works/host/ssh_connection_pool.dart';
import 'package:probably_works/providers/ai/llm_port.dart';
import 'package:probably_works/providers/ai/model_catalog.dart';
import 'package:probably_works/test_support/pipe_pty_launcher.dart';

/// Скриптованный LLM: каждый вызов stream() отдаёт очередной сценарий ответа.
class _FakeLlm implements LlmProvider {
  final List<List<LlmEvent>> script = [];
  final List<LlmRequest> requests = [];
  final List<LlmRequest> titleRequests = [];

  /// Ответ модели на запрос заголовка (отдельно от сценария хода).
  String titleReply = '';

  /// Список моделей, который вернёт OpenRouter при обновлении каталога.
  List<LlmModelInfo> models = const [];
  int listCalls = 0;

  /// Если задано — следующий ход завершится этой ошибкой вместо ответа.
  LlmFailure? nextFailure;

  @override
  Future<LlmKeyInfo> checkKey() =>
      Future.value(const LlmKeyInfo(label: 'test', usage: 0));

  @override
  Stream<LlmEvent> stream(LlmRequest request) {
    if (request.messages.first.content == ChatTitle.systemPrompt) {
      titleRequests.add(request);
      return Stream.fromIterable([
        LlmTextDelta(titleReply),
        const LlmCompleted(),
      ]);
    }
    requests.add(request);
    final failure = nextFailure;
    if (failure != null) {
      nextFailure = null;
      return Stream.error(failure);
    }
    return Stream.fromIterable(script.removeAt(0));
  }

  @override
  Future<List<LlmModelInfo>> listModels() async {
    listCalls++;
    return models;
  }
}

class _SilentNotifier implements AppNotifier {
  @override
  Future<void> notify({
    required AgentNoticeKind kind,
    required String chatTitle,
    String? detail,
  }) async {
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
  late ChatDraftStore drafts;

  setUp(() async {
    db = openInMemoryDatabase();
    tmp = Directory.systemTemp.createTempSync('pw_e2e');
    final chats = ChatRepository(db);
    final settings = SettingsRepository(db);
    await settings.preload();
    final secrets = MemorySecretStore();
    final hosts = HostRepository(db, secrets);
    final pool = SshConnectionPool(
      hosts,
      secrets,
      settings,
      HostKeyConfirmations(),
    );
    broker = InteractionBroker();
    final registry = ActiveExecRegistry();
    final bus = LiveOutputBus();
    final logs = ExecLogStore(tmp);
    final turnChangesets = TurnChangesetService(TurnChangesetStore(tmp));
    final commands = CommandExecutor(logs, registry, bus);
    final state = SessionStateService(chats);
    final workspace = WorkspaceContextLoader(settings);
    final builder = ContextBuilder();
    llm = _FakeLlm();
    final modelCatalog = ModelCatalogService(SavedModelRepository(db), llm);
    final runtimes = HostRuntimeFactory(
      pool,
      const PipePtyLauncher(),
      VirtualHostProvisioner(db),
    );
    final self = SelfToolHandler(
      hosts,
      settings,
      LocaleController(),
      ThemeController(),
      modelCatalog,
      HostDiagnostics(hosts, MemorySecretStore(), settings, runtimes),
    );
    final tools = ToolExecutor(
      chats,
      commands,
      broker,
      state,
      workspace,
      self,
      ProjectRepository(db),
      turnChangesets,
    );
    final compactor = ContextCompactor(chats, llm, builder);
    final mcp = McpService(
      McpServerRepository(db),
      McpClientManager(secrets),
      tools,
      secrets,
    );
    final plugins = PluginService(
      const PluginCatalog(),
      settings,
      tools,
      commands,
      secrets,
    );
    drafts = ChatDraftStore(chats);
    final projectStore = ProjectRepository(db);
    hub = AgentHub(
      chats,
      settings,
      hosts,
      runtimes,
      llm,
      modelCatalog,
      builder,
      compactor,
      tools,
      mcp,
      plugins,
      workspace,
      state,
      broker,
      registry,
      logs,
      turnChangesets,
      _SilentNotifier(),
      ProjectLifecycleService(db, projectStore, hosts, runtimes),
      projectStore,
      PolicyProfileRepository(db),
    );
    await hosts.ensureLocalHost(DateTime.now());
    await settings.write(SettingsRepository.keyDefaultModel, 'fake/model');
  });

  tearDown(() async {
    // Отложенная запись черновика не должна сработать после закрытия БД.
    await drafts.flush();
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  Future<String> createChatWithId(String id) async {
    final now = DateTime.now();
    await hub.chats.saveChat(
      Chat(id: id, hostId: 'local', title: id, createdAt: now, updatedAt: now),
    );
    return id;
  }

  Future<String> createChat({
    PolicyMode mode = PolicyMode.yolo,
    ChatTitleSource titleSource = ChatTitleSource.user,
  }) async {
    final now = DateTime.now();
    await hub.chats.saveChat(
      Chat(
        id: 'chat-1',
        hostId: 'local',
        title: 'test',
        titleSource: titleSource,
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

  test('daily spending limit blocks a new step', () async {
    final chatId = await createChat();
    await hub.settings.saveDailyBudget(chatId, 0.5);
    await hub.settings.addDailyUsage(
      chatId,
      promptTokens: 1,
      completionTokens: 1,
      costUsd: 1,
    );
    final session = hub.session(chatId);
    final failures = <AppFailure>[];
    final sub = session.events.listen((event) {
      if (event is AgentFailureRaised) failures.add(event.failure);
    });
    addTearDown(sub.cancel);

    await runTurn(session, 'hello');

    expect(failures.single.message, contains('daily spending limit'));
  });

  test('model not found switches to the fallback model', () async {
    final chatId = await createChat();
    llm.models = const [
      LlmModelInfo(id: 'fake/model', name: 'Primary', supportsTools: true),
      LlmModelInfo(id: 'fallback/model', name: 'Fallback', supportsTools: true),
    ];
    await hub.models.refresh();
    await hub.settings.write(
      SettingsRepository.keyFallbackModel,
      'fallback/model',
    );
    llm.nextFailure = const LlmFailure(
      'model not found',
      statusCode: 404,
      modelNotFound: true,
    );
    llm.script.add([
      const LlmTextDelta('fallback answer'),
      const LlmCompleted(),
    ]);

    final session = hub.session(chatId);
    await runTurn(session, 'hello');

    final messages = await hub.chats.messages(chatId);
    expect(
      messages.any(
        (message) =>
            message.role == MessageRole.assistant &&
            message.text.contains('fallback answer'),
      ),
      isTrue,
    );
    expect(
      messages.any(
        (message) =>
            message.role == MessageRole.event &&
            message.text.contains('fallback/model'),
      ),
      isTrue,
    );
    expect(llm.requests.last.model, 'fallback/model');
  });

  test('model without tools is rejected before the request', () async {
    final chatId = await createChat();
    llm.models = const [
      LlmModelInfo(id: 'fake/model', name: 'No tools', supportsTools: false),
    ];
    await hub.models.refresh();
    final failures = <AppFailure>[];
    final session = hub.session(chatId);
    final sub = session.events.listen((event) {
      if (event is AgentFailureRaised) failures.add(event.failure);
    });
    addTearDown(sub.cancel);

    await runTurn(session, 'hello');

    expect(failures.single.message, contains('does not support tools'));
    expect(llm.requests, isEmpty);
  });

  test('context length failure retries once with a rebuilt request', () async {
    final chatId = await createChat();
    final session = hub.session(chatId);
    llm.nextFailure = const LlmFailure(
      'context length exceeded',
      contextLengthExceeded: true,
    );
    llm.script.add([const LlmTextDelta('ok'), const LlmCompleted()]);

    await runTurn(session, 'hello');

    final assistant = (await hub.chats.messages(chatId)).last;
    expect(assistant.role, MessageRole.assistant);
    expect(assistant.text, 'ok');
  });

  test('a length finish asks the model to continue the answer', () async {
    final chatId = await createChat();
    final session = hub.session(chatId);
    llm.script
      ..add([
        const LlmTextDelta('part'),
        const LlmCompleted(finishReason: 'length'),
      ])
      ..add([const LlmTextDelta(' rest'), const LlmCompleted()]);

    await runTurn(session, 'hello');

    final messages = await hub.chats.messages(chatId);
    final answers = [
      for (final message in messages)
        if (message.role == MessageRole.assistant) message.text,
    ];
    final events = [
      for (final message in messages)
        if (message.role == MessageRole.event) message.text,
    ];
    expect(answers, ['part', ' rest']);
    expect(events.single, contains('cut by the model output limit'));
  });

  test('editing a message after compaction clears the stale summary', () async {
    final chatId = await createChat();
    final now = DateTime.now();
    for (var seq = 1; seq <= 4; seq++) {
      await hub.chats.insertMessage(
        ChatMessage(
          id: 'm$seq',
          chatId: chatId,
          seq: seq,
          role: seq.isOdd ? MessageRole.user : MessageRole.assistant,
          createdAt: now,
          text: 'message $seq',
        ),
      );
    }
    final before = (await hub.chats.chat(chatId))!;
    await hub.chats.saveChat(
      before.copyWith(compactionSummary: 'old summary', compactedUntilSeq: 3),
    );

    final users = [
      for (final message in await hub.chats.messages(chatId))
        if (message.role == MessageRole.user) message,
    ];
    final session = hub.session(chatId);
    final finished = session.events.firstWhere((e) => e is AgentTurnFinished);
    llm.script.add([const LlmTextDelta('ok'), const LlmCompleted()]);

    expect(await session.editUserMessage(users.first.id, 'new task'), isTrue);
    await finished;

    final updated = (await hub.chats.chat(chatId))!;
    // Сводка описывала удалённые сообщения, а cutoff был больше нового seq.
    expect(updated.compactionSummary, isNull);
    expect(updated.compactedUntilSeq, 0);
  });

  test('subagent runs in a hidden chat and returns its result', () async {
    final chatId = await createChat();
    llm.models = const [
      LlmModelInfo(id: 'fake/model', name: 'Fake', supportsTools: true),
    ];
    await hub.models.refresh();
    llm.script.add([const LlmTextDelta('child result'), const LlmCompleted()]);

    final parent = (await hub.chats.chat(chatId))!;
    final run = await hub.subagents.start(
      parent: parent,
      title: 'Child',
      task: 'child task',
      context: 'parent context',
    );
    final result = await hub.subagents.wait(run.id);

    expect(result.text, contains('child result'));
    expect(run.title, 'Child');
    final childMessages = await hub.chats.messages(run.id);
    expect(childMessages.first.text, contains('parent context'));
    expect(hub.subagents.readReport(run.id), contains('child result'));
    final chunk = hub.subagents.readReport(run.id, offset: 0, limit: 5);
    expect(chunk, contains('more: offset=5'));
    final child = await hub.chats.chat(run.id);
    expect(child?.kind, ChatKind.subagent);
    expect(child?.parentChatId, chatId);
    expect(child?.rootChatId, chatId);
    expect(child?.depth, 1);
    expect(
      (await hub.chats.watchChats().first).map((chat) => chat.id),
      isNot(contains(run.id)),
    );

    await hub.chats.deleteChat(chatId);
    expect(await hub.chats.chat(run.id), isNull);
  });

  test('subagent model follows parent, setting and tool strategy', () async {
    final chatId = await createChat();
    llm.models = const [
      LlmModelInfo(id: 'fake/model', name: 'Parent', supportsTools: true),
      LlmModelInfo(id: 'cheap/model', name: 'Cheap', supportsTools: true),
    ];
    await hub.models.refresh();
    await hub.settings.write(
      SettingsRepository.keySubagentModel,
      'cheap/model',
    );
    final parent = (await hub.chats.chat(chatId))!;

    Future<String> runModel(String? strategy) async {
      llm.script.add([const LlmTextDelta('ok'), const LlmCompleted()]);
      final run = await hub.subagents.start(
        parent: parent,
        title: 'Task',
        task: 'task',
        modelStrategy: strategy,
      );
      await hub.subagents.wait(run.id);
      return (await hub.chats.chat(run.id))!.model!;
    }

    expect(await runModel(null), 'cheap/model');
    expect(await runModel('default'), 'cheap/model');
    expect(await runModel('parent'), 'fake/model');

    await hub.settings.write(SettingsRepository.keySubagentModel, '');
    expect(await runModel('default'), 'fake/model');
  });

  test('manual compaction records when and why it happened', () async {
    final chatId = await createChat();
    final now = DateTime.now();
    for (var seq = 1; seq <= 4; seq++) {
      await hub.chats.insertMessage(
        ChatMessage(
          id: 'm$seq',
          chatId: chatId,
          seq: seq,
          role: seq.isOdd ? MessageRole.user : MessageRole.assistant,
          createdAt: now,
          text: 'message $seq',
        ),
      );
    }
    final session = hub.session(chatId);
    llm.script.add([const LlmTextDelta('summary'), const LlmCompleted()]);

    await session.compactNow(force: true);

    final updated = (await hub.chats.chat(chatId))!;
    expect(updated.compactedUntilSeq, greaterThan(0));
    final info = await hub.settings.readCompactionInfo(chatId);
    expect(info, isNotNull);
    expect(info!.reason, 'forced');
    expect(info.cutoffSeq, updated.compactedUntilSeq);
    expect(info.summaryChars, updated.compactionSummary?.length);
  });

  Future<void> waitUntil(bool Function() ready) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (!ready() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(ready(), isTrue);
  }

  /// Ждёт, пока в ленте появятся результаты ровно этих вызовов, в этом порядке.
  Future<List<ChatMessage>> waitForToolIds(
    String chatId,
    List<String> ids,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    var tools = <ChatMessage>[];
    while (DateTime.now().isBefore(deadline)) {
      tools = [
        for (final message in await hub.chats.messages(chatId))
          if (message.role == MessageRole.tool) message,
      ];
      final got = [for (final message in tools) message.toolCallId];
      if (got.length == ids.length) {
        var same = true;
        for (var i = 0; i < ids.length; i++) {
          if (got[i] != ids[i]) same = false;
        }
        if (same) return tools;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect([for (final message in tools) message.toolCallId], ids);
    return tools;
  }

  test('a model removed from OpenRouter is not blocked: the send fails with a model-missing failure and the catalog is rechecked', () async {
    final chatId = await createChat();
    llm.models = const [LlmModelInfo(id: 'fake/model', name: 'Fake')];
    await hub.models.refresh();
    // Модель исчезла с сервера, но в кеше ещё есть: следующий запрос вернёт 404.
    llm
      ..models = const [LlmModelInfo(id: 'other/model', name: 'Other')]
      ..nextFailure = const LlmFailure(
        'No endpoints found for fake/model.',
        statusCode: 404,
        modelNotFound: true,
      );
    final session = hub.session(chatId);
    final failures = <AppFailure>[];
    final sub = session.events.listen((e) {
      if (e is AgentFailureRaised) failures.add(e.failure);
    });

    await runTurn(session, 'hello');
    await sub.cancel();

    expect(llm.requests, hasLength(1));
    expect(failures.single, isA<LlmFailure>());
    expect((failures.single as LlmFailure).modelNotFound, isTrue);
    expect(llm.listCalls, 2);
    expect(hub.models.state.statusOf('fake/model'), ModelStatus.unavailable);
  });

  test(
    'a binary file goes to the model once, in the first request of its turn',
    () async {
      final chatId = await createChat();
      llm
        ..models = const [
          LlmModelInfo(
            id: 'fake/model',
            name: 'Fake',
            inputModalities: ['text', 'file'],
          ),
        ]
        ..script.addAll([
          [const LlmTextDelta('вижу PDF'), const LlmCompleted()],
          [const LlmTextDelta('и ещё раз'), const LlmCompleted()],
        ]);
      await hub.models.refresh();
      final session = hub.session(chatId);
      final pdf = AttachmentRef(
        name: 'scan.pdf',
        mode: AttachmentMode.file,
        mimeType: 'application/pdf',
        sizeBytes: 8,
        bytes: Uint8List.fromList(utf8.encode('%PDF-1.4')),
      );

      final finished = session.events.firstWhere((e) => e is AgentTurnFinished);
      await session.submit('что в файле?', attachments: [pdf]);
      await finished;
      await runTurn(session, 'а теперь?');

      expect(llm.requests, hasLength(2));
      final first = llm.requests.first.messages.lastWhere(
        (m) => m.role == LlmRole.user,
      );
      expect(first.files.single.name, 'scan.pdf');
      expect(first.files.single.mimeType, 'application/pdf');
      expect(first.content, contains('content is attached to this message'));

      final second = llm.requests[1].messages;
      expect(second.every((m) => m.files.isEmpty), isTrue);
      final earlier = second.firstWhere(
        (m) => m.role == LlmRole.user && m.content.contains('scan.pdf'),
      );
      expect(earlier.content, contains('no longer in context'));

      final stored = await hub.chats.messages(chatId);
      final user = stored.firstWhere((m) => m.text == 'что в файле?');
      expect(user.attachments.single.bytes, isNull);
      expect(user.attachments.single.name, 'scan.pdf');
    },
  );

  test(
    'a model without file input is refused before any request is sent',
    () async {
      final chatId = await createChat();
      llm.models = const [
        LlmModelInfo(id: 'fake/model', name: 'Fake', inputModalities: ['text']),
      ];
      await hub.models.refresh();
      final session = hub.session(chatId);
      final failures = <AppFailure>[];
      final sub = session.events.listen((e) {
        if (e is AgentFailureRaised) failures.add(e.failure);
      });

      final finished = session.events.firstWhere((e) => e is AgentTurnFinished);
      await session.submit(
        'посмотри',
        attachments: [
          AttachmentRef(
            name: 'scan.pdf',
            mode: AttachmentMode.file,
            mimeType: 'application/pdf',
            sizeBytes: 8,
            bytes: Uint8List.fromList(utf8.encode('%PDF-1.4')),
          ),
        ],
      );
      await finished;
      await sub.cancel();

      expect(llm.requests, isEmpty);
      expect(failures.single.message, contains('does not accept'));
    },
  );

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

  test(
    'read_file: шаг хранит путь вместо скрипта, вывод разбирается видом',
    () async {
      final chatId = await createChat();
      final file = File('${tmp.path}/sample.txt')
        ..writeAsStringSync('alpha\nbeta');
      llm.script
        ..add([
          LlmCompleted(
            toolCalls: [
              _call('c1', 'read_file', jsonEncode({'path': file.path})),
            ],
          ),
        ])
        ..add([const LlmTextDelta('готово'), const LlmCompleted()]);

      await runTurn(hub.session(chatId), 'прочитай файл');

      final runs = await hub.chats.toolRunsForChat(chatId);
      expect(runs, hasLength(1));
      expect(runs.single.toolName, 'read_file');
      expect(runs.single.command, 'read ${file.path}');
      final parsed = parseReadFileOutput(runs.single.outputText ?? '');
      expect(parsed, isA<ReadFileText>());
      expect(
        [for (final line in (parsed! as ReadFileText).lines) line.text],
        ['alpha', 'beta'],
      );
    },
  );

  test('reasoning is stored on its step, streamed, and kept out of the model context', () async {
    final chatId = await createChat();
    final session = hub.session(chatId);
    final streamed = <AgentReasoningDelta>[];
    final sub = session.events
        .where((e) => e is AgentReasoningDelta)
        .cast<AgentReasoningDelta>()
        .listen(streamed.add);
    llm.script
      ..add([
        const LlmReasoningDelta('Рассуждение первого шага'),
        LlmCompleted(
          toolCalls: [_call('c1', 'run_command', '{"command":"echo hello"}')],
        ),
      ])
      ..add([
        const LlmReasoningDelta('Рассуждение финального шага'),
        const LlmTextDelta('done'),
        const LlmCompleted(),
      ]);

    await runTurn(session, 'say hello');
    await sub.cancel();

    final assistants = [
      for (final m in await hub.chats.messages(chatId))
        if (m.role == MessageRole.assistant) m,
    ];
    expect(assistants.map((m) => m.reasoning), [
      'Рассуждение первого шага',
      'Рассуждение финального шага',
    ]);
    expect(assistants.last.text, 'done');
    expect(streamed.map((e) => e.text), [
      'Рассуждение первого шага',
      'Рассуждение финального шага',
    ]);
    for (final request in llm.requests) {
      for (final message in request.messages) {
        expect(message.content, isNot(contains('Рассуждение')));
      }
    }
  });

  test(
    'a step with only reasoning is kept, and not replayed to the model',
    () async {
      final chatId = await createChat();
      llm.script
        ..add([
          const LlmReasoningDelta('Только мысли без ответа'),
          const LlmCompleted(),
        ])
        ..add([const LlmTextDelta('ok'), const LlmCompleted()]);

      await runTurn(hub.session(chatId), 'первый вопрос');
      await runTurn(hub.session(chatId), 'второй вопрос');

      final assistants = [
        for (final m in await hub.chats.messages(chatId))
          if (m.role == MessageRole.assistant) m,
      ];
      expect(assistants.first.reasoning, 'Только мысли без ответа');
      expect(assistants.first.text, isEmpty);
      final secondRequest = llm.requests.last.messages;
      expect(
        [
          for (final m in secondRequest)
            if (m.role == LlmRole.assistant) m,
        ],
        isEmpty,
        reason: 'empty assistant step must not be sent back',
      );
    },
  );

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
        broker.resolveApproval(
          request.id,
          const ApprovalDecision.deny(reason: 'not this time'),
        );
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
      expect(tool.text, contains('not this time'));
      final runs = await hub.chats.toolRunsForChat(chatId);
      expect(runs.single.status, ToolRunStatus.denied);
    },
  );

  test('allowTurn grants the exact command for the rest of the turn', () async {
    final chatId = await createChat(mode: PolicyMode.ask);
    final requested = <String>[];
    final approvals = broker.approvalRequests.listen((request) {
      requested.add(request.id);
      broker.resolveApproval(request.id, const ApprovalDecision.allowTurn());
    });
    addTearDown(approvals.cancel);
    final command = 'mkdir -p ${tmp.path}/granted';
    llm.script
      ..add([
        LlmCompleted(
          toolCalls: [
            _call('c1', ToolNames.runCommand, jsonEncode({'command': command})),
          ],
        ),
      ])
      ..add([
        LlmCompleted(
          toolCalls: [
            _call('c2', ToolNames.runCommand, jsonEncode({'command': command})),
          ],
        ),
      ])
      ..add([const LlmTextDelta('ok'), const LlmCompleted()]);

    await runTurn(hub.session(chatId), 'run twice');

    final runs = await hub.chats.toolRunsForChat(chatId);
    expect(runs, hasLength(2));
    expect(runs.every((run) => run.status == ToolRunStatus.done), isTrue);
    expect(requested, hasLength(1), reason: 'second call uses the grant');
    expect(Directory('${tmp.path}/granted').existsSync(), isTrue);
  });

  test(
    'ask mode: approved command stays one run that moves from waiting to done',
    () async {
      final chatId = await createChat(mode: PolicyMode.ask);
      final requested = <String>[];
      final approvals = broker.approvalRequests.listen((request) {
        requested.add(request.id);
        broker.resolveApproval(request.id, const ApprovalDecision.allowOnce());
      });
      addTearDown(approvals.cancel);
      llm.script
        ..add([
          LlmCompleted(
            toolCalls: [
              _call('c1', 'run_command', '{"command":"printf approved"}'),
            ],
          ),
        ])
        ..add([const LlmTextDelta('ok'), const LlmCompleted()]);

      await runTurn(hub.session(chatId), 'say approved');

      final runs = await hub.chats.toolRunsForChat(chatId);
      expect(runs, hasLength(1), reason: 'approval must not duplicate the run');
      expect(runs.single.id, requested.single);
      expect(runs.single.status, ToolRunStatus.done);
      expect(runs.single.outputText, contains('approved'));
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

  /// Ждёт, пока фоновая генерация заголовка сохранит результат.
  Future<Chat> waitForGeneratedTitle(String chatId) async {
    for (var i = 0; i < 500; i++) {
      final chat = await hub.chats.chat(chatId);
      if (chat != null && chat.titleSource != ChatTitleSource.none) {
        return chat;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('title was not generated');
  }

  group('chat title', () {
    test('generated title replaces the fallback and is sanitized', () async {
      final chatId = await createChat(titleSource: ChatTitleSource.none);
      llm
        ..titleReply = '"Счётчик от 1 до 40".'
        ..script.add([const LlmTextDelta('done'), const LlmCompleted()]);

      await runTurn(hub.session(chatId), 'запусти счётчик от 1 до 40');

      final chat = await waitForGeneratedTitle(chatId);
      expect(chat.title, 'Счётчик от 1 до 40');
      expect(chat.titleSource, ChatTitleSource.generated);
      expect(llm.titleRequests.single.skipReasoning, isTrue);
      expect(llm.titleRequests.single.maxTokens, ChatTitle.maxTokens);
    });

    test('empty title model setting falls back to the default model', () async {
      final chatId = await createChat(titleSource: ChatTitleSource.none);
      await hub.settings.write(SettingsRepository.keyTitleModel, '');
      llm
        ..titleReply = 'Заголовок'
        ..script.add([const LlmTextDelta('done'), const LlmCompleted()]);

      await runTurn(hub.session(chatId), 'задача');

      await waitForGeneratedTitle(chatId);
      expect(llm.titleRequests.single.model, 'fake/model');
    });

    test('configured title model is used for the title request', () async {
      final chatId = await createChat(titleSource: ChatTitleSource.none);
      await hub.settings.write(SettingsRepository.keyTitleModel, 'title/model');
      llm
        ..titleReply = 'Заголовок'
        ..script.add([const LlmTextDelta('done'), const LlmCompleted()]);

      await runTurn(hub.session(chatId), 'задача');

      await waitForGeneratedTitle(chatId);
      expect(llm.titleRequests.single.model, 'title/model');
    });

    test('unusable reply keeps the fallback and is logged', () async {
      final chatId = await createChat(titleSource: ChatTitleSource.none);
      llm
        ..titleReply = 'The user wants a short chat title for their request'
        ..script.add([const LlmTextDelta('done'), const LlmCompleted()]);
      final logged = Logger.root.onRecord.firstWhere(
        (r) => r.message.contains('unusable model reply'),
      );

      await runTurn(hub.session(chatId), 'запусти счётчик');

      await logged;
      final chat = await hub.chats.chat(chatId);
      expect(chat!.titleSource, ChatTitleSource.none);
      expect(chat.title, 'запусти счётчик');
    });
  });

  test(
    'opening a chat shows its history after one state change, not a sequence',
    () async {
      final chatId = await createChat();
      await hub.chats.insertMessage(
        ChatMessage(
          id: 'm1',
          chatId: chatId,
          seq: 1,
          role: MessageRole.user,
          createdAt: DateTime.now(),
          text: 'привет',
        ),
      );
      final bloc = ChatBloc(hub, LiveOutputBus(), drafts);
      addTearDown(bloc.close);
      final states = <ChatState>[];
      final sub = bloc.stream.listen(states.add);
      addTearDown(sub.cancel);

      bloc.add(ChatOpened(chatId));
      final opened = await bloc.stream.firstWhere(
        (s) => !s.loading && s.chat != null,
      );

      expect(opened.messages.single.text, 'привет');
      // Спиннер и один итог: промежуточные перерисовки открытия не нужны.
      expect(states.where((s) => !s.loading).length, 1);
      expect(states.length, lessThanOrEqualTo(2));
    },
  );

  test('a chat from the list is in the first state, so its header and composer never blank out', () async {
    final chatId = await createChat();
    final chat = (await hub.chats.chat(chatId))!;
    final bloc = ChatBloc(hub, LiveOutputBus(), drafts, seedChat: chat);
    addTearDown(bloc.close);

    // До любого события: шапка и композер уже есть, лента ждёт загрузки.
    expect(bloc.state.chat?.id, chatId);
    expect(bloc.state.loading, isTrue);

    final states = <ChatState>[];
    final sub = bloc.stream.listen(states.add);
    addTearDown(sub.cancel);
    bloc.add(ChatOpened(chatId));
    await bloc.stream.firstWhere((s) => !s.loading);

    // Ни одно промежуточное состояние не теряет чат: шапка не мигает.
    expect(states, isNotEmpty);
    expect(states.every((s) => s.chat?.id == chatId), isTrue);
  });

  test('switching to a chat not in the list keeps the previous chat settings until the new chat loads', () async {
    final first = await createChat();
    final second = await createChatWithId('chat-2');
    final bloc = ChatBloc(hub, LiveOutputBus(), drafts);
    addTearDown(bloc.close);
    bloc.add(ChatOpened(first));
    await bloc.stream.firstWhere((s) => !s.loading && s.chatId == first);

    bloc.add(ChatOpened(second));
    final switching = await bloc.stream.firstWhere((s) => s.chatId == second);
    // Пока грузится второй чат: композер и шапка ещё от первого, лента пустая и в загрузке.
    expect(switching.loading, isTrue);
    expect(switching.chat?.id, first);
    expect(switching.messages, isEmpty);

    final loaded = await bloc.stream.firstWhere((s) => !s.loading);
    expect(loaded.chat?.id, second);
  });

  test(
    'switching to a seeded chat shows its header and composer at once',
    () async {
      final first = await createChat();
      final second = await createChatWithId('chat-2');
      final secondChat = (await hub.chats.chat(second))!;
      final bloc = ChatBloc(hub, LiveOutputBus(), drafts);
      addTearDown(bloc.close);
      bloc.add(ChatOpened(first));
      await bloc.stream.firstWhere((s) => !s.loading && s.chatId == first);

      bloc.add(ChatOpened(second, seedChat: secondChat));
      final switching = await bloc.stream.firstWhere((s) => s.chatId == second);
      expect(switching.chat?.id, second);
      expect(switching.loading, isTrue);
      await bloc.stream.firstWhere((s) => !s.loading);
    },
  );

  test('a host added while the chat is open reaches the composer without switching chats', () async {
    final chatId = await createChat();
    final bloc = ChatBloc(hub, LiveOutputBus(), drafts);
    addTearDown(bloc.close);
    bloc.add(ChatOpened(chatId));
    await bloc.stream.firstWhere((s) => !s.loading);
    expect(bloc.state.hosts.map((h) => h.id), ['local']);

    // Подписка до записи: изменение приходит в блок, а не теряется между записью и подпиской.
    final withNewHost = bloc.stream.firstWhere((s) => s.hosts.length == 2);
    final now = DateTime.now();
    await hub.hosts.save(
      Host(
        id: 'ssh-1',
        name: 'Prod',
        kind: HostKind.ssh,
        address: 'example.com',
        username: 'deploy',
        createdAt: now,
        updatedAt: now,
      ),
    );
    final state = await withNewHost;
    expect(state.hosts.map((h) => h.id), ['local', 'ssh-1']);
    expect(state.chatId, chatId);
  });

  test('each chat keeps its own draft: switching away and back restores it and saves it to the database', () async {
    final first = await createChat();
    final second = await createChatWithId('chat-2');
    final bloc = ChatBloc(hub, LiveOutputBus(), drafts);
    addTearDown(bloc.close);
    bloc.add(ChatOpened(first));
    await bloc.stream.firstWhere((s) => !s.loading && s.chatId == first);

    bloc
      ..add(const ChatDraftEdited('черновик первого'))
      ..add(ChatOpened(second));
    final other = await bloc.stream.firstWhere(
      (s) => !s.loading && s.chatId == second,
    );
    // Во втором чате черновика ещё нет: поле пустое.
    expect(other.draft, isEmpty);

    bloc
      ..add(const ChatDraftEdited('черновик второго'))
      ..add(ChatOpened(first));
    final back = await bloc.stream.firstWhere(
      (s) => !s.loading && s.chatId == first,
    );
    expect(back.draft, 'черновик первого');

    await drafts.flush();
    expect((await hub.chats.chat(first))!.draft.text, 'черновик первого');
    expect((await hub.chats.chat(second))!.draft.text, 'черновик второго');
  });

  test('attachments of a draft belong to their chat too', () async {
    final first = await createChat();
    final second = await createChatWithId('chat-2');
    final bloc = ChatBloc(hub, LiveOutputBus(), drafts);
    addTearDown(bloc.close);
    bloc.add(ChatOpened(first));
    await bloc.stream.firstWhere((s) => !s.loading && s.chatId == first);

    bloc
      ..add(
        const ChatAttachmentsAdded([
          AttachmentRef(
            name: 'notes.txt',
            mode: AttachmentMode.attach,
            content: 'заметка',
            sizeBytes: 7,
          ),
        ]),
      )
      ..add(ChatOpened(second));
    final other = await bloc.stream.firstWhere(
      (s) => !s.loading && s.chatId == second,
    );
    expect(other.attachments, isEmpty);

    bloc.add(ChatOpened(first));
    final back = await bloc.stream.firstWhere(
      (s) => !s.loading && s.chatId == first,
    );
    expect(back.attachments.single.name, 'notes.txt');

    await drafts.flush();
    final saved = (await hub.chats.chat(first))!.draft;
    expect(saved.attachments.single.content, 'заметка');
  });

  test('sending clears the draft of the chat right away', () async {
    final chatId = await createChat();
    llm.script.add([const LlmTextDelta('ок'), const LlmCompleted()]);
    final bloc = ChatBloc(hub, LiveOutputBus(), drafts);
    addTearDown(bloc.close);
    bloc.add(ChatOpened(chatId));
    await bloc.stream.firstWhere((s) => !s.loading);

    bloc.add(const ChatDraftEdited('вопрос'));
    final finished = hub.allEvents.firstWhere((e) => e is AgentTurnFinished);
    bloc.add(const ChatSubmitted('вопрос'));
    await finished;

    expect(drafts.of(chatId).isEmpty, isTrue);
    await drafts.flush();
    expect((await hub.chats.chat(chatId))!.draft.isEmpty, isTrue);
  });

  test('a new chat opens ready: the default model is selected at once, without a loading state', () async {
    final bloc = ChatBloc(hub, LiveOutputBus(), drafts);
    addTearDown(bloc.close);
    final states = <ChatState>[];
    final sub = bloc.stream.listen(states.add);
    addTearDown(sub.cancel);

    bloc.add(const ChatDraftOpened());
    await bloc.stream.firstWhere((s) => s.unsaved);

    expect(bloc.state.effectiveModelId, 'fake/model');
    expect(bloc.state.hosts.map((h) => h.id), ['local']);
    // Ни одного состояния с загрузкой: композер и шапка сразу готовы, без спиннера и скелета.
    expect(states.any((s) => s.loading), isFalse);
  });

  test('a new chat is ready in the very first state: no read is awaited before the body appears', () {
    final bloc = ChatBloc(hub, LiveOutputBus(), drafts);
    addTearDown(bloc.close);

    // Сразу после создания блока (без await): чат, модель и хосты уже в состоянии первого кадра.
    expect(bloc.state.chatId, isNotNull);
    expect(bloc.state.chat, isNotNull);
    expect(bloc.state.unsaved, isTrue);
    expect(bloc.state.effectiveModelId, 'fake/model');
  });

  test('a new chat stays out of the database until the first send, then is saved and reported', () async {
    final created = <String>[];
    final bloc = ChatBloc(
      hub,
      LiveOutputBus(),
      drafts,
      onChatCreated: created.add,
    );
    addTearDown(bloc.close);
    bloc.add(const ChatDraftOpened());
    await bloc.stream.firstWhere((s) => s.unsaved);
    final id = bloc.state.chatId!;

    expect(await hub.chats.chat(id), isNull);
    expect(await hub.chats.watchChats().first, isEmpty);

    llm.script.add([const LlmTextDelta('ок'), const LlmCompleted()]);
    final finished = hub.allEvents.firstWhere((e) => e is AgentTurnFinished);
    bloc.add(const ChatSubmitted('вопрос'));
    await finished;

    expect(bloc.state.unsaved, isFalse);
    expect(created, [id]);
    expect((await hub.chats.chat(id))!.id, id);
    expect((await hub.chats.messages(id)).first.text, 'вопрос');
  });

  test('a new chat takes the draft of the chat it was opened from and clears that chat', () async {
    final first = await createChat();
    final bloc = ChatBloc(hub, LiveOutputBus(), drafts);
    addTearDown(bloc.close);
    bloc.add(ChatOpened(first));
    await bloc.stream.firstWhere((s) => !s.loading);
    drafts.update(first, const ChatDraft(text: 'черновик'));

    bloc.add(const ChatDraftOpened());
    await bloc.stream.firstWhere((s) => s.unsaved);
    final fresh = bloc.state.chatId!;

    expect(fresh, isNot(first));
    expect(bloc.state.draft, 'черновик');
    expect(drafts.of(fresh).text, 'черновик');
    expect(drafts.of(first).isEmpty, isTrue);
    // Перенос сохраняется в БД сразу; новый чат в БД не появился.
    expect((await hub.chats.chat(first))!.draft.isEmpty, isTrue);
    expect(await hub.chats.chat(fresh), isNull);
  });

  /// Виртуальный Host с его ФС и чатом на нём. Политика yolo: подтверждения не мешают проверке.
  Future<String> createVirtualChat() async {
    final now = DateTime.now();
    final sandbox = Host(
      id: 'sandbox',
      name: 'Sandbox',
      kind: HostKind.virtual,
      createdAt: now,
      updatedAt: now,
    );
    await HostRepository(db, MemorySecretStore()).save(sandbox);
    await VirtualHostProvisioner(db).provision(sandbox);
    await hub.chats.saveChat(
      Chat(
        id: 'sandbox-chat',
        hostId: sandbox.id,
        title: 'sandbox',
        createdAt: now,
        updatedAt: now,
        policyMode: PolicyMode.yolo,
        model: 'fake/model',
      ),
    );
    return 'sandbox-chat';
  }

  test(
    'run_command on a virtual host writes and reads its own file system',
    () async {
      final chatId = await createVirtualChat();
      llm.script
        ..add([
          LlmCompleted(
            toolCalls: [
              _call(
                'c1',
                'run_command',
                '{"command":"echo hi > note.txt && cat note.txt"}',
              ),
            ],
          ),
        ])
        ..add([const LlmTextDelta('done'), const LlmCompleted()]);

      await runTurn(hub.session(chatId), 'write a note');

      final tool = (await hub.chats.messages(chatId))
          .firstWhere((m) => m.role == MessageRole.tool);
      expect(tool.text, contains('status: done'));
      expect(tool.text, contains('hi'));
    },
  );

  test('virtual host run_command receives stdin', () async {
    final chatId = await createVirtualChat();
    llm.script
      ..add([
        LlmCompleted(
          toolCalls: [
            _call(
              'stdin',
              ToolNames.runCommand,
              jsonEncode({'command': 'cat', 'stdin': 'virtual stdin'}),
            ),
          ],
        ),
      ])
      ..add([const LlmTextDelta('done'), const LlmCompleted()]);

    await runTurn(hub.session(chatId), 'read stdin');

    final tool = (await hub.chats.messages(chatId))
        .firstWhere((message) => message.role == MessageRole.tool);
    expect(tool.text, contains('status: done'));
    expect(tool.text, contains('virtual stdin'));
  });

  test('background run_command on a virtual host is refused and the model is told why', () async {
    final chatId = await createVirtualChat();
    llm.script
      ..add([
        LlmCompleted(
          toolCalls: [
            _call(
              'c1',
              'run_command',
              '{"command":"sleep 5","background":true}',
            ),
          ],
        ),
      ])
      ..add([const LlmTextDelta('ok'), const LlmCompleted()]);

    await runTurn(hub.session(chatId), 'wait in background');

    final tool = (await hub.chats.messages(chatId))
        .firstWhere((m) => m.role == MessageRole.tool);
    expect(tool.text, contains('background is not supported'));
    expect(await hub.chats.toolRunsForChat(chatId), isEmpty);
  });

  test(
    'write then read of the same file sees the write, in call order',
    () async {
      final chatId = await createVirtualChat();
      llm.script
        ..add([
          LlmCompleted(
            toolCalls: [
              _call(
                'w',
                'write_file',
                jsonEncode({
                  'path': '/home/agent/note.txt',
                  'content': 'hello from write',
                }),
              ),
              _call(
                'r',
                'read_file',
                jsonEncode({'path': '/home/agent/note.txt'}),
              ),
              _call(
                'o',
                'read_file',
                jsonEncode({'path': '/home/agent/other.txt'}),
              ),
            ],
          ),
        ])
        ..add([const LlmTextDelta('done'), const LlmCompleted()]);

      await runTurn(hub.session(chatId), 'write and check');

      final tools = [
        for (final message in await hub.chats.messages(chatId))
          if (message.role == MessageRole.tool) message,
      ];
      expect(
        [for (final message in tools) message.toolCallId],
        ['w', 'r', 'o'],
      );
      expect(tools[1].text, contains('hello from write'));
    },
  );

  test('file tools create, copy, move, find, stat and delete a file', () async {
    final chatId = await createChat();
    final dir = '${tmp.path}/fileops';
    llm.script
      ..add([
        LlmCompleted(
          toolCalls: [
            _call('mkdir', ToolNames.makeDir, jsonEncode({'path': dir})),
          ],
        ),
      ])
      ..add([
        LlmCompleted(
          toolCalls: [
            _call(
              'write',
              ToolNames.writeFile,
              jsonEncode({'path': '$dir/a.txt', 'content': 'alpha'}),
            ),
          ],
        ),
      ])
      ..add([
        LlmCompleted(
          toolCalls: [
            _call(
              'patch',
              ToolNames.applyPatch,
              jsonEncode({
                'path': '$dir/a.txt',
                'patch': '@@ -1,1 +1,1 @@\n-alpha\n+beta',
              }),
            ),
          ],
        ),
      ])
      ..add([
        LlmCompleted(
          toolCalls: [
            _call(
              'copy',
              ToolNames.copyPath,
              jsonEncode({'from': '$dir/a.txt', 'to': '$dir/b.txt'}),
            ),
          ],
        ),
      ])
      ..add([
        LlmCompleted(
          toolCalls: [
            _call(
              'move',
              ToolNames.movePath,
              jsonEncode({'from': '$dir/b.txt', 'to': '$dir/c.txt'}),
            ),
          ],
        ),
      ])
      ..add([
        LlmCompleted(
          toolCalls: [
            _call(
              'glob',
              ToolNames.glob,
              jsonEncode({'pattern': '*.txt', 'path': dir}),
            ),
          ],
        ),
      ])
      ..add([
        LlmCompleted(
          toolCalls: [
            _call(
              'stat',
              ToolNames.statPath,
              jsonEncode({'path': '$dir/c.txt'}),
            ),
          ],
        ),
      ])
      ..add([
        LlmCompleted(
          toolCalls: [
            _call(
              'delete',
              ToolNames.deleteFile,
              jsonEncode({'path': '$dir/c.txt'}),
            ),
          ],
        ),
      ])
      ..add([const LlmTextDelta('done'), const LlmCompleted()]);

    await runTurn(hub.session(chatId), 'file operations');

    expect(File('$dir/a.txt').readAsStringSync(), 'beta');
    expect(File('$dir/b.txt').existsSync(), isFalse);
    expect(File('$dir/c.txt').existsSync(), isFalse);
    final messages = await hub.chats.messages(chatId);
    final tools = [
      for (final message in messages)
        if (message.role == MessageRole.tool) message,
    ];
    expect(
      [for (final message in tools) message.toolCallId],
      ['mkdir', 'write', 'patch', 'copy', 'move', 'glob', 'stat', 'delete'],
    );
    final runs = await hub.chats.toolRunsForMessages([
      for (final message in messages) message.id,
    ]);
    expect(runs.where((run) => run.status != ToolRunStatus.done), isEmpty);
  });

  test('run_command accepts stdin, timeout and pager defaults', () async {
    final chatId = await createChat();
    llm.script
      ..add([
        LlmCompleted(
          toolCalls: [
            _call(
              'stdin',
              ToolNames.runCommand,
              jsonEncode({'command': 'cat', 'stdin': 'hello from stdin'}),
            ),
          ],
        ),
      ])
      ..add([
        LlmCompleted(
          toolCalls: [
            _call(
              'pager',
              ToolNames.runCommand,
              jsonEncode({'command': r'printf "%s" "$PAGER"'}),
            ),
          ],
        ),
      ])
      ..add([
        LlmCompleted(
          toolCalls: [
            _call(
              'timeout',
              ToolNames.runCommand,
              jsonEncode({'command': 'echo no', 'timeout': 99999}),
            ),
          ],
        ),
      ])
      ..add([
        LlmCompleted(
          toolCalls: [
            _call(
              'short-timeout',
              ToolNames.runCommand,
              jsonEncode({'command': 'sleep 2', 'timeout': 1}),
            ),
          ],
        ),
      ])
      ..add([const LlmTextDelta('done'), const LlmCompleted()]);

    await runTurn(hub.session(chatId), 'check run options');

    final tools = [
      for (final message in await hub.chats.messages(chatId))
        if (message.role == MessageRole.tool) message,
    ];
    expect(tools.first.text, contains('hello from stdin'));
    expect(tools[1].text, contains('cat'));
    expect(tools[2].text, contains('timeout'));
    expect(tools[3].text, contains('timedOut'));
  });

  test(
    'forkChat copies history and state without changing the source',
    () async {
      final chatId = await createChat();
      final now = DateTime.now();
      await hub.chats.insertMessage(
        ChatMessage(
          id: 'u1',
          chatId: chatId,
          seq: 1,
          role: MessageRole.user,
          createdAt: now,
          text: 'original question',
        ),
      );
      await hub.chats.insertMessage(
        ChatMessage(
          id: 'a1',
          chatId: chatId,
          seq: 2,
          role: MessageRole.assistant,
          createdAt: now,
          text: 'original answer',
        ),
      );
      await hub.chats.saveToolRun(
        ToolRun(
          id: 'r1',
          chatId: chatId,
          messageId: 'a1',
          toolName: ToolNames.readFile,
          argsJson: '{"path":"a.txt"}',
          status: ToolRunStatus.done,
          startedAt: now,
          finishedAt: now,
          resultPreview: 'text',
        ),
      );
      final source = (await hub.chats.chat(chatId))!;
      await hub.state.mutate(source, (revision) {
        revision.goal = 'remembered goal';
      });

      final forked = await hub.forkChat(chatId, title: 'Copy of test');

      expect(forked.id, isNot(chatId));
      expect(forked.title, 'Copy of test');
      final copied = await hub.chats.messages(forked.id);
      expect(
        [for (final message in copied) message.text],
        ['original question', 'original answer'],
      );
      expect((await hub.state.current(forked)).goal, 'remembered goal');
      final copiedRuns = await hub.chats.toolRunsForChat(forked.id);
      expect(copiedRuns, hasLength(1));
      expect(copiedRuns.single.messageId, copied[1].id);

      expect((await hub.chats.messages(chatId)).length, 2);
      final sourceAfter = (await hub.chats.chat(chatId))!;
      expect((await hub.state.current(sourceAfter)).goal, 'remembered goal');
    },
  );

  test('forkChat can stop at a completed answer', () async {
    final chatId = await createChat();
    final now = DateTime.now();
    final messages = [
      ('u1', MessageRole.user, 'first question'),
      ('a1', MessageRole.assistant, 'first answer'),
      ('u2', MessageRole.user, 'second question'),
      ('a2', MessageRole.assistant, 'second answer'),
    ];
    for (var i = 0; i < messages.length; i++) {
      final (id, role, text) = messages[i];
      await hub.chats.insertMessage(
        ChatMessage(
          id: id,
          chatId: chatId,
          seq: i + 1,
          role: role,
          createdAt: now,
          text: text,
        ),
      );
    }

    final forked = await hub.forkChat(
      chatId,
      untilMessageId: 'a1',
      title: 'First branch',
    );
    final copied = await hub.chats.messages(forked.id);

    expect(
      [for (final message in copied) message.text],
      ['first question', 'first answer'],
    );
    expect(copied.map((message) => message.role), [
      MessageRole.user,
      MessageRole.assistant,
    ]);
  });

  test('list_runs and read_run_output expose stored output by pages', () async {
    final chatId = await createChat();
    final now = DateTime.now();
    await hub.chats.saveToolRun(
      ToolRun(
        id: 'seed',
        chatId: chatId,
        messageId: 'assistant',
        toolName: ToolNames.runCommand,
        argsJson: '{}',
        command: 'printf abcdef',
        status: ToolRunStatus.done,
        startedAt: now,
        finishedAt: now,
        outputText: 'abcdefghij',
      ),
    );
    llm.script
      ..add([
        LlmCompleted(toolCalls: [_call('list', ToolNames.listRuns, '{}')]),
      ])
      ..add([
        LlmCompleted(
          toolCalls: [
            _call(
              'read',
              ToolNames.readRunOutput,
              jsonEncode({'run_id': 'seed', 'limit': 5}),
            ),
          ],
        ),
      ])
      ..add([const LlmTextDelta('done'), const LlmCompleted()]);

    await runTurn(hub.session(chatId), 'inspect runs');

    final tools = [
      for (final message in await hub.chats.messages(chatId))
        if (message.role == MessageRole.tool) message,
    ];
    expect(tools.first.text, contains('seed | done'));
    expect(tools[1].text, contains('total: 10 chars'));
    expect(tools[1].text, contains('offset=5'));
    expect(tools[1].text, contains('abcde'));
  });

  Future<void> seedWaiting({
    required String chatId,
    required ToolRunStatus status,
    required String toolName,
    required String args,
    required String callId,
    String? command,
    String? pendingCard,
    String? eventText,
  }) async {
    final now = DateTime.now();
    await hub.chats.insertMessage(
      ChatMessage(
        id: 'user-1',
        chatId: chatId,
        seq: 1,
        role: MessageRole.user,
        createdAt: now,
        text: 'do it',
      ),
    );
    await hub.chats.insertMessage(
      ChatMessage(
        id: 'assistant-1',
        chatId: chatId,
        seq: 2,
        role: MessageRole.assistant,
        createdAt: now,
        toolCalls: [ToolCallRef(id: callId, name: toolName, arguments: args)],
      ),
    );
    if (eventText != null) {
      await hub.chats.insertMessage(
        ChatMessage(
          id: 'event-1',
          chatId: chatId,
          seq: 3,
          role: MessageRole.event,
          createdAt: now,
          text: eventText,
        ),
      );
    }
    await hub.chats.saveToolRun(
      ToolRun(
        id: 'run-1',
        chatId: chatId,
        messageId: 'assistant-1',
        toolName: toolName,
        argsJson: args,
        command: command,
        status: status,
        startedAt: now,
        toolCallId: callId,
        pendingCard: pendingCard,
      ),
    );
  }

  test(
    'an unanswered question is shown again when the chat is opened',
    () async {
      final chatId = await createChat();
      const args = '{"question":"Which color?"}';
      await seedWaiting(
        chatId: chatId,
        status: ToolRunStatus.waitingUser,
        toolName: 'ask_user',
        args: args,
        callId: 'call-1',
        eventText: 'a command was interrupted',
      );
      final session = hub.session(chatId);

      await session.restoreUnanswered();

      final question = broker.pendingQuestions(chatId).single;
      expect(question.text, 'Which color?');
      expect(session.isRunning, isTrue);

      llm.script.add([const LlmTextDelta('thanks'), const LlmCompleted()]);
      final finished = session.events.firstWhere((e) => e is AgentTurnFinished);
      broker.answer(question.id, 'blue');
      await finished;

      expect(broker.pendingQuestions(chatId), isEmpty);
      final runs = await hub.chats.toolRunsForChat(chatId);
      expect(runs.single.status, ToolRunStatus.done);
      final tool = (await hub.chats.messages(chatId))
          .firstWhere((m) => m.role == MessageRole.tool);
      expect(tool.text, 'User answered: blue');
      expect(tool.toolCallId, 'call-1');
      final sent = llm.requests.single.messages;
      final assistant = sent.indexWhere(
        (m) => m.role == LlmRole.assistant && m.toolCalls.isNotEmpty,
      );
      expect(sent[assistant + 1].role, LlmRole.tool);
      expect(sent[assistant + 1].content, contains('blue'));
      expect(
        sent.indexWhere((m) => m.content.contains('a command was interrupted')),
        greaterThan(assistant + 1),
      );

      await session.restoreUnanswered();
      expect(await hub.chats.waitingRuns(chatId), isEmpty);
      expect(session.isRunning, isFalse);
    },
  );

  test(
    'stopping a restored question records the answer and does not ask again',
    () async {
      final chatId = await createChat();
      await seedWaiting(
        chatId: chatId,
        status: ToolRunStatus.waitingUser,
        toolName: 'ask_user',
        args: '{"question":"Still there?"}',
        callId: 'call-1',
      );
      final session = hub.session(chatId);
      await session.restoreUnanswered();
      expect(broker.pendingQuestions(chatId), hasLength(1));

      final finished = session.events.firstWhere((e) => e is AgentTurnFinished);
      await session.stop();
      await finished;

      expect(broker.pendingQuestions(chatId), isEmpty);
      expect(llm.requests, isEmpty);
      final runs = await hub.chats.toolRunsForChat(chatId);
      expect(runs.single.status, ToolRunStatus.done);
      final tool = (await hub.chats.messages(chatId))
          .firstWhere((m) => m.role == MessageRole.tool);
      expect(tool.text, contains('did not answer'));

      await session.restoreUnanswered();
      expect(await hub.chats.waitingRuns(chatId), isEmpty);
    },
  );

  test('a restored approval card runs only after the user allows it', () async {
    final chatId = await createChat();
    const args = '{"command":"printf approved"}';
    await seedWaiting(
      chatId: chatId,
      status: ToolRunStatus.waitingApproval,
      toolName: 'run_command',
      args: args,
      callId: 'call-1',
      command: 'printf approved',
      pendingCard: const PendingCard(
        summary: 'printf approved',
        reason: 'needs approval',
      ).encode(),
    );
    final session = hub.session(chatId);
    await session.restoreUnanswered();
    final request = broker.pendingApprovals(chatId).single;
    expect(request.summary, 'printf approved');
    expect(request.reason, 'needs approval');

    llm.script.add([const LlmTextDelta('ran'), const LlmCompleted()]);
    final finished = session.events.firstWhere((e) => e is AgentTurnFinished);
    broker.resolveApproval(request.id, const ApprovalDecision.allowOnce());
    await finished;

    expect(broker.pendingApprovals(chatId), isEmpty);
    final runs = await hub.chats.toolRunsForChat(chatId);
    expect(runs, hasLength(1));
    expect(runs.single.status, ToolRunStatus.done);
    expect(runs.single.outputText, contains('approved'));
    expect(runs.single.pendingCard, isNull);
  });

  test('denying a restored approval is a final answer', () async {
    final chatId = await createChat();
    const args = '{"command":"printf should-not-run"}';
    await seedWaiting(
      chatId: chatId,
      status: ToolRunStatus.waitingApproval,
      toolName: 'run_command',
      args: args,
      callId: 'call-1',
      command: 'printf should-not-run',
      pendingCard: const PendingCard(
        summary: 'printf should-not-run',
        reason: 'needs approval',
      ).encode(),
    );
    final session = hub.session(chatId);
    await session.restoreUnanswered();
    final request = broker.pendingApprovals(chatId).single;

    llm.script.add([const LlmTextDelta('stopped'), const LlmCompleted()]);
    final finished = session.events.firstWhere((e) => e is AgentTurnFinished);
    broker.resolveApproval(request.id, const ApprovalDecision.deny());
    await finished;

    expect(broker.pendingApprovals(chatId), isEmpty);
    final tool = (await hub.chats.messages(chatId))
        .firstWhere((m) => m.role == MessageRole.tool);
    expect(tool.text, contains('rejected'));
    final runs = await hub.chats.toolRunsForChat(chatId);
    expect(runs.single.status, ToolRunStatus.denied);
    expect(runs.single.outputText, isNull);

    await session.restoreUnanswered();
    expect(await hub.chats.waitingRuns(chatId), isEmpty);
    expect(session.isRunning, isFalse);
  });

  test('several questions in one step are asked together', () async {
    final chatId = await createChat();
    llm.script
      ..add([
        LlmCompleted(
          toolCalls: [
            _call('c1', 'ask_user', '{"question":"first?"}'),
            _call('c2', 'ask_user', '{"question":"second?"}'),
            _call('c3', 'ask_user', '{"question":"third?"}'),
          ],
        ),
      ])
      ..add([const LlmTextDelta('all three'), const LlmCompleted()]);
    final session = hub.session(chatId);
    final seen = <UserQuestion>[];
    final questions = broker.questions.listen(seen.add);
    addTearDown(questions.cancel);
    final finished = session.events.firstWhere((e) => e is AgentTurnFinished);
    await session.submit('ask three');
    await waitUntil(() => seen.length == 3);

    expect(seen.map((question) => question.text).toSet(), {
      'first?',
      'second?',
      'third?',
    });
    expect(broker.pendingQuestions(chatId), hasLength(3));

    // Ответы приходят не в порядке вызовов: в ленту результаты всё равно ложатся по нему.
    String idOf(String text) =>
        seen.firstWhere((question) => question.text == text).id;
    broker
      ..answer(idOf('third?'), 'three')
      ..answer(idOf('second?'), 'two')
      ..answer(idOf('first?'), 'one');
    await finished;

    final tools = [
      for (final message in await hub.chats.messages(chatId))
        if (message.role == MessageRole.tool) message,
    ];
    expect(
      [for (final message in tools) message.toolCallId],
      ['c1', 'c2', 'c3'],
    );
    expect(tools.map((message) => message.text), [
      'User answered: one',
      'User answered: two',
      'User answered: three',
    ]);
  });

  test(
    'restart on the second question also asks the third without waiting',
    () async {
      final chatId = await createChat();
      final now = DateTime.now();
      const firstArgs = '{"question":"first?"}';
      const secondArgs = '{"question":"second?"}';
      const thirdArgs = '{"question":"third?"}';
      await hub.chats.insertMessage(
        ChatMessage(
          id: 'user-1',
          chatId: chatId,
          seq: 1,
          role: MessageRole.user,
          createdAt: now,
          text: 'ask three',
        ),
      );
      await hub.chats.insertMessage(
        ChatMessage(
          id: 'assistant-1',
          chatId: chatId,
          seq: 2,
          role: MessageRole.assistant,
          createdAt: now,
          toolCalls: [
            const ToolCallRef(id: 'c1', name: 'ask_user', arguments: firstArgs),
            const ToolCallRef(
              id: 'c2',
              name: 'ask_user',
              arguments: secondArgs,
            ),
            const ToolCallRef(id: 'c3', name: 'ask_user', arguments: thirdArgs),
          ],
        ),
      );
      await hub.chats.insertMessage(
        ChatMessage(
          id: 'tool-1',
          chatId: chatId,
          seq: 3,
          role: MessageRole.tool,
          createdAt: now,
          text: 'User answered: one',
          toolCallId: 'c1',
        ),
      );
      await hub.chats.saveToolRun(
        ToolRun(
          id: 'run-1',
          chatId: chatId,
          messageId: 'assistant-1',
          toolName: 'ask_user',
          argsJson: firstArgs,
          status: ToolRunStatus.done,
          startedAt: now,
          finishedAt: now,
          toolCallId: 'c1',
          resultPreview: 'User answered: one',
        ),
      );
      await hub.chats.saveToolRun(
        ToolRun(
          id: 'run-2',
          chatId: chatId,
          messageId: 'assistant-1',
          toolName: 'ask_user',
          argsJson: secondArgs,
          status: ToolRunStatus.waitingUser,
          startedAt: now.add(const Duration(seconds: 1)),
          toolCallId: 'c2',
        ),
      );

      final seen = <String>[];
      final questions = broker.questions.listen(
        (question) => seen.add(question.text),
      );
      addTearDown(questions.cancel);
      final session = hub.session(chatId);
      await session.restoreUnanswered();
      await waitUntil(() => seen.contains('third?'));
      expect(broker.pendingQuestions(chatId).map((q) => q.text).toSet(), {
        'second?',
        'third?',
      });
      final waiting = await hub.chats.waitingRuns(chatId);
      expect(waiting.map((run) => run.toolCallId).toSet(), {'c2', 'c3'});

      llm.script.add([const LlmTextDelta('done'), const LlmCompleted()]);
      final finished = session.events.firstWhere((e) => e is AgentTurnFinished);
      final pending = broker.pendingQuestions(chatId);
      broker
        ..answer(
          pending.firstWhere((question) => question.text == 'third?').id,
          'three',
        )
        ..answer(
          pending.firstWhere((question) => question.text == 'second?').id,
          'two',
        );
      await finished;

      final tools = [
        for (final message in await hub.chats.messages(chatId))
          if (message.role == MessageRole.tool) message,
      ];
      expect(
        [for (final message in tools) message.toolCallId],
        ['c1', 'c2', 'c3'],
      );
      expect(tools.map((message) => message.text), [
        'User answered: one',
        'User answered: two',
        'User answered: three',
      ]);
      expect(await hub.chats.waitingRuns(chatId), isEmpty);
      final sent = llm.requests.single.messages;
      final assistant = sent.indexWhere(
        (m) => m.role == LlmRole.assistant && m.toolCalls.length == 3,
      );
      expect(
        [for (var i = 1; i <= 3; i++) sent[assistant + i].toolCallId],
        ['c1', 'c2', 'c3'],
      );
    },
  );

  test('after restart independent work continues and the card appears only when the chat opens', () async {
    final chatId = await createVirtualChat();
    final chat = (await hub.chats.chat(chatId))!;
    await hub.chats.saveChat(chat.copyWith(policyMode: PolicyMode.ask));
    final now = DateTime.now();
    await hub.chats.saveChat(
      Chat(
        id: 'idle',
        hostId: 'local',
        title: 'idle',
        createdAt: now,
        updatedAt: now,
      ),
    );
    final host = (await hub.hosts.byId('sandbox'))!;
    final seeded = await captureOp(
      hub.runtimes.forHost(host),
      const WriteFileOp(
        '/home/agent/other.txt',
        backupPath: '/home/agent/other.txt.pw-bak-seed',
      ),
      stdin: Uint8List.fromList(utf8.encode('present\n')),
    );
    expect(seeded.ok, isTrue);
    const otherArgs = '{"path":"/home/agent/other.txt"}';
    const commandArgs = '{"command":"ls"}';
    const writeArgs =
        '{"path":"/home/agent/note.txt","content":"hello from write"}';
    const noteArgs = '{"path":"/home/agent/note.txt"}';
    await hub.chats.insertMessage(
      ChatMessage(
        id: 'm',
        chatId: chatId,
        seq: 1,
        role: MessageRole.assistant,
        createdAt: now,
        toolCalls: const [
          ToolCallRef(id: 'other', name: 'read_file', arguments: otherArgs),
          ToolCallRef(id: 'cmd', name: 'run_command', arguments: commandArgs),
          ToolCallRef(id: 'write', name: 'write_file', arguments: writeArgs),
          ToolCallRef(id: 'note', name: 'read_file', arguments: noteArgs),
        ],
      ),
    );
    await hub.chats.saveToolRun(
      ToolRun(
        id: 'run-cmd',
        chatId: chatId,
        messageId: 'm',
        toolName: 'run_command',
        argsJson: commandArgs,
        command: 'ls',
        status: ToolRunStatus.running,
        startedAt: now,
        toolCallId: 'cmd',
      ),
    );
    await hub.chats.saveToolRun(
      ToolRun(
        id: 'run-write',
        chatId: chatId,
        messageId: 'm',
        toolName: 'write_file',
        argsJson: writeArgs,
        command: 'write /home/agent/note.txt',
        status: ToolRunStatus.waitingApproval,
        startedAt: now,
        toolCallId: 'write',
        pendingCard: const PendingCard(
          summary: 'write /home/agent/note.txt',
          reason: 'write operation',
        ).encode(),
      ),
    );

    final recovered = await StartupRecovery(
      hub.chats,
      hub.logs,
      hub.settings,
    ).run(closedText: 'closed');
    expect(recovered, 1);

    await hub.resumeAfterRestart();

    // Старт не показывает карточку и не зовёт модель: запись ещё ждёт открытия чата.
    expect(broker.pendingApprovals(chatId), isEmpty);
    expect(broker.pendingQuestions(chatId), isEmpty);
    expect(hub.runningChatIds, {chatId});
    expect(llm.requests, isEmpty);

    final early = await waitForToolIds(chatId, ['other', 'cmd']);
    expect(early.first.text, contains('present'));
    expect(early[1].text, contains('interrupted'));
    final runs = await hub.chats.toolRunsForChat(chatId);
    expect(runs.where((run) => run.toolName == 'run_command'), hasLength(1));
    expect(
      runs.singleWhere((run) => run.id == 'run-cmd').status,
      ToolRunStatus.interrupted,
    );
    expect(
      runs.singleWhere((run) => run.id == 'run-write').status,
      ToolRunStatus.waitingApproval,
    );
    expect(runs.where((run) => run.toolCallId == 'note'), isEmpty);
    expect(
      runs.singleWhere((run) => run.toolCallId == 'other').status,
      ToolRunStatus.done,
    );

    await hub.session(chatId).restoreUnanswered();

    expect(broker.pendingApprovals(chatId).map((card) => card.id), [
      'run-write',
    ]);
    expect(
      (await hub.chats.toolRunsForChat(chatId))
          .where((run) => run.toolCallId == 'note'),
      isEmpty,
    );

    llm.script.add([const LlmTextDelta('done'), const LlmCompleted()]);
    final finished = hub
        .session(chatId)
        .events
        .firstWhere((event) => event is AgentTurnFinished);
    broker.resolveApproval('run-write', const ApprovalDecision.allowOnce());
    final event = await finished;

    expect((event as AgentTurnFinished).end, TurnEnd.completed);
    final tools = [
      for (final message in await hub.chats.messages(chatId))
        if (message.role == MessageRole.tool) message,
    ];
    expect(
      [for (final message in tools) message.toolCallId],
      ['other', 'cmd', 'write', 'note'],
    );
    expect(tools.last.text, contains('hello from write'));
    expect(
      (await hub.chats.toolRunsForChat(chatId))
          .singleWhere((run) => run.id == 'run-write')
          .status,
      ToolRunStatus.done,
    );
    expect(await hub.chats.waitingRuns(chatId), isEmpty);
    expect(llm.requests, hasLength(1));
    expect(hub.runningChatIds, isEmpty);
  });

  test('a card alone is not resumed until the chat opens', () async {
    final chatId = await createChat(mode: PolicyMode.ask);
    final now = DateTime.now();
    const askArgs = '{"question":"color?"}';
    await hub.chats.insertMessage(
      ChatMessage(
        id: 'm',
        chatId: chatId,
        seq: 1,
        role: MessageRole.assistant,
        createdAt: now,
        toolCalls: const [
          ToolCallRef(id: 'ask', name: 'ask_user', arguments: askArgs),
        ],
      ),
    );
    await hub.chats.saveToolRun(
      ToolRun(
        id: 'run-ask',
        chatId: chatId,
        messageId: 'm',
        toolName: 'ask_user',
        argsJson: askArgs,
        status: ToolRunStatus.waitingUser,
        startedAt: now,
        toolCallId: 'ask',
      ),
    );

    await hub.resumeAfterRestart();

    expect(broker.pendingQuestions(chatId), isEmpty);
    expect(hub.runningChatIds, isEmpty);
    expect(llm.requests, isEmpty);

    final session = hub.session(chatId);
    await session.restoreUnanswered();
    expect(broker.pendingQuestions(chatId).map((question) => question.id), [
      'run-ask',
    ]);

    final finished = session.events.firstWhere(
      (event) => event is AgentTurnFinished,
    );
    await session.stop();
    final event = await finished;
    expect((event as AgentTurnFinished).end, TurnEnd.stopped);
    expect(
      (await hub.chats.toolRunsForChat(chatId))
          .singleWhere((run) => run.id == 'run-ask')
          .status,
      ToolRunStatus.done,
    );
  });

  test(
    'stop before the chat opens closes a parked card without showing it',
    () async {
      final chatId = await createVirtualChat();
      final now = DateTime.now();
      final host = (await hub.hosts.byId('sandbox'))!;
      final seeded = await captureOp(
        hub.runtimes.forHost(host),
        const WriteFileOp(
          '/home/agent/other.txt',
          backupPath: '/home/agent/other.txt.pw-bak-seed',
        ),
        stdin: Uint8List.fromList(utf8.encode('present\n')),
      );
      expect(seeded.ok, isTrue);
      const otherArgs = '{"path":"/home/agent/other.txt"}';
      const askArgs = '{"question":"color?"}';
      await hub.chats.insertMessage(
        ChatMessage(
          id: 'm',
          chatId: chatId,
          seq: 1,
          role: MessageRole.assistant,
          createdAt: now,
          toolCalls: const [
            ToolCallRef(id: 'other', name: 'read_file', arguments: otherArgs),
            ToolCallRef(id: 'ask', name: 'ask_user', arguments: askArgs),
          ],
        ),
      );
      await hub.chats.saveToolRun(
        ToolRun(
          id: 'run-ask',
          chatId: chatId,
          messageId: 'm',
          toolName: 'ask_user',
          argsJson: askArgs,
          status: ToolRunStatus.waitingUser,
          startedAt: now,
          toolCallId: 'ask',
        ),
      );

      await StartupRecovery(
        hub.chats,
        hub.logs,
        hub.settings,
      ).run(closedText: 'closed');
      await hub.resumeAfterRestart();
      await waitForToolIds(chatId, ['other']);
      expect(broker.pendingQuestions(chatId), isEmpty);

      final session = hub.session(chatId);
      final finished = session.events.firstWhere(
        (event) => event is AgentTurnFinished,
      );
      await session.stop();
      final event = await finished;

      expect((event as AgentTurnFinished).end, TurnEnd.stopped);
      final ask = (await hub.chats.toolRunsForChat(chatId))
          .singleWhere((run) => run.id == 'run-ask');
      expect(ask.status, ToolRunStatus.done);
      final tools = [
        for (final message in await hub.chats.messages(chatId))
          if (message.role == MessageRole.tool) message,
      ];
      expect(
        [for (final message in tools) message.toolCallId],
        ['other', 'ask'],
      );
      expect(tools.last.text, contains('did not answer'));
      expect(llm.requests, isEmpty);
    },
  );

  test(
    'resumed turn uses the project profile and saves a confirmed fact',
    () async {
      final now = DateTime.now();
      const profileId = 'strict';
      await PolicyProfileRepository(db).save(
        PolicyProfile(
          id: profileId,
          name: 'strict',
          profile: const SecurityProfile().withCommand(
            'echo',
            CommandRisk.deny,
          ),
          createdAt: now,
          updatedAt: now,
        ),
      );
      final project = await hub.projects.ensureProject(
        hostId: 'local',
        workspace: '/srv/resume-app',
      );
      await hub.projectStore.save(project.copyWith(policyProfileId: profileId));
      const chatId = 'resume-project';
      await hub.chats.saveChat(
        Chat(
          id: chatId,
          hostId: 'local',
          projectId: project.id,
          workspace: '/srv/resume-app',
          title: 'resume',
          titleSource: ChatTitleSource.user,
          model: 'fake/model',
          policyMode: PolicyMode.yolo,
          createdAt: now,
          updatedAt: now,
        ),
      );
      const echoArgs = '{"command":"echo hi"}';
      const pinArgs = '{"text":"staging host only"}';
      await hub.chats.insertMessage(
        ChatMessage(
          id: 'm',
          chatId: chatId,
          seq: 1,
          role: MessageRole.assistant,
          createdAt: now,
          toolCalls: const [
            ToolCallRef(id: 'echo', name: 'run_command', arguments: echoArgs),
            ToolCallRef(
              id: 'pin',
              name: 'pin_project_fact',
              arguments: pinArgs,
            ),
          ],
        ),
      );
      await hub.chats.saveToolRun(
        ToolRun(
          id: 'run-pin',
          chatId: chatId,
          messageId: 'm',
          toolName: 'pin_project_fact',
          argsJson: pinArgs,
          command: 'Save project fact: staging host only',
          status: ToolRunStatus.waitingApproval,
          startedAt: now,
          toolCallId: 'pin',
          pendingCard: const PendingCard(
            summary: 'Save project fact: staging host only',
            reason: 'project facts are shared with every chat in this project',
          ).encode(),
        ),
      );

      llm.script.add([const LlmTextDelta('done'), const LlmCompleted()]);
      final session = hub.session(chatId);
      final finished = session.events.firstWhere(
        (event) => event is AgentTurnFinished,
      );
      await hub.resumeAfterRestart();

      final denied = await waitForToolIds(chatId, ['echo']);
      expect(denied.single.text, contains('denied by policy'));

      await session.restoreUnanswered();
      expect(broker.pendingApprovals(chatId).map((card) => card.id), [
        'run-pin',
      ]);
      broker.resolveApproval('run-pin', const ApprovalDecision.allowOnce());
      await finished;

      final tools = [
        for (final message in await hub.chats.messages(chatId))
          if (message.role == MessageRole.tool) message,
      ];
      expect(
        [for (final message in tools) message.toolCallId],
        ['echo', 'pin'],
      );
      expect(tools.last.text, contains('saved'));
      expect(tools.last.text, isNot(contains('no project')));
      final facts = await hub.projectStore.facts(project.id);
      expect(facts.single.text, 'staging host only');
    },
  );

  group('changeset only records successful writes', () {
    test(
      'denied write_file is not stored and does not prompt rollback later',
      () async {
        final chatId = await createChat(mode: PolicyMode.ask);
        final path = '${tmp.path}/denied_create.txt';
        final session = hub.session(chatId);
        final approvals = broker.approvalRequests.listen((request) {
          broker.resolveApproval(request.id, const ApprovalDecision.deny());
        });
        addTearDown(approvals.cancel);

        llm.script
          ..add([
            LlmCompleted(
              toolCalls: [
                _call(
                  'w',
                  'write_file',
                  jsonEncode({'path': path, 'content': 'agent'}),
                ),
              ],
            ),
          ])
          ..add([const LlmTextDelta('no'), const LlmCompleted()]);
        await runTurn(session, 'try create');

        final turnId = (await hub.chats.messages(chatId))
            .firstWhere((m) => m.role == MessageRole.user)
            .id;
        expect(await hub.turnChangesets.get(chatId, turnId), isNull);
        File(path).writeAsStringSync('user content');

        var prompted = false;
        final sub = broker.editFileChangesRequests.listen(
          (_) => prompted = true,
        );
        addTearDown(sub.cancel);
        llm.script.add([const LlmTextDelta('again'), const LlmCompleted()]);
        await session.editUserMessage(turnId, 'retry');
        expect(prompted, isFalse);
        expect(File(path).readAsStringSync(), 'user content');
      },
    );
  });

  group('edit message file rollback', () {
    Future<List<ChatMessage>> userMessages(String chatId) async => [
      for (final message in await hub.chats.messages(chatId))
        if (message.role == MessageRole.user) message,
    ];

    Future<void> resolveNextEditFileChanges(
      String chatId,
      EditFileChangesChoice choice,
    ) async {
      final request = await broker.editFileChangesRequests
          .where((item) => item.chatId == chatId)
          .first;
      broker.resolveEditFileChanges(request.id, choice);
    }

    test('regenerate uses the same implicit rollback prompt', () async {
      final chatId = await createChat();
      final path = '${tmp.path}/regenerate_rollback.txt';
      final session = hub.session(chatId);

      llm.script
        ..add([
          LlmCompleted(
            toolCalls: [
              _call(
                'w',
                ToolNames.writeFile,
                jsonEncode({'path': path, 'content': 'created'}),
              ),
            ],
          ),
        ])
        ..add([const LlmTextDelta('first answer'), const LlmCompleted()]);
      await runTurn(session, 'create the file');

      final before = (await hub.chats.messages(chatId))
          .where((message) => message.role == MessageRole.user);
      expect(before, hasLength(1));

      unawaited(
        resolveNextEditFileChanges(
          chatId,
          EditFileChangesChoice.rollbackAndContinue,
        ),
      );
      final finished = session.events.firstWhere((e) => e is AgentTurnFinished);
      llm.script.add([
        const LlmTextDelta('second answer'),
        const LlmCompleted(),
      ]);

      expect(await session.regenerateLast(), isTrue);
      await finished;

      expect(File(path).existsSync(), isFalse);
      final messages = await hub.chats.messages(chatId);
      expect(
        messages.where((message) => message.role == MessageRole.user),
        hasLength(1),
      );
      expect(messages.last.text, 'second answer');
    });

    test('editing after apply_patch restores the pre-turn file', () async {
      final chatId = await createChat();
      final path = '${tmp.path}/patch_rollback.txt';
      final session = hub.session(chatId);

      llm.script
        ..add([
          LlmCompleted(
            toolCalls: [
              _call(
                'w',
                ToolNames.writeFile,
                jsonEncode({'path': path, 'content': 'one\n'}),
              ),
            ],
          ),
        ])
        ..add([const LlmTextDelta('created'), const LlmCompleted()]);
      await runTurn(session, 'create the file');

      llm.script
        ..add([
          LlmCompleted(
            toolCalls: [
              _call(
                'p',
                ToolNames.applyPatch,
                jsonEncode({
                  'path': path,
                  'patch': '@@ -1,1 +1,1 @@\n-one\n+two',
                }),
              ),
            ],
          ),
        ])
        ..add([const LlmTextDelta('patched'), const LlmCompleted()]);
      await runTurn(session, 'patch the file');

      final users = await userMessages(chatId);
      unawaited(
        resolveNextEditFileChanges(
          chatId,
          EditFileChangesChoice.rollbackAndContinue,
        ),
      );
      llm.script.add([const LlmTextDelta('ok'), const LlmCompleted()]);
      await session.editUserMessage(users.last.id, 'rephrase patch');

      expect(File(path).readAsStringSync(), 'one\n');
    });

    test(
      'editing a later message restores files to state after the first write',
      () async {
        final chatId = await createChat();
        final path = '${tmp.path}/edit_msg_two.txt';
        final session = hub.session(chatId);

        llm.script
          ..add([
            LlmCompleted(
              toolCalls: [
                _call(
                  'w',
                  'write_file',
                  jsonEncode({'path': path, 'content': 'after-create'}),
                ),
              ],
            ),
          ])
          ..add([const LlmTextDelta('created'), const LlmCompleted()]);
        await runTurn(session, 'create the file');

        llm.script
          ..add([
            LlmCompleted(
              toolCalls: [
                _call(
                  'e',
                  'edit_file',
                  jsonEncode({
                    'path': path,
                    'old_string': 'after-create',
                    'new_string': 'after-edit',
                  }),
                ),
              ],
            ),
          ])
          ..add([const LlmTextDelta('edited'), const LlmCompleted()]);
        await runTurn(session, 'edit the file');

        final users = await userMessages(chatId);
        final secondId = users.last.id;
        unawaited(
          resolveNextEditFileChanges(
            chatId,
            EditFileChangesChoice.rollbackAndContinue,
          ),
        );
        llm.script.add([const LlmTextDelta('ok'), const LlmCompleted()]);
        await session.editUserMessage(secondId, 'rephrase edit');

        expect(File(path).existsSync(), isTrue);
        final onDisk = await File(path).readAsString();
        expect(onDisk, 'after-create');
        expect(
          (await hub.turnChangesets.get(chatId, secondId))!.rolledBack,
          isTrue,
        );
      },
    );

    test(
      'editing the first message chains rollback and removes a created file',
      () async {
        final chatId = await createChat();
        final path = '${tmp.path}/edit_msg_chain.txt';
        final session = hub.session(chatId);

        llm.script
          ..add([
            LlmCompleted(
              toolCalls: [
                _call(
                  'w',
                  'write_file',
                  jsonEncode({'path': path, 'content': 'v1'}),
                ),
              ],
            ),
          ])
          ..add([const LlmTextDelta('1'), const LlmCompleted()]);
        await runTurn(session, 'write');

        llm.script
          ..add([
            LlmCompleted(
              toolCalls: [
                _call(
                  'e',
                  'edit_file',
                  jsonEncode({
                    'path': path,
                    'old_string': 'v1',
                    'new_string': 'v2',
                  }),
                ),
              ],
            ),
          ])
          ..add([const LlmTextDelta('2'), const LlmCompleted()]);
        await runTurn(session, 'edit more');

        final firstId = (await userMessages(chatId)).first.id;
        unawaited(
          resolveNextEditFileChanges(
            chatId,
            EditFileChangesChoice.rollbackAndContinue,
          ),
        );
        llm.script.add([const LlmTextDelta('ok'), const LlmCompleted()]);
        await session.editUserMessage(firstId, 'rephrase first');

        expect(File(path).existsSync(), isFalse);
      },
    );

    test(
      'edit without rollback keeps files and marks changesets kept',
      () async {
        final chatId = await createChat();
        final path = '${tmp.path}/edit_msg_keep.txt';
        final session = hub.session(chatId);

        llm.script
          ..add([
            LlmCompleted(
              toolCalls: [
                _call(
                  'w',
                  'write_file',
                  jsonEncode({'path': path, 'content': 'keep-me'}),
                ),
              ],
            ),
          ])
          ..add([const LlmTextDelta('ok'), const LlmCompleted()]);
        await runTurn(session, 'write once');

        final userId = (await userMessages(chatId)).single.id;
        unawaited(
          resolveNextEditFileChanges(
            chatId,
            EditFileChangesChoice.continueWithoutRollback,
          ),
        );
        llm.script.add([const LlmTextDelta('again'), const LlmCompleted()]);
        await session.editUserMessage(userId, 'rephrase');

        expect(await File(path).readAsString(), 'keep-me');
        final kept = await hub.turnChangesets.get(chatId, userId);
        expect(kept!.keptOnEdit, isTrue);

        var prompted = false;
        final sub = broker.editFileChangesRequests.listen(
          (_) => prompted = true,
        );
        llm.script.add([const LlmTextDelta('third'), const LlmCompleted()]);
        await session.editUserMessage(userId, 'once more');
        await sub.cancel();
        expect(prompted, isFalse);
      },
    );

    test(
      'shell mutation sets nonRecoverable on the edit-file prompt',
      () async {
        final chatId = await createChat();
        final path = '${tmp.path}/edit_msg_shell.txt';
        final session = hub.session(chatId);

        llm.script
          ..add([
            LlmCompleted(
              toolCalls: [
                _call(
                  'sh',
                  'run_command',
                  jsonEncode({'command': 'echo hi > /tmp/x'}),
                ),
                _call(
                  'w',
                  'write_file',
                  jsonEncode({'path': path, 'content': 'body'}),
                ),
              ],
            ),
          ])
          ..add([const LlmTextDelta('done'), const LlmCompleted()]);
        await runTurn(session, 'shell and write');

        final userId = (await userMessages(chatId)).single.id;
        Future<void> answerPrompt() async {
          final request = await broker.editFileChangesRequests
              .where((item) => item.chatId == chatId)
              .first;
          expect(request.shellMayHaveChangedFiles, isTrue);
          broker.resolveEditFileChanges(
            request.id,
            EditFileChangesChoice.cancel,
          );
        }

        await Future.wait([
          answerPrompt(),
          session.editUserMessage(userId, 'edit'),
        ]);
      },
    );

    test('staging copy is removed after a successful edit', () async {
      final chatId = await createChat();
      final path = '${tmp.path}/turn_cs_staging_cleanup.txt';
      final session = hub.session(chatId);
      final store = TurnChangesetStore(tmp);

      llm.script
        ..add([
          LlmCompleted(
            toolCalls: [
              _call(
                'w',
                'write_file',
                jsonEncode({'path': path, 'content': 'x'}),
              ),
              _call(
                'ed',
                'edit_file',
                jsonEncode({
                  'path': path,
                  'old_string': 'x',
                  'new_string': 'y',
                }),
              ),
            ],
          ),
        ])
        ..add([const LlmTextDelta('ok'), const LlmCompleted()]);
      await runTurn(session, 'write then edit');

      final turnId = (await userMessages(chatId)).single.id;
      final staging = store.stagingDir(chatId, turnId);
      final leftovers = staging.existsSync()
          ? staging
                .listSync()
                .whereType<File>()
                .where((file) => file.path.endsWith('.stg'))
                .toList()
          : <File>[];
      expect(leftovers, isEmpty);
    });
  });
}

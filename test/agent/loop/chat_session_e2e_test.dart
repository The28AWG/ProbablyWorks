import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
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
import 'package:probably_works/agent/loop/chat_title.dart';
import 'package:probably_works/agent/state/session_state_service.dart';
import 'package:probably_works/agent/tools/tool_executor.dart';
import 'package:probably_works/agent/workspace/workspace_context_loader.dart';
import 'package:probably_works/core/data/chat_draft_store.dart';
import 'package:probably_works/core/data/chat_repository.dart';
import 'package:probably_works/core/data/host_repository.dart';
import 'package:probably_works/core/data/saved_model_repository.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/db/app_database.dart';
import 'package:probably_works/core/db/db_connection.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/error/app_failure.dart';
import 'package:probably_works/core/notify/desktop_notifier.dart';
import 'package:probably_works/core/security/secret_store.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/features/chats/presentation/bloc/chat_list_cubit.dart';
import 'package:probably_works/host/host_runtime_factory.dart';
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
  late ChatDraftStore drafts;

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
    drafts = ChatDraftStore(chats);
    hub = AgentHub(
      chats,
      settings,
      hosts,
      HostRuntimeFactory(pool, const PipePtyLauncher()),
      llm,
      ModelCatalogService(SavedModelRepository(db), llm),
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
    'ask mode: approved command stays one run that moves from waiting to done',
    () async {
      final chatId = await createChat(mode: PolicyMode.ask);
      final requested = <String>[];
      final approvals = broker.approvalRequests.listen((request) {
        requested.add(request.id);
        broker.resolveApproval(request.id, allow: true);
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

  test('creating a chat moves the draft of the current chat into it and clears the old one', () async {
    final first = await createChat();
    final cubit = ChatListCubit(hub, drafts);
    addTearDown(cubit.close);
    cubit.select(first);
    drafts.update(first, const ChatDraft(text: 'черновик'));

    final created = await cubit.create();

    expect(cubit.state.selectedId, created);
    expect(drafts.of(created).text, 'черновик');
    expect(drafts.of(first).isEmpty, isTrue);
    // Перенос сохраняется в БД сразу, без задержки записи.
    expect((await hub.chats.chat(created))!.draft.text, 'черновик');
    expect((await hub.chats.chat(first))!.draft.isEmpty, isTrue);
  });
}

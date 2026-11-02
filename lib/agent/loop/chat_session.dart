import 'dart:async';

import 'package:logging/logging.dart';
import 'package:probably_works/agent/context/context_builder.dart';
import 'package:probably_works/agent/context/context_compactor.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/exec/command_executor.dart';
import 'package:probably_works/agent/interaction/interaction_broker.dart';
import 'package:probably_works/agent/loop/agent_event.dart';
import 'package:probably_works/agent/loop/agent_hub.dart';
import 'package:probably_works/agent/loop/chat_title.dart';
import 'package:probably_works/agent/loop/prompt_queue.dart';
import 'package:probably_works/agent/policy/command_classifier.dart';
import 'package:probably_works/agent/policy/policy_engine.dart';
import 'package:probably_works/agent/tools/tool_catalog.dart';
import 'package:probably_works/agent/tools/tool_executor.dart';
import 'package:probably_works/core/config/app_limits.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/error/app_failure.dart';
import 'package:probably_works/core/util/cancel_token.dart';
import 'package:probably_works/core/util/redactor.dart';
import 'package:probably_works/core/util/text_clip.dart';
import 'package:probably_works/host/host_capture.dart';
import 'package:probably_works/host/host_runtime.dart';
import 'package:probably_works/host/shell_adapter.dart';
import 'package:probably_works/providers/ai/llm_port.dart';
import 'package:uuid/uuid.dart';

/// Ход агента одного чата: очередь ввода, цикл модели и инструментов, Stop, edit/delete-after.
/// Одновременно выполняется не более одного хода; ввод во время хода уходит в очередь.
class ChatSession {
  ChatSession(this.chatId, this._hub) {
    _runSub = _hub.tools.runChanges
        .where((run) => run.chatId == chatId)
        .listen((run) => _emit(AgentRunChanged(chatId, run)));
    // Ожидание пользователя должно быть заметно, даже если окно приложения не в фокусе.
    _waitSub = _hub.broker.approvalRequests
        .where((r) => r.chatId == chatId)
        .listen(
          (_) => unawaited(
            _hub.notifier.notify(
              title: 'ProbablyWorks',
              body: 'Approval needed',
            ),
          ),
        );
    _questionSub = _hub.broker.questions
        .where((q) => q.chatId == chatId)
        .listen(
          (_) => unawaited(
            _hub.notifier.notify(
              title: 'ProbablyWorks',
              body: 'The agent is waiting for an answer',
            ),
          ),
        );
  }

  final String chatId;
  final AgentHub _hub;

  final _log = Logger('ChatSession');
  final _events = StreamController<AgentEvent>.broadcast();
  final PromptQueue _queue = PromptQueue();
  late final StreamSubscription<ToolRun> _runSub;
  late final StreamSubscription<ApprovalRequest> _waitSub;
  late final StreamSubscription<UserQuestion> _questionSub;
  String? _hostStubHostId;
  String? _hostStubText;

  static const _uuid = Uuid();
  static const _maxRetries = 3;

  bool _running = false;
  CancelToken? _turnCancel;
  CancelToken? _stepCancel;

  Stream<AgentEvent> get events => _events.stream;

  bool get isRunning => _running;

  List<QueuedPrompt> get queue => _queue.items;

  // ---- public API --------------------------------------------------------

  /// Пользовательский ввод. Во время хода: обычный — в очередь (soft drain), [sendNow] — прерывает шаг модели.
  Future<void> submit(
    String text, {
    List<AttachmentRef> attachments = const [],
    bool sendNow = false,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty && attachments.isEmpty) return;
    final prompt = QueuedPrompt.user(
      trimmed,
      attachments: [for (final a in attachments) a.redacted()],
    );
    if (!_running) {
      _running = true;
      await _persistPrompt(prompt);
      unawaited(_runTurn());
      return;
    }
    if (sendNow) {
      _queue.enqueueFirst(prompt);
      _stepCancel?.cancel();
    } else {
      _queue.enqueue(prompt);
    }
    _emitQueue();
  }

  /// Элемент очереди — отправить сейчас: встаёт первым, текущий шаг прерывается.
  /// Если хода нет (например, после Stop), ход запускается сразу.
  void promoteQueued(int index) {
    final item = _queue.takeAt(index);
    if (item == null) return;
    _queue.enqueueFirst(item);
    _emitQueue();
    if (_running) {
      _stepCancel?.cancel();
    } else {
      _running = true;
      unawaited(_runTurn());
    }
  }

  /// Вынимает элемент очереди (для редактирования в поле ввода или удаления).
  QueuedPrompt? takeQueued(int index) {
    final item = _queue.takeAt(index);
    _emitQueue();
    return item;
  }

  /// Ручное сжатие истории (кнопка) или проверка контекста после смены модели.
  /// Не выполняется во время хода: ход сам управляет контекстом.
  Future<void> compactNow({bool force = false}) async {
    if (_running) throw StateError('cannot compact while the agent is running');
    try {
      await _prepare(await _hub.limits(), forceCompact: force);
    } on AppFailure catch (failure) {
      _emit(AgentFailureRaised(chatId, failure));
    }
    _emit(AgentStateChanged(chatId));
  }

  /// Stop: отменяет ход, останавливает процессы чата, снимает ожидания approve/вопросов.
  /// Очередь не дренируется: остаётся до следующего явного действия пользователя.
  Future<void> stop() async {
    _turnCancel?.cancel();
    _stepCancel?.cancel();
    _hub.broker.cancelChat(chatId);
    await _hub.registry.stopChat(chatId);
    final limits = await _hub.limits();
    Timer(limits.killGrace, () {
      if (_hub.registry.forChat(chatId).isNotEmpty) {
        unawaited(_hub.registry.stopChat(chatId, force: true));
      }
    });
  }

  /// Продолжить после достижения лимита шагов.
  Future<void> continueAfterStepLimit() async {
    if (_running) return;
    _running = true;
    unawaited(_runTurn());
  }

  /// Edit N: восстанавливает состояние «ДО» N, удаляет N и всё после, отправляет новый текст.
  Future<void> editUserMessage(String messageId, String newText) async {
    if (_running) throw StateError('cannot edit while the agent is running');
    final message = await _find(messageId);
    if (message == null || message.role != MessageRole.user) return;
    await _truncate(message, fromSelf: true, restoreBefore: true);
    await submit(newText, attachments: message.attachments);
  }

  /// Delete-after N: оставляет N, удаляет всё после, состояние — как после N.
  Future<void> deleteAfter(String messageId) async {
    if (_running) throw StateError('cannot delete while the agent is running');
    final message = await _find(messageId);
    if (message == null) return;
    await _truncate(message, fromSelf: false, restoreBefore: false);
    _emit(AgentStateChanged(chatId));
  }

  // ---- turn loop ---------------------------------------------------------

  Future<void> _runTurn() async {
    final turn = _turnCancel = CancelToken();
    _emit(AgentTurnStarted(chatId));
    var end = TurnEnd.completed;
    try {
      end = await _loop(turn);
    } on AppFailure catch (failure) {
      end = TurnEnd.failed;
      _emit(AgentFailureRaised(chatId, failure));
    } on Object catch (error, stack) {
      _log.severe('turn crashed', error, stack);
      end = TurnEnd.failed;
      _emit(AgentFailureRaised(chatId, LlmFailure('internal error: $error')));
    } finally {
      _running = false;
      _turnCancel = null;
      _stepCancel = null;
      _emit(AgentTurnFinished(chatId, end));
    }
    if (end == TurnEnd.completed) {
      unawaited(
        _hub.notifier.notify(title: 'ProbablyWorks', body: 'Task finished'),
      );
    } else if (end == TurnEnd.failed) {
      unawaited(
        _hub.notifier.notify(title: 'ProbablyWorks', body: 'Task failed'),
      );
    }
  }

  Future<TurnEnd> _loop(CancelToken turn) async {
    final limits = await _hub.limits();
    var steps = 0;
    while (true) {
      if (turn.isCancelled) return TurnEnd.stopped;
      await _drainQueue();

      final prepared = await _prepare(limits);
      final step = await _streamWithRetry(prepared.request, turn, limits);
      final assistant =
          step.text.isEmpty && step.toolCalls.isEmpty && step.reasoning.isEmpty
          ? null
          : await _append(
              MessageRole.assistant,
              text: step.text,
              reasoning: Redactor.redact(step.reasoning),
              toolCalls: [
                for (final c in step.toolCalls)
                  ToolCallRef(id: c.id, name: c.name, arguments: c.arguments),
              ],
            );
      if (step.usage != null) {
        await _recordUsage(prepared.chat, step.usage!, prepared.limit);
      }
      if (step.stopped || turn.isCancelled) return TurnEnd.stopped;
      if (step.interruptedBySendNow) continue;
      if (step.toolCalls.isEmpty) {
        if (_queue.isNotEmpty) continue;
        return TurnEnd.completed;
      }

      steps++;
      final messageId = assistant?.id ?? '';
      if (steps > limits.maxAgentSteps) {
        await _answerRemaining(
          step.toolCalls,
          0,
          'not executed: step limit reached, the user must continue the task',
        );
        return TurnEnd.stepLimit;
      }

      final toolCtx = ToolContext(
        chat: prepared.chat,
        messageId: messageId,
        host: prepared.host,
        runtime: prepared.runtime,
        limits: limits,
        policy: prepared.policy,
        onBackgroundDone: _onBackgroundDone,
      );
      var finished = false;
      for (var i = 0; i < step.toolCalls.length; i++) {
        final call = step.toolCalls[i];
        if (turn.isCancelled) {
          await _answerRemaining(step.toolCalls, i, 'cancelled by the user');
          return TurnEnd.stopped;
        }
        final result = await _hub.tools.execute(call, toolCtx);
        await _append(
          MessageRole.tool,
          text: Redactor.redact(result.text),
          toolCallId: call.id,
        );
        if (result.finish) {
          finished = true;
          await _answerRemaining(
            step.toolCalls,
            i + 1,
            'not executed: the task was finished',
          );
          break;
        }
      }
      if (finished) return TurnEnd.completed;
    }
  }

  Future<_Prepared> _prepare(
    AppLimits limits, {
    bool forceCompact = false,
  }) async {
    var chat = await _hub.chats.chat(chatId);
    if (chat == null) throw const LlmFailure('chat not found');
    final host = await _hub.hosts.byId(chat.hostId);
    if (host == null) {
      throw const HostFailure(
        'host not found',
        kind: HostFailureKind.spawnFailed,
      );
    }
    final runtime = _hub.runtimes.forHost(host);
    final snapshot = await _hub.workspace.load(chat, runtime, host.os);
    if (snapshot.needsTrust) {
      _emit(AgentTrustNeeded(chatId, snapshot.workspace));
    }
    final model =
        chat.model ??
        await _hub.settings.read(SettingsRepository.keyDefaultModel);
    if (model == null || model.isEmpty) {
      throw const LlmFailure('model is not selected');
    }

    final state = await _hub.state.current(chat);
    final messages = await _hub.chats.messages(chatId);
    final hostStub = await _loadHostStub(host, runtime);
    final notes = _backgroundNotes();
    ContextInput inputFor(Chat current) => ContextInput(
      chat: current,
      host: host,
      messages: messages,
      state: state,
      workspace: snapshot,
      recentWindow: limits.recentWindowMessages,
      hostStub: hostStub,
      backgroundNotes: notes,
    );
    chat = await _hub.compactor.compactIfNeeded(
      inputFor(chat),
      summaryModel: model,
      force: forceCompact,
    );
    final llmMessages = _hub.builder.build(inputFor(chat));
    final limit = chat.contextLength ?? ContextCompactor.defaultContextLength;
    _emit(
      AgentUsageUpdated(chatId, ContextCompactor.estimate(llmMessages), limit),
    );

    final denylist = await _hub.settings.readDenylist();
    final policy = PolicyEngine(
      classifier: CommandClassifier(denylist: denylist),
      mode: chat.policyMode,
    );
    return _Prepared(
      chat: chat,
      host: host,
      runtime: runtime,
      policy: policy,
      limit: limit,
      request: LlmRequest(
        model: model,
        messages: llmMessages,
        tools: ToolCatalog.specs,
      ),
    );
  }

  Future<StepResult> _streamWithRetry(
    LlmRequest request,
    CancelToken turn,
    AppLimits limits,
  ) async {
    var attempt = 0;
    while (true) {
      try {
        return await _streamOnce(request, turn, limits);
      } on LlmFailure catch (failure) {
        if (!failure.retryable || attempt >= _maxRetries || turn.isCancelled) {
          rethrow;
        }
        attempt++;
        _log.warning(
          'retrying model request (attempt $attempt): ${failure.message}',
        );
        _emit(AgentTextDelta(chatId, '', reset: true));
        _emit(AgentReasoningDelta(chatId, '', reset: true));
        await Future.any<void>([
          Future<void>.delayed(Duration(seconds: 1 << (attempt - 1))),
          turn.whenCancelled,
        ]);
        if (turn.isCancelled) return const StepResult(text: '', stopped: true);
      }
    }
  }

  Future<StepResult> _streamOnce(
    LlmRequest request,
    CancelToken turn,
    AppLimits limits,
  ) async {
    final step = CancelToken();
    _stepCancel = step;
    final text = StringBuffer();
    final reasoning = StringBuffer();
    var toolCalls = <LlmToolCall>[];
    LlmUsage? usage;
    final done = Completer<void>();
    late StreamSubscription<LlmEvent> sub;
    Timer? watchdog;

    void resetWatchdog() {
      watchdog?.cancel();
      watchdog = Timer(limits.streamWatchdog, () {
        if (done.isCompleted) return;
        unawaited(sub.cancel());
        done.completeError(
          const LlmFailure('model did not respond in time', retryable: true),
        );
      });
    }

    resetWatchdog();
    sub = _hub.llm
        .stream(request)
        .listen(
          (event) {
            resetWatchdog();
            switch (event) {
              case LlmReasoningDelta e:
                reasoning.write(e.text);
                _emit(AgentReasoningDelta(chatId, e.text));
              case LlmTextDelta e:
                text.write(e.text);
                _emit(AgentTextDelta(chatId, e.text));
              case LlmCompleted e:
                toolCalls = e.toolCalls;
                usage = e.usage;
            }
          },
          onError: (Object error) {
            if (!done.isCompleted) done.completeError(error);
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
        );
    unawaited(() async {
      await Future.any<void>([turn.whenCancelled, step.whenCancelled]);
      if (done.isCompleted) return;
      await sub.cancel();
      done.complete();
    }());
    try {
      await done.future;
    } finally {
      watchdog?.cancel();
      _stepCancel = null;
    }
    return StepResult(
      text: text.toString(),
      reasoning: reasoning.toString(),
      toolCalls: toolCalls,
      usage: usage,
      interruptedBySendNow: step.isCancelled && !turn.isCancelled,
      stopped: turn.isCancelled,
    );
  }

  // ---- queue -------------------------------------------------------------

  /// Soft drain: вливает очередь в историю на границе шага.
  Future<void> _drainQueue() async {
    if (_queue.isEmpty) return;
    final items = _queue.drain();
    _emitQueue();
    for (final item in items) {
      if (item.isEvent) {
        await _append(MessageRole.event, text: item.text);
      } else {
        await _persistPrompt(item);
      }
    }
  }

  void _emitQueue() => _emit(AgentQueueChanged(chatId, _queue.items.length));

  // ---- background --------------------------------------------------------

  void _onBackgroundDone(ToolRun run, ExecOutcome outcome) {
    final exit = outcome.exitCode == null
        ? ''
        : ', exit code ${outcome.exitCode}';
    final text =
        'Background command ${run.id} finished with status ${outcome.status.name}$exit.\n'
        'Command: ${run.command ?? run.toolName}\n'
        '${TextClip.headTail(outcome.outputText, maxChars: 2000)}';
    unawaited(
      _hub.notifier.notify(
        title: 'ProbablyWorks',
        body: 'Background command ${outcome.status.name}',
      ),
    );
    unawaited(_deliverEvent(text));
  }

  Future<void> _deliverEvent(String text) async {
    if (_running) {
      _queue.enqueue(QueuedPrompt.event(text));
      _emitQueue();
      return;
    }
    _running = true;
    await _append(MessageRole.event, text: text);
    unawaited(_runTurn());
  }

  // ---- persistence -------------------------------------------------------

  /// Сохраняет пользовательский промпт и открывает новую ревизию состояния.
  Future<void> _persistPrompt(QueuedPrompt prompt) async {
    final chat = await _hub.chats.chat(chatId);
    if (chat == null) return;
    final messageId = _uuid.v4();
    final revisions = await _hub.state.onUserMessage(chat, messageId);
    await _append(
      MessageRole.user,
      id: messageId,
      text: prompt.text,
      attachments: prompt.attachments,
      openedRevisionId: revisions.opened,
      sealedBeforeRevisionId: revisions.sealedBefore,
    );
    final refreshed = await _hub.chats.chat(chatId);
    if (refreshed != null &&
        refreshed.titleSource == ChatTitleSource.none &&
        prompt.text.isNotEmpty) {
      await _hub.chats.saveChat(
        refreshed.copyWith(title: ChatTitle.fallback(prompt.text)),
      );
      _emit(AgentStateChanged(chatId));
      unawaited(_generateTitle(prompt.text));
    }
  }

  /// Снимок хоста (user, cwd, shell) для контекста. Получается один раз на хост в рамках сессии.
  Future<String?> _loadHostStub(Host host, HostRuntime runtime) async {
    if (_hostStubHostId == host.id && _hostStubText != null) {
      return _hostStubText;
    }
    final run = await captureRun(runtime, ShellAdapter(host.os).hostInfo());
    if (!run.ok) return null;
    _hostStubHostId = host.id;
    _hostStubText = run.stdout.trim();
    return _hostStubText;
  }

  List<String> _backgroundNotes() => [
    for (final exec in _hub.registry.forChat(chatId))
      if (exec.background)
        'pid ${exec.pid ?? '?'}: ${exec.command} (started ${exec.startedAt.toIso8601String()})',
  ];

  Future<ChatMessage> _append(
    MessageRole role, {
    String? id,
    String text = '',
    String reasoning = '',
    List<ToolCallRef> toolCalls = const [],
    String? toolCallId,
    List<AttachmentRef> attachments = const [],
    String? openedRevisionId,
    String? sealedBeforeRevisionId,
  }) async {
    final seq = await _hub.chats.nextSeq(chatId);
    final message = ChatMessage(
      id: id ?? _uuid.v4(),
      chatId: chatId,
      seq: seq,
      role: role,
      createdAt: DateTime.now(),
      text: text,
      reasoning: reasoning,
      toolCalls: toolCalls,
      toolCallId: toolCallId,
      attachments: attachments,
      openedRevisionId: openedRevisionId,
      sealedBeforeRevisionId: sealedBeforeRevisionId,
    );
    await _hub.chats.insertMessage(message);
    _emit(AgentMessageAdded(chatId, message));
    return message;
  }

  Future<void> _answerRemaining(
    List<LlmToolCall> calls,
    int from,
    String reason,
  ) async {
    for (var i = from; i < calls.length; i++) {
      await _append(MessageRole.tool, text: reason, toolCallId: calls[i].id);
    }
  }

  Future<void> _recordUsage(Chat chat, LlmUsage usage, int limit) async {
    final current = await _hub.chats.chat(chatId) ?? chat;
    await _hub.chats.saveChat(
      current.copyWith(
        lastPromptTokens: usage.promptTokens,
        lastCompletionTokens: usage.completionTokens,
      ),
    );
    _emit(AgentUsageUpdated(chatId, usage.promptTokens, limit));
  }

  Future<ChatMessage?> _find(String messageId) async {
    for (final message in await _hub.chats.messages(chatId)) {
      if (message.id == messageId) return message;
    }
    return null;
  }

  /// Удаляет сообщения (с N или после N), их tool runs, логи и ревизии. fromSelf — удалить и N.
  Future<void> _truncate(
    ChatMessage message, {
    required bool fromSelf,
    required bool restoreBefore,
  }) async {
    final chat = await _hub.chats.chat(chatId);
    if (chat == null) return;
    if (restoreBefore) {
      await _hub.state.restoreBefore(chat, message);
    } else {
      await _hub.state.restoreAfter(chat, message);
    }
    final fromSeq = fromSelf ? message.seq : message.seq + 1;
    final ids = await _hub.chats.deleteMessagesFrom(chatId, fromSeq);
    final runs = await _hub.chats.toolRunsForMessages(ids);
    for (final run in runs) {
      await _hub.logs.deleteFile(run.logPath);
    }
    await _hub.chats.deleteToolRuns([for (final r in runs) r.id]);
    await _hub.chats.deleteRevisionsTriggeredBy(ids);
    _emit(AgentStateChanged(chatId));
  }

  // ---- title -------------------------------------------------------------

  /// Модель для заголовка: отдельная из настроек, иначе модель по умолчанию.
  /// Пустая строка в настройках означает «не задана» (очистка поля пишет именно её).
  Future<String?> _titleModel() async {
    final titleModel = await _hub.settings.read(
      SettingsRepository.keyTitleModel,
    );
    if (titleModel != null && titleModel.isNotEmpty) return titleModel;
    final defaultModel = await _hub.settings.read(
      SettingsRepository.keyDefaultModel,
    );
    return defaultModel == null || defaultModel.isEmpty ? null : defaultModel;
  }

  Future<void> _generateTitle(String prompt) async {
    try {
      final model = await _titleModel();
      if (model == null) {
        _log.warning('title generation skipped: no model configured');
        return;
      }
      final request = LlmRequest(
        model: model,
        messages: [
          const LlmMessage.system(ChatTitle.systemPrompt),
          LlmMessage.user(TextClip.headTail(prompt, maxChars: 1000)),
        ],
        maxTokens: ChatTitle.maxTokens,
        skipReasoning: true,
      );
      final buffer = StringBuffer();
      await for (final event in _hub.llm.stream(request)) {
        if (event is LlmTextDelta) buffer.write(event.text);
      }
      final title = ChatTitle.sanitize(buffer.toString());
      if (title == null) {
        _log.warning(
          'title generation: unusable model reply, keeping fallback',
        );
        return;
      }
      final chat = await _hub.chats.chat(chatId);
      if (chat == null || chat.titleSource == ChatTitleSource.user) return;
      await _hub.chats.saveChat(
        chat.copyWith(title: title, titleSource: ChatTitleSource.generated),
      );
      _emit(AgentStateChanged(chatId));
    } on Object catch (error, stack) {
      _log.warning('title generation failed', error, stack);
    }
  }

  void _emit(AgentEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  Future<void> dispose() async {
    await _runSub.cancel();
    await _waitSub.cancel();
    await _questionSub.cancel();
    await _events.close();
  }
}

class _Prepared {
  const _Prepared({
    required this.chat,
    required this.host,
    required this.runtime,
    required this.policy,
    required this.limit,
    required this.request,
  });

  final Chat chat;
  final Host host;
  final HostRuntime runtime;
  final PolicyEngine policy;
  final int limit;
  final LlmRequest request;
}

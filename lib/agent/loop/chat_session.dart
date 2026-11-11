import 'dart:async';

import 'package:logging/logging.dart';
import 'package:probably_works/agent/context/context_breakdown.dart';
import 'package:probably_works/agent/context/context_builder.dart';
import 'package:probably_works/agent/context/context_compactor.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/domain/project.dart';
import 'package:probably_works/agent/exec/command_executor.dart';
import 'package:probably_works/agent/interaction/edit_file_changes_request.dart';
import 'package:probably_works/agent/interaction/interaction_broker.dart';
import 'package:probably_works/agent/loop/agent_event.dart';
import 'package:probably_works/agent/loop/agent_hub.dart';
import 'package:probably_works/agent/loop/chat_title.dart';
import 'package:probably_works/agent/loop/prompt_queue.dart';
import 'package:probably_works/agent/loop/tool_scheduler.dart';
import 'package:probably_works/agent/policy/command_classifier.dart';
import 'package:probably_works/agent/policy/policy_engine.dart';
import 'package:probably_works/agent/tools/self_tool_catalog.dart';
import 'package:probably_works/agent/tools/tool_catalog.dart';
import 'package:probably_works/agent/tools/tool_executor.dart';
import 'package:probably_works/agent/turn/turn_changeset_logic.dart';
import 'package:probably_works/core/config/app_limits.dart';
import 'package:probably_works/core/data/chat_repository.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/domain/chat_usage.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/error/app_failure.dart';
import 'package:probably_works/core/notify/app_notifier.dart';
import 'package:probably_works/core/util/cancel_token.dart';
import 'package:probably_works/core/util/redactor.dart';
import 'package:probably_works/core/util/text_clip.dart';
import 'package:probably_works/core/util/workspace_path.dart';
import 'package:probably_works/host/host_capture.dart';
import 'package:probably_works/host/host_op.dart';
import 'package:probably_works/host/host_runtime.dart';
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
        .listen((_) => unawaited(_notify(AgentNoticeKind.approvalNeeded)));
    _questionSub = _hub.broker.questions
        .where((q) => q.chatId == chatId)
        .listen((_) => unawaited(_notify(AgentNoticeKind.questionAsked)));
    _changesetSub = _hub.turnChangesets.changes
        .where((cs) => cs.chatId == chatId)
        .listen((cs) => _emit(AgentTurnChangesetChanged(chatId, cs)));
  }

  final String chatId;
  final AgentHub _hub;

  final _log = Logger('ChatSession');
  final _events = StreamController<AgentEvent>.broadcast();
  final PromptQueue _queue = PromptQueue();

  /// Бинарные файлы сообщений, которые ещё не ушли модели (id сообщения → файлы).
  /// Байты не хранятся в БД: живут здесь до успешного ответа модели на первый запрос хода.
  final Map<String, List<LlmFilePart>> _inlineFiles = {};
  late final StreamSubscription<ToolRun> _runSub;
  late final StreamSubscription<ApprovalRequest> _waitSub;
  late final StreamSubscription<UserQuestion> _questionSub;
  String? _hostStubHostId;
  String? _hostStubText;

  static const _uuid = Uuid();
  static const _maxRetries = 3;

  /// Сколько раз можно автоматически попросить модель продолжить ответ,
  /// обрезанный по лимиту вывода. Дальше показываем предупреждение и завершаем ход.
  static const _maxLengthContinues = 2;

  static const _lengthContinueText =
      'the previous answer was cut by the model output limit; continue it';
  static const _lengthFinalText =
      'model output limit reached; the answer may be incomplete';

  bool _running = false;
  CancelToken? _turnCancel;
  CancelToken? _stepCancel;

  late final StreamSubscription _changesetSub;

  /// Повторный вход в открытие чата ждёт ту же регистрацию карточек, а не вторую.
  Future<void>? _restoreInFlight;

  /// Карточки, которые ход уже ждёт, но в брокер ещё не положил.
  /// Открытие чата их показывает. До этого зависимый вызов стоит, а независимый идёт.
  final Map<String, _ParkedCard> _parked = {};

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
  /// [reason] — событие в чате с причиной (например, остановка при сворачивании на iOS).
  Future<void> stop({String? reason}) async {
    _turnCancel?.cancel();
    _stepCancel?.cancel();
    // Карточка ещё не в брокере: cancelChat её не видит, а планировщик ждёт это будущее.
    _releaseParked();
    _hub.broker.cancelChat(chatId);
    await _hub.registry.stopChat(chatId);
    if (reason != null) await _append(MessageRole.event, text: reason);
    final limits = await _hub.limits();
    Timer(limits.killGrace, () {
      if (_hub.registry.forChat(chatId).isNotEmpty) {
        unawaited(_hub.registry.stopChat(chatId, force: true));
      }
    });
  }

  /// Показывает неотвеченные карточки этого чата и продолжает ход с места ожидания.
  ///
  /// Читает только этот чат: закрытые чаты не трогаем. Возвращается, когда карточки
  /// уже в брокере, и не ждёт ответ. Повторный вызов во время того же хода ничего не делает.
  /// Явный ответ, отказ и Stop записывают статус и больше не восстанавливаются.
  ///
  /// Карточки одного сообщения регистрируются все сразу. Планировщик доигрывает
  /// остальные вызовы, не дожидаясь чужих ответов, и держит порядок только там,
  /// где вызовы конфликтуют по ресурсам. Уже отвеченные повторно не открываются.
  ///
  /// Если ход уже продолжен после старта приложения, второй не запускается:
  /// здесь только появляются карточки, которые старт сознательно не показывал.
  Future<void> restoreUnanswered() async {
    if (_running) {
      _showParkedCards();
      return;
    }
    final inflight = _restoreInFlight;
    if (inflight != null) {
      await inflight;
      // Ход уже идёт: карточки, отложенные стартом, пора показать.
      // Ход не стартовал (в шаге были только карточки) — идём обычным путём ниже.
      if (_running) {
        _showParkedCards();
        return;
      }
    }
    final gate = Completer<void>();
    _restoreInFlight = gate.future;
    try {
      final runs = await _hub.chats.waitingRuns(chatId);
      if (runs.isEmpty || _running) return;
      _running = true;
      final turn = _turnCancel = CancelToken();
      final reopened = [for (final run in runs) _hub.tools.reopenWaiting(run)];
      unawaited(_finishTurn(() => _resumeThenLoop(reopened, turn)));
    } finally {
      if (!gate.isCompleted) gate.complete();
      if (identical(_restoreInFlight, gate.future)) _restoreInFlight = null;
    }
  }

  /// Есть ли шаг модели, у которого ещё не все вызовы лежат в ленте.
  ///
  /// Активный запуск для этого не обязателен: после закрытия приложения процесс
  /// уже помечен прерванным, а хвост вызовов мог не начаться.
  static Future<bool> hasUnfinishedStep(
    ChatRepository chats,
    String chatId,
  ) async {
    final messages = await chats.messages(chatId);
    return _unfinishedAssistant(messages) != null;
  }

  /// Продолжает незакрытый шаг после старта приложения, не показывая карточки.
  ///
  /// Процесс, который прервало закрытие, в ленту возвращается готовым результатом
  /// и заново не запускается. Вызов без карточки стартует, как только закрыты его
  /// зависимости, даже если чат никто не открыл. Вопрос и подтверждение ждут
  /// открытия: до этого их нет в брокере, и зависимый вызов стоит вместе с ними.
  /// Если выполнять больше нечего, ход не стартует: иначе чат выглядел бы занятым
  /// из-за карточки, которой на экране ещё нет.
  Future<void> resumeAfterRestart() async {
    if (_running) return;
    final inflight = _restoreInFlight;
    if (inflight != null) {
      await inflight;
      if (_running) return;
    }
    final gate = Completer<void>();
    _restoreInFlight = gate.future;
    try {
      if (_running) return;
      final messages = await _hub.chats.messages(chatId);
      final assistant = _unfinishedAssistant(messages);
      if (assistant == null) return;
      final answered = _toolResultIds(messages);
      final runs = await _hub.chats.toolRunsForMessages([assistant.id]);
      final recovered = <String, Future<ToolResult> Function()>{};
      final parked = <ReopenedWait>[];
      final parkedCalls = <String>{};
      for (final run in runs) {
        final callId = await _callIdFor(run);
        if (answered.contains(callId)) continue;
        if (run.status == ToolRunStatus.waitingApproval ||
            run.status == ToolRunStatus.waitingUser) {
          final card = _ParkedCard(run);
          _parked[run.id] = card;
          parkedCalls.add(callId);
          parked.add(ReopenedWait(run, card.decision.future));
          continue;
        }
        // Живого процесса уже нет: StartupRecovery перевёл его в interrupted
        // либо запуск успел завершиться до записи в ленту. Повторно Host не трогаем.
        recovered[callId] = () async => _recoveredResult(run);
      }
      // Одни карточки — не работа. Ход поднимет открытие чата и сразу покажет их.
      // Иначе список чатов крутил бы спиннер у вопроса, которого ещё не видно.
      var executable = false;
      for (final call in assistant.toolCalls) {
        if (answered.contains(call.id) || parkedCalls.contains(call.id)) {
          continue;
        }
        executable = true;
        break;
      }
      if (!executable) {
        _parked.clear();
        return;
      }
      _running = true;
      final turn = _turnCancel = CancelToken();
      unawaited(
        _finishTurn(() async {
          final end = await _resumeMessage(
            assistant.id,
            parked,
            turn,
            recovered: recovered,
          );
          if (end != null) return end;
          return _loop(turn);
        }),
      );
    } finally {
      if (!gate.isCompleted) gate.complete();
      if (identical(_restoreInFlight, gate.future)) _restoreInFlight = null;
    }
  }

  /// Кладёт отложенные карточки в брокер. Регистрация синхронная: открытие чата
  /// сразу читает список, не дожидаясь ответа. Повторный вызов карточки не двоит.
  void _showParkedCards() {
    for (final card in _parked.values) {
      if (card.shown) continue;
      final reopened = _hub.tools.reopenWaiting(card.run);
      card.shown = true;
      unawaited(_forwardDecision(reopened.decision, card.decision));
    }
  }

  /// Ответ брокера завершает будущее, которого планировщик ждёт с момента старта.
  Future<void> _forwardDecision(
    Future<WaitingDecision> from,
    Completer<WaitingDecision> to,
  ) async {
    try {
      final decision = await from;
      if (!to.isCompleted) to.complete(decision);
    } on Object catch (error, stack) {
      if (!to.isCompleted) to.completeError(error, stack);
    }
  }

  /// Карточки, которые ещё не показаны, получают отказ или пустой ответ.
  /// Показанные закрывает [InteractionBroker.cancelChat]: он же завершит будущее.
  void _releaseParked() {
    for (final card in _parked.values) {
      if (card.shown || card.decision.isCompleted) continue;
      if (card.run.status == ToolRunStatus.waitingUser) {
        card.decision.complete(const WaitingDecision.question(null));
      } else {
        card.decision.complete(
          const WaitingDecision.approval(ApprovalDecision.deny()),
        );
      }
    }
  }

  /// Текст уже закончившегося запуска. Ошибка — всё, кроме обычного done:
  /// прерванный процесс модель должна увидеть как сбой, а не как успех.
  ToolResult _recoveredResult(ToolRun run) {
    final failed = run.status != ToolRunStatus.done;
    final preview = run.resultPreview;
    if (preview != null && preview.isNotEmpty) {
      return ToolResult(preview, isError: failed);
    }
    final output = run.outputText;
    if (output != null && output.isNotEmpty) {
      return ToolResult(output, isError: failed);
    }
    return const ToolResult(
      'interrupted: the application was closed while the run was active',
      isError: true,
    );
  }

  /// Продолжить после достижения лимита шагов.
  Future<void> continueAfterStepLimit() async {
    if (_running) return;
    _running = true;
    unawaited(_runTurn());
  }

  /// Edit N: восстанавливает состояние «ДО» N, удаляет N и всё после, отправляет новый текст.
  ///
  /// [attachments] заменяют вложения исходного сообщения. Null оставляет прежние — так правка
  /// меняет только текст. Если агент менял файлы в этом сообщении или позже, спрашивает об откате
  /// на Host. false — сообщения нет или пользователь отказался откатывать файлы, история не меняется.
  /// true — ход с новым текстом запущен.
  Future<bool> editUserMessage(
    String messageId,
    String newText, {
    List<AttachmentRef>? attachments,
  }) async {
    if (_running) throw StateError('cannot edit while the agent is running');
    final message = await _find(messageId);
    if (message == null || message.role != MessageRole.user) return false;
    if (!await _confirmFileChangesBeforeRewind(
      anchor: message,
      afterOnly: false,
    )) {
      return false;
    }
    await _truncate(message, fromSelf: true, restoreBefore: true);
    await submit(newText, attachments: attachments ?? message.attachments);
    return true;
  }

  /// Regenerate: удаляет ответы последнего хода и запускает его заново.
  ///
  /// Сообщение пользователя остаётся. Если агент менял файлы, вызывается тот же
  /// неявный откат, что и при edit: без отдельной кнопки отката в интерфейсе.
  /// false — истории нет или пользователь отменил откат файлов.
  Future<bool> regenerateLast() async {
    if (_running) {
      throw StateError('cannot regenerate while the agent is running');
    }
    final messages = await _hub.chats.messages(chatId);
    ChatMessage? user;
    for (final message in messages) {
      if (message.role == MessageRole.user) user = message;
    }
    if (user == null) return false;
    if (!await _confirmFileChangesBeforeRewind(
      anchor: user,
      afterOnly: false,
    )) {
      return false;
    }
    await _truncate(user, fromSelf: false, restoreBefore: false);
    _running = true;
    unawaited(_runTurn());
    return true;
  }

  /// Delete-after N: оставляет N, удаляет всё после, состояние — как после N.
  Future<void> deleteAfter(String messageId) async {
    if (_running) throw StateError('cannot delete while the agent is running');
    final message = await _find(messageId);
    if (message == null || message.role != MessageRole.user) return;
    if (!await _confirmFileChangesBeforeRewind(
      anchor: message,
      afterOnly: true,
    )) {
      return;
    }
    await _truncate(message, fromSelf: false, restoreBefore: false);
    _emit(AgentStateChanged(chatId));
  }

  /// Спрашивает об откате файлов на Host. false — пользователь отменил или откат не удался.
  Future<bool> _confirmFileChangesBeforeRewind({
    required ChatMessage anchor,
    required bool afterOnly,
  }) async {
    final messages = await _hub.chats.messages(chatId);
    final allTurns = await _hub.turnChangesets.forChat(chatId);
    final turnIds = turnIdsWithPendingFileChanges(
      messages: messages,
      allTurns: allTurns,
      anchorSeq: anchor.seq,
      afterOnly: afterOnly,
    );
    if (turnIds.isEmpty) return true;

    final newestFirst = turnIdsNewestFirst(
      messages: messages,
      turnIds: turnIds,
    );
    final oldestFirst = List<String>.of(newestFirst.reversed);
    final shellWarning = turnIds.any(
      (turnId) => allTurns[turnId]?.nonRecoverable ?? false,
    );
    final choice = await _hub.broker.requestEditFileChanges(
      EditFileChangesRequest(
        id: _uuid.v4(),
        chatId: chatId,
        files: aggregateEditFileChanges(
          allTurns: allTurns,
          turnIdsOldestFirst: oldestFirst,
        ),
        shellMayHaveChangedFiles: shellWarning,
      ),
    );
    if (choice == EditFileChangesChoice.cancel) return false;

    if (choice == EditFileChangesChoice.continueWithoutRollback) {
      await _hub.turnChangesets.markKeptOnEdit(chatId, turnIds);
      return true;
    }

    final chat = await _hub.chats.chat(chatId);
    if (chat == null) return false;
    final host = await _hub.hosts.byId(chat.hostId);
    if (host == null) return false;
    final runtime = _hub.runtimes.forHost(host);
    final cwd = commandWorkspace(host, chat.workspace);
    final result = await _hub.turnChangesets.rollbackTurnsNewestFirst(
      chatId: chatId,
      turnIdsNewestFirst: newestFirst,
      runtime: runtime,
      hostKind: host.kind,
      cwd: cwd,
    );
    if (!result.ok) {
      throw StateError(
        'file rollback failed: ${result.describe()}; '
        'history was not changed',
      );
    }
    _emit(AgentStateChanged(chatId));
    return true;
  }

  // ---- turn loop ---------------------------------------------------------

  /// Модель не найдена на сервере: перечитываем список, чтобы в чате сразу появилась отметка `!`.
  Future<void> _recheckCatalog() async {
    try {
      await _hub.models.refresh();
    } on Object catch (error) {
      _log.warning('catalog recheck after missing model failed: $error');
    }
  }

  Future<void> _runTurn() async {
    final turn = _turnCancel = CancelToken();
    await _finishTurn(() => _loop(turn));
  }

  /// Общая оболочка хода: событие старта, ошибка, финал и уведомление.
  /// И обычный ход, и продолжение после карточки заканчиваются здесь.
  Future<void> _finishTurn(Future<TurnEnd> Function() body) async {
    _emit(AgentTurnStarted(chatId));
    var end = TurnEnd.completed;
    try {
      end = await body();
    } on AppFailure catch (failure) {
      end = TurnEnd.failed;
      if (failure is LlmFailure && failure.modelNotFound) {
        await _recheckCatalog();
      }
      _emit(AgentFailureRaised(chatId, failure));
    } on Object catch (error, stack) {
      _log.severe('turn crashed', error, stack);
      end = TurnEnd.failed;
      _emit(AgentFailureRaised(chatId, LlmFailure('internal error: $error')));
    } finally {
      _running = false;
      _turnCancel = null;
      _stepCancel = null;
      // Решение уже записано в запуск. Следующее открытие читает базу, а не эту карту.
      _parked.clear();
      _emit(AgentTurnFinished(chatId, end));
    }
    // Stop пользователем уведомления не даёт: он сам знает, что остановил ход.
    switch (end) {
      case TurnEnd.completed:
        unawaited(_notify(AgentNoticeKind.turnFinished));
      case TurnEnd.failed:
        unawaited(_notify(AgentNoticeKind.turnFailed));
      case TurnEnd.stepLimit:
        unawaited(_notify(AgentNoticeKind.stepLimitReached));
      case TurnEnd.stopped:
    }
  }

  /// Дожидается карточек вместе с остальными вызовами того же сообщения,
  /// затем продолжает обычный цикл модели.
  Future<TurnEnd> _resumeThenLoop(
    List<ReopenedWait> items,
    CancelToken turn,
  ) async {
    final order = <String>[];
    final groups = <String, List<ReopenedWait>>{};
    for (final item in items) {
      groups
          .putIfAbsent(item.run.messageId, () {
            order.add(item.run.messageId);
            return [];
          })
          .add(item);
    }
    for (final messageId in order) {
      if (turn.isCancelled) {
        await _closeUnanswered(
          messageId,
          await _answeredToolCallIds(),
          'cancelled by the user',
        );
        return TurnEnd.stopped;
      }
      final end = await _resumeMessage(messageId, groups[messageId]!, turn);
      if (end != null) return end;
    }
    return _loop(turn);
  }

  /// Карточки [items] либо уже в брокере, либо отложены до открытия чата.
  /// [recovered] — запуски, которые после перезапуска живыми не являются:
  /// их результат пишется в ленту, Host повторно не вызывается.
  /// Остальные вызовы сообщения идут по плану, не дожидаясь чужого ответа.
  Future<TurnEnd?> _resumeMessage(
    String messageId,
    List<ReopenedWait> items,
    CancelToken turn, {
    Map<String, Future<ToolResult> Function()> recovered = const {},
  }) async {
    final message = await _find(messageId);
    final calls = [
      if (message != null && message.role == MessageRole.assistant)
        for (final call in message.toolCalls)
          LlmToolCall(id: call.id, name: call.name, arguments: call.arguments),
    ];
    final known = {for (final call in calls) call.id};
    final resumed = <String, Future<ToolResult> Function()>{};
    for (final item in items) {
      final callId = await _callIdFor(item.run);
      if (!known.contains(callId)) {
        final result = await _completeReopened(item);
        await _appendTool(callId, result);
        if (result.finish) return TurnEnd.completed;
        continue;
      }
      resumed[callId] = () => _completeReopened(item);
    }
    for (final entry in recovered.entries) {
      resumed.putIfAbsent(entry.key, () => entry.value);
    }
    if (calls.isEmpty) return null;
    final ctx = await _toolContext(messageId);
    if (ctx == null) {
      // Иначе отложенная карточка держит ход: показать её некому, хоста нет.
      _releaseParked();
      for (final entry in resumed.entries) {
        await _appendTool(entry.key, await entry.value());
      }
      await _closeUnanswered(
        messageId,
        await _answeredToolCallIds(),
        'not executed: host not found',
      );
      return TurnEnd.failed;
    }
    return _scheduleCalls(
      calls,
      ctx,
      turn,
      alreadyAnswered: await _answeredToolCallIds(),
      resumed: resumed,
    );
  }

  Future<ToolResult> _completeReopened(ReopenedWait item) async {
    final decision = await item.decision;
    final ctx = await _toolContext(item.run.messageId);
    return _hub.tools.completeWaiting(item.run, decision, ctx);
  }

  Future<void> _closeUnanswered(
    String messageId,
    Set<String> answered,
    String reason,
  ) async {
    final message = await _find(messageId);
    if (message == null) return;
    final calls = [
      for (final call in message.toolCalls)
        if (!answered.contains(call.id))
          LlmToolCall(id: call.id, name: call.name, arguments: call.arguments),
    ];
    await _answerRemaining(calls, 0, reason);
  }

  Future<Set<String>> _answeredToolCallIds() async {
    final messages = await _hub.chats.messages(chatId);
    return {
      for (final message in messages)
        if (message.role == MessageRole.tool && message.toolCallId != null)
          message.toolCallId!,
    };
  }

  /// Id вызова для результата. Новые запуски хранят его; старые ищем по имени и аргументам.
  Future<String> _callIdFor(ToolRun run) async {
    final stored = run.toolCallId;
    if (stored != null && stored.isNotEmpty) return stored;
    final message = await _find(run.messageId);
    if (message == null) return run.id;
    for (final call in message.toolCalls) {
      if (call.name == run.toolName && call.arguments == run.argsJson) {
        return call.id;
      }
    }
    if (message.toolCalls.length == 1) return message.toolCalls.single.id;
    return run.id;
  }

  /// Контекст инструмента без сборки запроса к модели: карточка уже задана, ход ещё не у модели.
  /// Проект и профиль политики те же, что у живого хода: иначе подтверждённый после
  /// перезапуска факт некуда писать, а остальные команды батча классифицируются
  /// глобальным профилем и без доверия skills.
  Future<ToolContext?> _toolContext(String messageId) async {
    final chat = await _hub.chats.chat(chatId);
    if (chat == null) return null;
    final host = await _hub.hosts.byId(chat.hostId);
    if (host == null) return null;
    final bound = await _executionContext(chat);
    final limits = await _hub.limits();
    return ToolContext(
      chat: bound.chat,
      messageId: messageId,
      turnUserMessageId: await _turnForAssistant(messageId),
      host: host,
      runtime: _hub.runtimes.forHost(host),
      limits: limits,
      policy: bound.policy,
      onBackgroundDone: _onBackgroundDone,
      project: bound.project,
    );
  }

  /// Пользовательское сообщение, которым открыт ход с ответом [assistantMessageId].
  ///
  /// Инструменты привязываются к последнему user-сообщению с меньшим seq, чем ответ
  /// ассистента (а не к последнему влитому из очереди).
  Future<String?> _turnForAssistant(String assistantMessageId) async {
    final messages = await _hub.chats.messages(chatId);
    ChatMessage? assistant;
    for (final message in messages) {
      if (message.id == assistantMessageId) assistant = message;
    }
    if (assistant == null) return null;
    ChatMessage? user;
    for (final message in messages) {
      if (message.role != MessageRole.user || message.seq >= assistant.seq) {
        continue;
      }
      if (user == null || message.seq > user.seq) user = message;
    }
    return user?.id;
  }

  /// Проект и политика хода. Общие для живого шага и возобновления, чтобы
  /// профиль проекта и доверие skills не зависели от того, перезапускали приложение или нет.
  Future<({Chat chat, Project? project, PolicyEngine policy})>
  _executionContext(Chat chat) async {
    var current = chat;
    var project = current.projectId == null
        ? null
        : await _hub.projectStore.byId(current.projectId!);
    if (project == null) {
      project = await _hub.projects.ensureForChat(current);
      if (project != null) {
        current = await _hub.chats.chat(chatId) ?? current;
      }
    }
    return (
      chat: current,
      project: project,
      policy: await _policyFor(current, project),
    );
  }

  /// Профиль проекта заменяет глобальный. Без проекта остаётся глобальный:
  /// у чата без папки своего профиля нет.
  Future<PolicyEngine> _policyFor(Chat chat, Project? project) async {
    final denylist = await _hub.settings.readDenylist();
    var profile = await _hub.settings.readSecurityProfile();
    final profileId = project?.policyProfileId;
    if (profileId != null) {
      final custom = await _hub.policyProfiles.byId(profileId);
      if (custom != null) profile = custom.profile;
    }
    return PolicyEngine(
      classifier: CommandClassifier(denylist: denylist, profile: profile),
      mode: chat.policyMode,
    );
  }

  /// Системное уведомление о событии этого чата. Название чата читается здесь, потому что
  /// оно принадлежит данным сессии. Сбой чтения или показа уведомление не ломает ход агента.
  Future<void> _notify(AgentNoticeKind kind, {String? detail}) async {
    try {
      final chat = await _hub.chats.chat(chatId);
      await _hub.notifier.notify(
        kind: kind,
        chatTitle: chat?.title ?? '',
        detail: detail,
      );
    } on Object catch (error) {
      _log.warning('notification skipped: $error');
    }
  }

  Future<TurnEnd> _loop(CancelToken turn) async {
    final limits = await _hub.limits();
    var steps = 0;
    var lengthContinues = 0;
    while (true) {
      if (turn.isCancelled) return TurnEnd.stopped;
      await _drainQueue();

      var prepared = await _prepare(limits);
      StepResult step;
      try {
        step = await _streamWithRetry(prepared.request, turn, limits);
      } on LlmFailure catch (failure) {
        // Запрос мог не поместиться в окно модели: пробуем один раз сжатие и повторяем
        // с уже пересобранным запросом. Второй такой ошибки не глотаем, иначе ход
        // будет бесконечно сжимать и повторять одно и то же.
        if (!failure.contextLengthExceeded || turn.isCancelled) rethrow;
        _emit(AgentTextDelta(chatId, '', reset: true));
        _emit(AgentReasoningDelta(chatId, '', reset: true));
        prepared = await _prepare(limits, forceCompact: true);
        step = await _streamWithRetry(prepared.request, turn, limits);
      }
      for (final id in prepared.inlineIds) {
        _inlineFiles.remove(id);
      }
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
        await _recordUsage(
          prepared.chat,
          prepared.model,
          step.usage!,
          prepared.limit,
        );
      }
      if (step.stopped || turn.isCancelled) return TurnEnd.stopped;
      if (step.interruptedBySendNow) continue;
      if (step.toolCalls.isEmpty) {
        if (_queue.isNotEmpty) continue;
        if (_isLengthFinish(step.finishReason)) {
          // Ответ упёрся в лимит вывода. Не выдаём его за полный: просим
          // продолжить, но не бесконечно. Событие остаётся в ленте и контексте.
          if (lengthContinues < _maxLengthContinues) {
            lengthContinues++;
            await _append(MessageRole.event, text: _lengthContinueText);
            continue;
          }
          await _append(MessageRole.event, text: _lengthFinalText);
        }
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
        turnUserMessageId: await _turnForAssistant(messageId),
        host: prepared.host,
        runtime: prepared.runtime,
        limits: limits,
        policy: prepared.policy,
        onBackgroundDone: _onBackgroundDone,
        project: prepared.project,
      );
      final scheduled = await _scheduleCalls(step.toolCalls, toolCtx, turn);
      if (scheduled != null) return scheduled;
    }
  }

  /// Батч вызовов одного шага. null — все результаты записаны, цикл модели продолжается.
  Future<TurnEnd?> _scheduleCalls(
    List<LlmToolCall> calls,
    ToolContext ctx,
    CancelToken turn, {
    Set<String> alreadyAnswered = const {},
    Map<String, Future<ToolResult> Function()> resumed = const {},
  }) async {
    final workspace = commandWorkspace(ctx.host, ctx.chat.workspace);
    final end = await ToolScheduler.run(
      calls: calls,
      workspace: workspace,
      policy: ctx.policy,
      hostKind: ctx.host.kind,
      cancel: turn,
      canonicalize: (path) =>
          _canonicalToolPath(ctx.runtime, path, cwd: workspace),
      alreadyAnswered: alreadyAnswered,
      resumed: resumed,
      execute: (call) => _hub.tools.execute(call, ctx),
      commit: (call, result) => _appendTool(call.id, result),
    );
    return switch (end) {
      ToolScheduleEnd.done => null,
      ToolScheduleEnd.finish => TurnEnd.completed,
      ToolScheduleEnd.cancelled => TurnEnd.stopped,
    };
  }

  /// Ключ файла на этом Host: `~` и симлинки раскрыты. null — планировщик
  /// не отличает путь от остальных файлов и не пускает запись рядом с ним.
  Future<String?> _canonicalToolPath(
    HostRuntime runtime,
    String path, {
    required String cwd,
  }) async {
    try {
      final run = await captureOp(runtime, CanonicalPathOp(path), cwd: cwd);
      if (!run.ok) return null;
      final text = run.stdout.trim();
      if (text.isEmpty || text.contains('\n')) return null;
      return text;
    } on Object {
      return null;
    }
  }

  Future<void> _appendTool(String callId, ToolResult result) => _append(
    MessageRole.tool,
    text: Redactor.redact(result.text),
    toolCallId: callId,
  );

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
    final bound = await _executionContext(chat);
    chat = bound.chat;
    var project = bound.project;
    final trustedSkills = project == null
        ? const <String>{}
        : await _hub.projectStore.trustedSkillNames(project.id);
    final snapshot = await _hub.workspace.load(
      chat,
      runtime,
      project: project,
      trustedSkills: trustedSkills,
    );
    // Новые skills появляются недоверенными: доверие выдаёт пользователь, а не содержимое папки.
    final foundSkills = [
      for (final skill in [...snapshot.skills, ...snapshot.untrustedSkills])
        skill.name,
    ];
    if (project != null &&
        await _hub.projectStore.syncSkills(project.id, foundSkills) &&
        !project.skillsInitialized) {
      project = project.copyWith(skillsInitialized: true);
      await _hub.projectStore.save(project);
    }
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
    final projectFacts = project == null
        ? const <ProjectFact>[]
        : await _hub.projectStore.facts(project.id);
    final hostStub = await _loadHostStub(host, runtime);
    final notes = _backgroundNotes();
    ContextInput inputFor(
      Chat current, {
      Map<String, List<LlmFilePart>> files = const {},
    }) => ContextInput(
      chat: current,
      host: host,
      messages: messages,
      state: state,
      workspace: snapshot,
      recentWindow: limits.recentWindowMessages,
      hostStub: hostStub,
      backgroundNotes: notes,
      inlineFiles: files,
      projectFacts: projectFacts,
    );
    // Лимит проверяем до сжатия: оно тоже тратит токены, а превышение должно
    // остановить ход, а не оплатить ещё одну сводку.
    final daily = await _hub.settings.readDailyUsage(chatId);
    final budget = await _hub.settings.readDailyBudget(chatId);
    if (budget != null && daily.costUsd >= budget) {
      throw LlmFailure(
        'daily spending limit reached: '
        '\$${daily.costUsd.toStringAsFixed(4)} of '
        '\$${budget.toStringAsFixed(2)} today',
      );
    }
    final cutoffBefore = chat.compactedUntilSeq;
    chat = await _hub.compactor.compactIfNeeded(
      inputFor(chat),
      summaryModel: model,
      force: forceCompact,
      limits: limits,
    );
    // Метаданные пишем только при реальном сдвиге границы: compactor возвращает
    // тот же чат, если сжимать было нечего.
    if (chat.compactedUntilSeq != cutoffBefore) {
      await _hub.settings.saveCompactionInfo(
        chatId,
        ChatCompactionInfo(
          at: DateTime.now(),
          reason: forceCompact ? 'forced' : 'threshold',
          cutoffSeq: chat.compactedUntilSeq,
          summaryChars: chat.compactionSummary?.length ?? 0,
        ),
      );
    }
    final inline = Map.of(_inlineFiles);
    _checkFilesAccepted(model, inline);
    final llmMessages = _hub.builder.build(inputFor(chat, files: inline));
    final limit = chat.contextLength ?? ContextCompactor.defaultContextLength;
    final tools = [...ToolCatalog.specs, ...SelfToolCatalog.specs];
    _emit(
      AgentUsageUpdated(
        chatId,
        ContextCompactor.estimate(llmMessages),
        limit,
        breakdown: ContextBreakdown.of(llmMessages, tools: tools),
        dailyCostUsd: daily.costUsd,
        dailyBudgetUsd: budget,
      ),
    );

    final policy = bound.policy;
    return _Prepared(
      chat: chat,
      host: host,
      runtime: runtime,
      policy: policy,
      limit: limit,
      model: model,
      inlineIds: inline.keys.toList(),
      project: project,
      request: LlmRequest(model: model, messages: llmMessages, tools: tools),
    );
  }

  /// Файлы в запросе допустимы только для модели, которая принимает их тип (см. [ModelCatalogState.acceptsFile]).
  void _checkFilesAccepted(
    String model,
    Map<String, List<LlmFilePart>> inline,
  ) {
    for (final files in inline.values) {
      for (final file in files) {
        if (!_hub.models.state.acceptsFile(model, file.mimeType)) {
          throw LlmFailure(
            'model $model does not accept ${file.mimeType} input; choose another model',
          );
        }
      }
    }
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
    String? finishReason;
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
                finishReason = e.finishReason;
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
      finishReason: finishReason,
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
      _notify(AgentNoticeKind.backgroundFinished, detail: outcome.status.name),
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
    final files = [
      for (final a in prompt.attachments)
        if (a.mode == AttachmentMode.file && a.bytes != null)
          LlmFilePart(
            name: a.name,
            mimeType: a.mimeType ?? 'application/octet-stream',
            bytes: a.bytes!,
          ),
    ];
    if (files.isNotEmpty) _inlineFiles[messageId] = files;
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
    final run = await captureOp(runtime, const HostInfoOp());
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

  Future<void> _recordUsage(
    Chat chat,
    String model,
    LlmUsage usage,
    int limit,
  ) async {
    final cost = _costOf(model, usage);
    final daily = await _hub.settings.addDailyUsage(
      chatId,
      promptTokens: usage.promptTokens,
      completionTokens: usage.completionTokens,
      costUsd: cost ?? 0,
    );
    final budget = await _hub.settings.readDailyBudget(chatId);
    final current = await _hub.chats.chat(chatId) ?? chat;
    await _hub.chats.saveChat(
      current.copyWith(
        lastPromptTokens: usage.promptTokens,
        lastCompletionTokens: usage.completionTokens,
      ),
    );
    _emit(
      AgentUsageUpdated(
        chatId,
        usage.promptTokens,
        limit,
        dailyCostUsd: daily.costUsd,
        dailyBudgetUsd: budget,
      ),
    );
  }

  /// Стоимость одного ответа по ценам каталога. Цены OpenRouter — за токен.
  /// Null, если каталог ещё не знает модель: тогда расход не оценивается.
  double? _costOf(String model, LlmUsage usage) {
    final info = _hub.models.state.modelOf(model);
    final prompt = double.tryParse(info?.promptPrice ?? '');
    final completion = double.tryParse(info?.completionPrice ?? '');
    if (prompt == null || completion == null) return null;
    return prompt * usage.promptTokens + completion * usage.completionTokens;
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
    // Сводка могла покрывать удалённые сообщения. Оставлять её и старую границу нельзя:
    // после правки раннего сообщения cutoff может оказаться больше всех оставшихся seq,
    // и модель получит только устаревшую сводку вместо диалога. Перечитываем чат:
    // restoreBefore/restoreAfter уже могли сохранить новый currentRevisionId.
    if (chat.compactedUntilSeq > fromSeq - 1) {
      final current = await _hub.chats.chat(chatId) ?? chat;
      await _hub.chats.saveChat(
        current.copyWith(clearCompactionSummary: true, compactedUntilSeq: 0),
      );
    }
    // Правка хода не должна оставлять выданные им разрешения.
    _hub.broker.clearTurnGrants(message.id);
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

  /// Провайдеры называют лимит вывода по-разному: `length` у OpenRouter,
  /// `max_tokens` у некоторых совместимых API.
  static bool _isLengthFinish(String? reason) {
    final value = reason?.toLowerCase();
    return value != null &&
        (value.contains('length') || value.contains('max_tokens'));
  }

  void _emit(AgentEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  Future<void> dispose() async {
    await _runSub.cancel();
    await _waitSub.cancel();
    await _questionSub.cancel();
    await _changesetSub.cancel();
    await _events.close();
  }
}

/// Последний ответ модели, у которого не каждый вызов уже есть в ленте.
ChatMessage? _unfinishedAssistant(List<ChatMessage> messages) {
  final answered = _toolResultIds(messages);
  ChatMessage? open;
  for (final message in messages) {
    if (message.role != MessageRole.assistant || message.toolCalls.isEmpty) {
      continue;
    }
    for (final call in message.toolCalls) {
      if (answered.contains(call.id)) continue;
      open = message;
      break;
    }
  }
  return open;
}

/// Id вызовов, для которых в ленте уже лежит результат.
Set<String> _toolResultIds(List<ChatMessage> messages) => {
  for (final message in messages)
    if (message.role == MessageRole.tool && message.toolCallId != null)
      message.toolCallId!,
};

/// Подтверждение или вопрос, который старт приложения не кладёт в брокер.
class _ParkedCard {
  _ParkedCard(this.run) : decision = Completer<WaitingDecision>();

  final ToolRun run;
  final Completer<WaitingDecision> decision;

  /// Уже передана в брокер. Повторное открытие чата карточку не регистрирует снова.
  var shown = false;
}

class _Prepared {
  const _Prepared({
    required this.chat,
    required this.host,
    required this.runtime,
    required this.policy,
    required this.limit,
    required this.model,
    required this.inlineIds,
    required this.request,
    this.project,
  });

  final Chat chat;
  final Host host;
  final HostRuntime runtime;
  final PolicyEngine policy;
  final int limit;
  final String model;

  /// Проект чата. Null, пока у чата нет явной папки: дом общим проектом не становится.
  final Project? project;

  /// Сообщения, чьи файлы входят в этот запрос; после ответа модели их байты освобождаются.
  final List<String> inlineIds;
  final LlmRequest request;
}

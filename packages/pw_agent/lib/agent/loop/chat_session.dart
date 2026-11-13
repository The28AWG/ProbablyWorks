import 'dart:async';

import 'package:logging/logging.dart';
import 'package:pw_agent/agent/context/context_breakdown.dart';
import 'package:pw_agent/agent/context/context_builder.dart';
import 'package:pw_agent/agent/context/context_compactor.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/project.dart';
import 'package:pw_agent/agent/exec/command_executor.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/agent/loop/chat_title.dart';
import 'package:pw_agent/agent/loop/prompt_queue.dart';
import 'package:pw_agent/agent/loop/tool_scheduler.dart';
import 'package:pw_agent/agent/policy/command_classifier.dart';
import 'package:pw_agent/agent/policy/policy_engine.dart';
import 'package:pw_agent/agent/subagent/subagent_manager.dart';
import 'package:pw_agent/agent/tools/tool_executor.dart';
import 'package:pw_agent/agent/turn/turn_changeset_logic.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/core/data/chat_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/domain/chat_usage.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/core/notify/app_notifier.dart';
import 'package:pw_agent/core/util/cancel_token.dart';
import 'package:pw_agent/core/util/redactor.dart';
import 'package:pw_agent/core/util/text_clip.dart';
import 'package:pw_agent/core/util/workspace_path.dart';
import 'package:pw_agent/host/host_capture.dart';
import 'package:pw_agent/host/host_op.dart';
import 'package:pw_agent/host/host_runtime.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/src/agent/loop/agent_hub.dart';
import 'package:uuid/uuid.dart';

part 'chat_session_turn.dart';
part 'chat_session_context.dart';
part 'chat_session_runtime.dart';
part 'chat_session_history.dart';

part 'chat_session_models.dart';

/// Ход агента одного чата: очередь ввода, цикл модели и инструментов, Stop, edit/delete-after.
/// Одновременно выполняется не более одного хода; ввод во время хода уходит в очередь.
class ChatSession {
  ChatSession(this.chatId, this._hub, [this._onEvent]) {
    _runSub = _hub.tools.runChanges
        .where((run) => run.chatId == chatId)
        .listen((run) => _emit(AgentRunChanged(chatId, run)));
    // Ожидание пользователя должно быть заметно, даже если окно приложения не в фокусе.
    _waitSub = _hub.broker.approvalRequests
        .where((r) => r.chatId == chatId)
        .listen(
          (request) => unawaited(
            _notify(AgentNoticeKind.approvalNeeded, approvalId: request.id),
          ),
        );
    _questionSub = _hub.broker.questions
        .where((q) => q.chatId == chatId)
        .listen((_) => unawaited(_notify(AgentNoticeKind.questionAsked)));
    _changesetSub = _hub.turnChangesets.changes
        .where((cs) => cs.chatId == chatId)
        .listen((cs) => _emit(AgentTurnChangesetChanged(chatId, cs)));
  }

  final String chatId;
  final AgentHub _hub;

  /// Общий поток событий хаба. Отдельный callback, а не подписка на [events]:
  /// иначе [hasEventListeners] всегда был бы true и сессию нельзя было бы
  /// вытеснить, когда открытый чат уже закрыт.
  final void Function(AgentEvent)? _onEvent;

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

  /// Модель, на которую ход переключился из-за fallback. Сбрасывается на новом ходе.
  String? _modelOverride;

  late final StreamSubscription _changesetSub;

  /// Повторный вход в открытие чата ждёт ту же регистрацию карточек, а не вторую.
  Future<void>? _restoreInFlight;

  /// Карточки, которые ход уже ждёт, но в брокер ещё не положил.
  /// Открытие чата их показывает. До этого зависимый вызов стоит, а независимый идёт.
  final Map<String, _ParkedCard> _parked = {};

  /// История, прочитанная в текущем ходе. Внутри одного хода сообщения пишет
  /// только эта сессия, поэтому повторные чтения на каждом шаге не нужны.
  /// Вне хода кэш пуст: edit/delete и внешние изменения читают базу заново.
  List<ChatMessage>? _turnHistory;

  /// Идёт ход, в котором разрешён кэш [_turnHistory].
  bool _historyWarm = false;

  Stream<AgentEvent> get events => _events.stream;

  bool get isRunning => _running;

  List<QueuedPrompt> get queue => _queue.items;

  /// Есть ли подписчик на события этой сессии (локальный UI или API-адаптер).
  bool get hasEventListeners => _events.hasListener;

  /// Сессию можно безопасно вытеснить: она не выполняет ход, не держит очередь,
  /// карточки, вложения, фоновые процессы или субагентов и никто не слушает её
  /// события. Иначе новый экземпляр потерял бы наблюдаемое состояние.
  bool get canEvict =>
      !_running &&
      !hasEventListeners &&
      _queue.isEmpty &&
      _parked.isEmpty &&
      _inlineFiles.isEmpty &&
      _restoreInFlight == null &&
      _hub.registry.forChat(chatId).isEmpty &&
      !_hub.broker.waitingChatIds.contains(chatId) &&
      _hub.subagents.activeFor(chatId).isEmpty;

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
    await _hub.subagents.stopChildren(chatId);
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
      await _showParkedCards();
      return;
    }
    final inflight = _restoreInFlight;
    if (inflight != null) {
      await inflight;
      // Ход уже идёт: карточки, отложенные стартом, пора показать.
      // Ход не стартовал (в шаге были только карточки) — идём обычным путём ниже.
      if (_running) {
        await _showParkedCards();
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
      final reopened = <ReopenedWait>[];
      for (final run in runs) {
        reopened.add(await _hub.tools.reopenWaiting(run));
      }
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
      final messages = await _messages();
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
  Future<void> _showParkedCards() async {
    for (final card in _parked.values) {
      if (card.shown) continue;
      card.shown = true;
      await _showParkedCard(card);
    }
  }

  Future<void> _showParkedCard(_ParkedCard card) async {
    final reopened = await _hub.tools.reopenWaiting(card.run);
    unawaited(_forwardDecision(reopened.decision, card.decision));
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
    final messages = await _messages();
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
    final messages = await _messages();
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

  void _emit(AgentEvent event) {
    _onEvent?.call(event);
    if (!_events.isClosed) _events.add(event);
  }

  Future<void> dispose() async {
    await _runSub.cancel();
    await _waitSub.cancel();
    await _questionSub.cancel();
    await _changesetSub.cancel();
    await _events.close();
  }

  /// Доставляет фоновое событие в чат. Если ход идёт — ставит в очередь,
  /// иначе добавляет событие и запускает новый ход.
  Future<void> deliverEvent(String text) => _deliverEvent(text);
}

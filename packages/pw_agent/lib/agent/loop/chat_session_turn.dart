part of 'chat_session.dart';

extension _ChatSessionTurn on ChatSession {
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
    _historyWarm = true;
    _turnHistory = null;
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
      _historyWarm = false;
      _turnHistory = null;
      // Решение уже записано в запуск. Следующее открытие читает базу, а не эту карту.
      _parked.clear();
      _emit(AgentTurnFinished(chatId, end));
    }
    // Stop пользователем уведомления не даёт: он сам знает, что остановил ход.
    switch (end) {
      case TurnEnd.completed:
        unawaited(_notify(AgentNoticeKind.turnFinished));
        // Память обновляется в фоне: ход уже завершён и ответ пользователю отдан.
        unawaited(_updateProjectMemory());
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
    final messages = await _messages();
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
    final messages = await _messages();
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
  Future<void> _notify(
    AgentNoticeKind kind, {
    String? detail,
    String? approvalId,
  }) async {
    try {
      final chat = await _hub.chats.chat(chatId);
      await _hub.notifier.notify(
        kind: kind,
        chatTitle: chat?.title ?? '',
        detail: detail,
        chatId: chatId,
        approvalId: approvalId,
      );
    } on Object catch (error) {
      _log.warning('notification skipped: $error');
    }
  }

  Future<TurnEnd> _loop(CancelToken turn) async {
    _modelOverride = null;
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
          step.model ?? prepared.model,
          step.usage!,
          prepared.limit,
        );
      }
      if (step.model != null && step.model != prepared.model) {
        await _append(MessageRole.event, text: 'model fallback: ${step.model}');
      }
      if (step.stopped || turn.isCancelled) return TurnEnd.stopped;
      if (step.interruptedBySendNow) continue;
      if (step.toolCalls.isEmpty) {
        if (_queue.isNotEmpty) continue;
        if (_isLengthFinish(step.finishReason)) {
          // Ответ упёрся в лимит вывода. Не выдаём его за полный: просим
          // продолжить, но не бесконечно. Событие остаётся в ленте и контексте.
          if (lengthContinues < ChatSession._maxLengthContinues) {
            lengthContinues++;
            await _append(
              MessageRole.event,
              text: ChatSession._lengthContinueText,
            );
            continue;
          }
          await _append(MessageRole.event, text: ChatSession._lengthFinalText);
        }
        await _notifyActiveSubagents();
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
      if (scheduled != null) {
        if (scheduled == TurnEnd.completed) await _notifyActiveSubagents();
        return scheduled;
      }
    }
  }

  /// Мягко напоминает, что часть работы ещё идёт в фоне. Ход не блокируем.
  Future<void> _notifyActiveSubagents() async {
    final active = _hub.subagents.activeFor(chatId);
    if (active.isEmpty) return;
    await _append(
      MessageRole.event,
      text:
          '${active.length} subagent(s) are still running; '
          'their results will arrive as events.',
    );
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
}

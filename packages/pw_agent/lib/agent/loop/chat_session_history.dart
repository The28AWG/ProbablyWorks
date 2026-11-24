part of 'chat_session.dart';

extension _ChatSessionHistory on ChatSession {
  // ---- persistence -------------------------------------------------------

  /// Сохраняет пользовательский промпт и открывает новую ревизию состояния.
  ///
  /// Пока идёт запись, [clientMessageId] держится в
  /// [_persistingClientMessages]: повторный запрос не должен создать дубль,
  /// пока элемент уже ушёл из очереди, а сообщение ещё нет в БД.
  Future<void> _persistPrompt(QueuedPrompt prompt) async {
    final clientMessageId = prompt.clientMessageId;
    if (clientMessageId != null) {
      _persistingClientMessages.add(clientMessageId);
    }
    try {
      final chat = await _hub.chats.chat(chatId);
      if (chat == null) return;
      // Заметка идёт отдельным событием: текст пользователя остаётся тем, что
      // было запланировано, а модель и лента видят причину опоздания.
      final note = prompt.note;
      if (note != null) await _append(MessageRole.event, text: note);
      final messageId = ChatSession._uuid.v4();
      final revisions = await _hub.state.onUserMessage(chat, messageId);
      await _append(
        MessageRole.user,
        id: messageId,
        text: prompt.text,
        attachments: prompt.attachments,
        mentions: prompt.mentions,
        clientMessageId: clientMessageId,
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
    } finally {
      if (clientMessageId != null) {
        _persistingClientMessages.remove(clientMessageId);
      }
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
    List<MentionRef> mentions = const [],
    String? clientMessageId,
    String? openedRevisionId,
    String? sealedBeforeRevisionId,
  }) async {
    final seq = await _hub.chats.nextSeq(chatId);
    final message = ChatMessage(
      id: id ?? ChatSession._uuid.v4(),
      chatId: chatId,
      clientMessageId: clientMessageId,
      seq: seq,
      role: role,
      createdAt: DateTime.now(),
      text: text,
      reasoning: reasoning,
      toolCalls: toolCalls,
      toolCallId: toolCallId,
      attachments: attachments,
      mentions: mentions,
      openedRevisionId: openedRevisionId,
      sealedBeforeRevisionId: sealedBeforeRevisionId,
    );
    await _hub.chats.insertMessage(message);
    if (_historyWarm) _turnHistory?.add(message);
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
    int limit, {
    required bool contextWindowKnown,
    ContextBreakdown? breakdown,
  }) async {
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
    // Точное значение получено: до конца хода оценка для этой модели больше
    // не показывается. Следующий ход снова начнёт с оценки, потому что
    // контекст к тому моменту изменится.
    _exactUsageModels.add(model);
    _emit(
      AgentUsageUpdated(
        chatId,
        usage.promptTokens,
        limit,
        contextWindowKnown: contextWindowKnown,
        breakdown: breakdown,
        dailyCostUsd: daily.costUsd,
        dailyBudgetUsd: budget,
      ),
    );
  }

  /// Расход служебного запроса (сводки истории). В отличие от [_recordUsage]
  /// не меняет последний размер контекста: сводка не является запросом хода,
  /// и показывать её токены в чипе нельзя.
  Future<void> _recordUtilityUsage(String model, LlmUsage usage) async {
    await _hub.settings.addDailyUsage(
      chatId,
      promptTokens: usage.promptTokens,
      completionTokens: usage.completionTokens,
      costUsd: _costOf(model, usage) ?? 0,
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

  /// Сообщения текущего хода с кэшем на один ход. Вне хода всегда читает базу,
  /// поэтому edit/delete/regenerate видят актуальную историю.
  Future<List<ChatMessage>> _messages() async {
    if (!_historyWarm) return _hub.chats.messages(chatId);
    final cached = _turnHistory;
    if (cached != null) return cached;
    final loaded = await _hub.chats.messages(chatId);
    _turnHistory = loaded;
    return loaded;
  }

  Future<ChatMessage?> _find(String messageId) async {
    for (final message in await _messages()) {
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
    // Заметка о просроченной задаче стоит отдельным событием перед промптом.
    // При правке промпта она уходит вместе с ним, иначе описывает доставку,
    // которой больше нет.
    if (fromSelf) {
      for (final previous in await _messages()) {
        if (previous.seq != message.seq - 1) continue;
        if (previous.role != MessageRole.event) continue;
        if (!previous.text.startsWith(scheduledTaskLateNotePrefix)) continue;
        await _hub.chats.deleteMessage(previous.id);
      }
    }
    final ids = await _hub.chats.deleteMessagesFrom(chatId, fromSeq);
    _turnHistory = null;
    final runs = await _hub.chats.toolRunsForMessages(ids);
    for (final run in runs) {
      await _hub.logs.deleteFile(run.logPath);
    }
    await _hub.chats.deleteToolRuns([for (final r in runs) r.id]);
    // Отложенная задача живёт вместе со своим шагом: исчез шаг — исчезает и
    // она. Иначе напоминание осталось бы без сообщения, которое его объясняет.
    final taskIds = <String>[];
    for (final run in runs) {
      final taskId = ScheduledTaskRepository.taskIdOfRun(run);
      if (taskId != null) taskIds.add(taskId);
    }
    // Строки без шага (созданные до появления шагов в журнале) удаляются по
    // времени: они относятся к переписываемой части, если появились позже
    // самого сообщения. Строгая граница: одинаковое время при точности в
    // секунду скорее значит «предыдущий ход», такую задачу сохраняем.
    // Оставшиеся запуски показывают, у кого шаг есть.
    final referenced = <String>{};
    for (final run in await _hub.chats.toolRunsForChat(chatId)) {
      final id = ScheduledTaskRepository.taskIdOfRun(run);
      if (id != null) referenced.add(id);
    }
    for (final task in await _hub.scheduledTasks.forChat(chatId)) {
      if (referenced.contains(task.id)) continue;
      if (!task.createdAt.isAfter(message.createdAt)) continue;
      taskIds.add(task.id);
    }
    await _hub.scheduledTasks.deleteByIds(taskIds);
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
}

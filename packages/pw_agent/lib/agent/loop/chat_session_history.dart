part of 'chat_session.dart';

extension _ChatSessionHistory on ChatSession {
  // ---- persistence -------------------------------------------------------

  /// Сохраняет пользовательский промпт и открывает новую ревизию состояния.
  Future<void> _persistPrompt(QueuedPrompt prompt) async {
    final chat = await _hub.chats.chat(chatId);
    if (chat == null) return;
    final messageId = ChatSession._uuid.v4();
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
      id: id ?? ChatSession._uuid.v4(),
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
    final ids = await _hub.chats.deleteMessagesFrom(chatId, fromSeq);
    _turnHistory = null;
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
}

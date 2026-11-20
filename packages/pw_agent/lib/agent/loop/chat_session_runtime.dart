part of 'chat_session.dart';

extension _ChatSessionRuntime on ChatSession {
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
    final result = outcome.resultError ? ', result error' : '';
    final retained = outcome.outputTruncated
        ? ' (tail kept; earlier output dropped)'
        : '';
    // Событие — это уведомление, а не результат: полный вывод лежит в буфере
    // запуска, и модель сама решает, читать его кусками или искать по строкам.
    final text =
        'Background command ${run.id} finished with status '
        '${outcome.status.name}$result$exit.\n'
        'Command: ${Redactor.redact(run.command ?? run.toolName)}\n'
        'Output: ${outcome.outputText.characters.length} chars retained'
        '$retained.\n'
        'Retained output: read_run_output run_id=${run.id} '
        '(mode=tail default, mode=chunk with offset/limit, '
        'mode=grep with pattern).\n'
        'Tail:\n'
        '${TextClip.tail(outcome.outputText, maxChars: 2000)}';
    unawaited(
      _notify(
        AgentNoticeKind.backgroundFinished,
        detail: outcome.resultError
            ? '${outcome.status.name}, result error'
            : outcome.status.name,
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
    _beginTurn();
    await _append(MessageRole.event, text: text);
    unawaited(_runTurn());
  }

  // ---- title -------------------------------------------------------------

  /// Запускает memory-цикл проекта. Ошибки не должны влиять на завершённый ход.
  Future<void> _updateProjectMemory() async {
    // В фоновом прогоне база закрывается сразу после хода, а обновление памяти
    // требует сети и времени: оно подождёт следующего обычного хода.
    if (!_hub.memoryUpdatesEnabled) return;
    try {
      await _hub.memory.updateAfterTurn(chatId);
    } on Object catch (error, stack) {
      _log.warning('project memory update failed', error, stack);
    }
  }

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
        // Заголовок — служебный вызов: не тратим рассуждения, но не ломаем
        // mandatory-модели, которым нельзя передать none.
        reasoning: resolveUtilityReasoning(_reasoningCapabilityOf(model)),
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
}

part of 'chat_session.dart';

extension _ChatSessionContext on ChatSession {
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
        _modelOverride ??
        chat.model ??
        await _hub.settings.read(SettingsRepository.keyDefaultModel);
    if (model == null || model.isEmpty) {
      throw const LlmFailure('model is not selected');
    }
    _ensureModelSupportsTools(model);

    final state = await _hub.state.current(chat);
    final messages = await _messages();
    final projectMemory = project == null
        ? null
        : await _hub.projectStore.memory(project.id);
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
      projectMemory: projectMemory,
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
    final llmMessages = [..._hub.builder.build(inputFor(chat, files: inline))];
    final activeSubagents = _hub.subagents.activeFor(chatId);
    if (activeSubagents.isNotEmpty) {
      llmMessages.add(LlmMessage.system(_subagentContext(activeSubagents)));
    }
    final limit = chat.contextLength ?? ContextCompactor.defaultContextLength;
    // Первый запрос подключает включённые MCP-серверы и плагины.
    await _hub.mcp.ensureReady();
    await _hub.plugins.ensureReady();
    final tools = _hub.tools.specs;
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

  static String _subagentContext(List<SubagentRun> runs) {
    final buffer = StringBuffer('Active subagents started in this chat:');
    for (final run in runs) {
      buffer
        ..write('\n- ${run.id}: ${run.title} (model ${run.model})')
        ..write(' [running]');
    }
    buffer.write(
      '\nResults are delivered as events. '
      'Use wait_subagent(runId) if you need a result now.',
    );
    return buffer.toString();
  }

  /// Не отправляет инструменты модели, про которую каталог точно знает, что
  /// tool calling она не поддерживает.
  void _ensureModelSupportsTools(String model) {
    final live = _hub.models.state.modelOf(model);
    // Если модели нет в живом каталоге, её мог удалить провайдер: не блокируем
    // запрос, чтобы сработали 404 и fallback. Проверяем только известную модель.
    if (live == null) return;
    if (!live.supportsTools) {
      throw LlmFailure(
        'model $model does not support tools; choose another model',
      );
    }
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
    LlmRequest initial,
    CancelToken turn,
    AppLimits limits,
  ) async {
    var request = initial;
    var attempt = 0;
    var fallbackUsed = false;
    while (true) {
      try {
        return await _streamOnce(request, turn, limits);
      } on LlmFailure catch (failure) {
        if (turn.isCancelled) return const StepResult(text: '', stopped: true);
        final canFallback = failure.modelNotFound || failure.statusCode == 404;
        final retriesExhausted =
            failure.retryable && attempt >= ChatSession._maxRetries;
        if (!fallbackUsed && (canFallback || retriesExhausted)) {
          final fallback = await _fallbackModel(request.model);
          if (fallback != null) {
            _log.warning(
              'switching to fallback model $fallback: ${failure.message}',
            );
            _emit(AgentTextDelta(chatId, '', reset: true));
            _emit(AgentReasoningDelta(chatId, '', reset: true));
            _modelOverride = fallback;
            request = _withModel(request, fallback);
            fallbackUsed = true;
            attempt = 0;
            continue;
          }
        }
        if (!failure.retryable || attempt >= ChatSession._maxRetries) rethrow;
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

  Future<String?> _fallbackModel(String primary) async {
    final configured =
        await _hub.settings.read(SettingsRepository.keyFallbackModel) ?? '';
    if (configured.isEmpty || configured == primary) return null;
    final live = _hub.models.state.modelOf(configured);
    final saved = _hub.models.state.saved[configured];
    if (live == null && saved == null) {
      _log.warning('fallback model is unavailable: $configured');
      return null;
    }
    if (!(live?.supportsTools ?? saved?.supportsTools ?? false)) {
      _log.warning('fallback model has no tool calling: $configured');
      return null;
    }
    return configured;
  }

  static LlmRequest _withModel(LlmRequest request, String model) => LlmRequest(
    model: model,
    messages: request.messages,
    tools: request.tools,
    maxTokens: request.maxTokens,
    temperature: request.temperature,
    skipReasoning: request.skipReasoning,
  );

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
      model: request.model,
    );
  }
}

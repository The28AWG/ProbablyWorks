part of 'chat_session.dart';

extension _ChatSessionContext on ChatSession {
  Future<_Prepared> _prepare(
    AppLimits limits, {
    CompactionReason? forceReason,
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
    // Снимок workspace переиспользуется в пределах хода: сканирование skills и
    // поиск AGENTS.md — это операции на Host. После инструмента, который мог
    // изменить файлы, снимок помечен грязным и читается заново.
    final snapshot = _workspaceDirty || _workspaceSnapshot == null
        ? await _hub.workspace.load(
            chat,
            runtime,
            project: project,
            trustedSkills: trustedSkills,
          )
        : _workspaceSnapshot!;
    _workspaceSnapshot = snapshot;
    // Пока каталог не доверен, снимок перечитывается на каждом шаге: доверие
    // могут выдать прямо во время хода, и тогда AGENTS.md должен появиться.
    _workspaceDirty = snapshot.needsTrust;
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
    final reasoningPreference = chat.reasoning == ReasoningPreference.inherit
        ? await _hub.settings.readReasoning(
            SettingsRepository.keyDefaultReasoning,
          )
        : chat.reasoning;
    final reasoning = resolveReasoning(
      capability: _reasoningCapabilityOf(model),
      preference: reasoningPreference,
    );

    final state = await _hub.state.current(chat);
    final messages = await _messages();
    final projectMemory = project == null
        ? null
        : await _hub.projectStore.memory(project.id);
    final hostStub = await _loadHostStub(host, runtime);
    final notes = _backgroundNotes();
    // Лимит проверяем до сжатия и до подключения MCP: оно тоже тратит токены,
    // а превышение должно остановить ход, а не оплатить ещё одну сводку.
    var daily = await _hub.settings.readDailyUsage(chatId);
    final budget = await _hub.settings.readDailyBudget(chatId);
    if (budget != null && daily.costUsd >= budget) {
      throw LlmFailure(
        'daily spending limit reached: '
        '\$${daily.costUsd.toStringAsFixed(4)} of '
        '\$${budget.toStringAsFixed(2)} today',
      );
    }
    // MCP и плагины подключаются до сборки: их схемы инструментов входят в
    // запрос, а значит и в оценку бюджета. Иначе сжатие срабатывало бы позже
    // фактического заполнения окна. Подготовка идемпотентна, поэтому в пределах
    // хода достаточно одного раза.
    if (!_servicesReadyForTurn) {
      await _hub.mcp.ensureReady();
      await _hub.plugins.ensureReady();
      _servicesReadyForTurn = true;
    }
    // В скрытом чате субагента нет инструментов расписания: их не показываем.
    final tools = _hub.tools.specsFor(chat);
    // Окно берём у фактически используемой модели, а не только из поля чата:
    // чат с моделью по умолчанию своего окна не хранит. Если размер неизвестен
    // ни каталогу, ни чату, не выдаём 128k за факт: работаем от консервативного
    // значения и показываем пометку, иначе сжатие сработает уже после отказа.
    final knownLimit =
        _hub.models.state.modelOf(model)?.contextLength ??
        _hub.models.state.saved[model]?.contextLength ??
        chat.contextLength;
    final contextWindowKnown = knownLimit != null;
    final limit = knownLimit ?? ContextCompactor.defaultContextLength;
    if (!contextWindowKnown) {
      _log.warning('context window unknown for $model; assuming $limit tokens');
    }
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
      limits: limits,
      contextLimit: limit,
      hostStub: hostStub,
      backgroundNotes: notes,
      inlineFiles: files,
      tools: tools,
      projectMemory: projectMemory,
    );
    // Вложения текущего запроса входят в бюджет: решение о сжатии должно
    // видеть тот же запрос, который уйдёт провайдеру.
    final inline = Map.of(_inlineFiles);
    // Сжатие — служебный проход: дорогая модель чата для него не нужна.
    // Берём модель памяти (она же «служебная»), иначе модель чата.
    final summaryModel = await _utilityModel(model);
    final compaction = await _hub.compactor.compactIfNeeded(
      inputFor(chat, files: inline),
      summaryModel: summaryModel,
      summaryReasoning: resolveUtilityReasoning(
        _reasoningCapabilityOf(summaryModel),
      ),
      forceReason: forceReason,
      limits: limits,
    );
    chat = compaction.chat;
    if (compaction.reason case final reason?) {
      // Сжатие уменьшило контекст: последнее точное значение устарело,
      // следующий запрос снова начнёт с оценки.
      _exactUsageModels.remove(model);
      await _hub.settings.saveCompactionInfo(
        chatId,
        ChatCompactionInfo(
          at: DateTime.now(),
          reason: reason.name,
          cutoffSeq: chat.compactedUntilSeq,
          summaryChars: chat.compactionSummary?.length ?? 0,
        ),
      );
    }
    if (compaction.usage case final usage?) {
      // Сводка — такой же расход, как ответ модели, но не последний размер
      // контекста: в чипе и в lastPromptTokens она не участвует.
      await _recordUtilityUsage(summaryModel, usage);
      daily = await _hub.settings.readDailyUsage(chatId);
    }
    _checkFilesAccepted(model, inline);
    final llmMessages = [..._hub.builder.build(inputFor(chat, files: inline))];
    final activeSubagents = _hub.subagents.activeFor(chatId);
    if (activeSubagents.isNotEmpty) {
      llmMessages.add(LlmMessage.system(_subagentContext(activeSubagents)));
    }
    _logContextMetrics(llmMessages: llmMessages, tools: tools, limit: limit);
    // Если провайдер уже присылал точный usage в этом ходе, оценка не нужна:
    // она только давала бы скачки в чипе. Пока точного значения нет — это
    // единственный доступный источник.
    if (!_exactUsageModels.contains(model)) {
      _emit(
        AgentUsageUpdated(
          chatId,
          ContextCompactor.estimate(llmMessages, tools: tools),
          limit,
          estimated: true,
          contextWindowKnown: contextWindowKnown,
          breakdown: ContextBreakdown.of(llmMessages, tools: tools),
          dailyCostUsd: daily.costUsd,
          dailyBudgetUsd: budget,
        ),
      );
    }

    final policy = bound.policy;
    return _Prepared(
      chat: chat,
      host: host,
      runtime: runtime,
      policy: policy,
      limit: limit,
      contextWindowKnown: contextWindowKnown,
      model: model,
      inlineIds: inline.keys.toList(),
      project: project,
      request: LlmRequest(
        model: model,
        messages: llmMessages,
        tools: tools,
        reasoning: reasoning,
        // Просим кэш префикса. Пока время меняется в конце запроса, попаданий
        // между шагами нет (см. LLM_PROVIDERS.md); флаг остаётся, чтобы
        // исправление схемы не требовало менять путь вызова.
        promptCaching: true,
      ),
    );
  }

  /// Возможности рассуждений модели из каталога или сохранённых деталей.
  /// Null — модель не описана; тогда явный уровень всё равно отправляется.
  LlmReasoningCapability? _reasoningCapabilityOf(String model) =>
      _hub.models.state.modelOf(model)?.reasoning ??
      _hub.models.state.saved[model]?.reasoning;

  /// Модель для служебных проходов (сжатие истории).
  ///
  /// Цепочка: модель памяти, затем модель заголовков, затем модель чата. Первая
  /// заданная и известная каталогу модель выигрывает; если она совпадает с
  /// моделью чата, возвращается она же. Недоступная модель не должна ломать ход:
  /// сжатие важнее экономии, поэтому при неизвестном id выбирается следующая
  /// ступень, а не ошибка.
  Future<String> _utilityModel(String fallback) async {
    final resolved = await resolveUtilityModel(
      settings: _hub.settings,
      fallback: fallback,
      isKnown: (model) =>
          _hub.models.state.modelOf(model) != null ||
          _hub.models.state.saved[model] != null,
    );
    return resolved ?? fallback;
  }

  /// Размер собранного запроса по частям. Пишется на уровне fine: это опора для
  /// замеров стоимости шага и проверки, что кэш-префикс не раздувается.
  void _logContextMetrics({
    required List<LlmMessage> llmMessages,
    required List<LlmToolSpec> tools,
    required int limit,
  }) {
    if (!_log.isLoggable(Level.FINE)) return;
    final breakdown = ContextBreakdown.of(llmMessages, tools: tools);
    _log.fine(
      'context: system=${breakdown.systemBytes}B '
      'history=${breakdown.historyBytes}B '
      'toolResults=${breakdown.toolResultBytes}B '
      'toolSchemas=${breakdown.toolSchemaBytes}B '
      'messages=${llmMessages.length} tools=${tools.length} '
      'estimated=${ContextCompactor.estimate(llmMessages, tools: tools)} '
      'limit=$limit',
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
            _liveText.clear();
            _liveReasoning.clear();
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
        _liveText.clear();
        _liveReasoning.clear();
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

  LlmRequest _withModel(LlmRequest request, String model) => LlmRequest(
    model: model,
    messages: request.messages,
    tools: request.tools,
    maxTokens: request.maxTokens,
    temperature: request.temperature,
    // Запасная модель может поддерживать другой набор уровней. Понижаем
    // сохранённый уровень, чтобы не получить 400 при fallback.
    reasoning: resolveReasoning(
      capability: _reasoningCapabilityOf(model),
      preference: ReasoningPreference.fromEffort(request.reasoning),
    ),
    // Кэш префикса не зависит от модели: смена модели не должна его отключать.
    promptCaching: request.promptCaching,
  );

  Future<StepResult> _streamOnce(
    LlmRequest request,
    CancelToken turn,
    AppLimits limits,
  ) async {
    final step = CancelToken();
    _stepCancel = step;
    // Новый шаг: снимок больше не должен содержать текст предыдущего.
    _liveText.clear();
    _liveReasoning.clear();
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
                _liveReasoning.write(e.text);
                _emit(AgentReasoningDelta(chatId, e.text));
              case LlmTextDelta e:
                text.write(e.text);
                _liveText.write(e.text);
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

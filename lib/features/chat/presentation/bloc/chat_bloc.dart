import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:probably_works/core/platform/app_platform.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_list_updates.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/chat_api.dart';
import 'package:pw_agent/agent/api/client_session_api.dart';
import 'package:pw_agent/agent/context/context_breakdown.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/project.dart';
import 'package:pw_agent/agent/domain/steps_display.dart';
import 'package:pw_agent/agent/exec/live_output_bus.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/agent/loop/prompt_queue.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/core/data/chat_draft_store.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/domain/chat_usage.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/core/logging/app_log.dart';
import 'package:pw_agent/host/host_terminal.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';
import 'package:pw_agent/providers/ai/model_runtime.dart';

part 'chat_bloc_event.dart';
part 'chat_bloc_state.dart';

// ---- bloc -------------------------------------------------------------------

/// UI-состояние одного чата. Данные истины — в БД; состояние держит только то, что нужно отрисовать сейчас.
/// Обработка событий по одному: каждое следующее ждёт окончания предыдущего.
EventTransformer<T> _sequential<T>() =>
    (events, mapper) => events.asyncExpand(mapper);

class ChatBloc extends Bloc<ChatEvent, ChatState> {
  /// [seedChat] — чат из уже загруженного списка. Он попадает в начальное состояние сразу, до первого
  /// кадра: шапка, композер и модель видны без ожидания, а лента грузится в своей области.
  ChatBloc(
    this._hub,
    this._bus,
    this._drafts, {
    Chat? seedChat,
    List<Host> seedHosts = const [],
    this.onChatCreated,
    ChatState? initialState,
    ModelRuntimeSource? modelRuntime,
  }) : _runtimeOverride = modelRuntime,
       super(initialState ?? _seedState(_hub, _drafts, seedChat, seedHosts)) {
    _composerText = state.draft;
    _composerMentions = state.mentions;
    on<ChatOpenEvent>(_onOpenEvent, transformer: _sequential());
    on<ChatDraftEdited>(_onDraftEdited);
    on<ChatAttachmentsAdded>(_onAttachmentsAdded);
    on<ChatAttachmentRemoved>(_onAttachmentRemoved);
    on<ChatSubmitted>(_onSubmitted);
    on<ChatStopped>((_, _) async => _session?.stop());
    on<ChatDraftConflictKeepLocal>(_onConflictKeepLocal);
    on<ChatDraftConflictAcceptRemote>(_onConflictAcceptRemote);
    on<_ConflictChanged>(_onConflictChanged);
    on<_SessionsChanged>(_onSessionsChanged);
    on<ChatContinued>((_, _) async => _session?.continueAfterStepLimit());
    on<ChatRegenerateRequested>((_, _) async {
      await _session?.regenerateLast();
    });
    on<ChatForkRequested>(_onFork);
    on<ChatApprovalAnswered>(_onApproval);
    on<ChatQuestionAnswered>(_onQuestion);
    on<ChatMessageEdited>(_onEdited);
    on<ChatDeletedAfter>(_onDeletedAfter);
    on<ChatModelChanged>(_onModelChanged);
    on<ChatReasoningChanged>(_onReasoningChanged);
    on<ChatModelPinToggled>(_onModelPinToggled);
    on<ChatPolicyChanged>(_onPolicyChanged);
    on<ChatHostChanged>(_onHostChanged);
    on<ChatWorkspaceChanged>(_onWorkspaceChanged);
    on<ChatWorkspaceTrusted>(_onTrusted);
    on<ChatRunStopRequested>(_onRunStop);
    on<ChatEditFileChangesAnswered>(_onEditFileChanges);
    on<ChatQueueSendNow>(
      (event, _) async => _session?.promoteQueued(event.index),
    );
    on<ChatQueueRemoved>((event, _) async => _session?.takeQueued(event.index));
    on<ChatQueueEdited>(_onQueueEdited);
    on<ChatCompactRequested>(_onCompactRequested);
    on<ChatDailyBudgetChanged>(_onDailyBudgetChanged);
    on<_SessionEvent>(_onSessionEvent);
    on<_LiveChunk>(_onLiveChunk);
    on<_LiveFlush>(_onLiveFlush);
    on<_Refresh>(_onRefresh);
    on<_StepsChanged>(_onStepsChanged);
    on<_PinnedChanged>(_onPinnedChanged);
    on<_DefaultModelChanged>(_onDefaultModelChanged);
    on<_CatalogChanged>((event, emit) {
      final limit = _contextLimitOf(
        state.chat,
        event.catalog,
        state.defaultModelId,
      );
      emit(
        state.copyWith(
          catalog: event.catalog,
          contextLimit: limit,
          clearContextLimit: limit == null,
          contextWindowKnown: limit != null,
        ),
      );
    });
    on<_HostsChanged>(
      (event, emit) => emit(state.copyWith(hosts: event.hosts)),
    );
  }

  final ChatApi _hub;
  final LiveOutputBus _bus;
  final ChatDraftStore _drafts;

  /// Подмена runtime для виджет-тестов, где за `ChatApi` стоит пустышка.
  final ModelRuntimeSource? _runtimeOverride;

  /// Вызывается, когда новый чат записан в БД после первой отправки: экран переключает выбор на него.
  final void Function(String chatId)? onChatCreated;

  /// Текст поля ввода, как его знает блок: обновляется из [ChatDraftEdited] без перерисовки.
  String _composerText = '';

  /// Упоминания поля ввода. Живут рядом с текстом и не эмитятся на каждый
  /// сдвиг диапазона: контроллер в UI — источник истины для текущего кадра.
  List<MentionRef> _composerMentions = const [];

  /// Подписки на сессию выбранного чата; меняются при смене чата.
  ChatSessionApi? _session;
  StreamSubscription<AgentEvent>? _sessionSub;
  StreamSubscription<LiveChunk>? _liveSub;
  StreamSubscription<ApprovalRequest>? _approvalSub;
  StreamSubscription<UserQuestion>? _questionSub;
  StreamSubscription<EditFileChangesRequest>? _editFileChangesSub;
  StreamSubscription<InteractionResolution>? _resolutionSub;
  StreamSubscription<DraftConflict>? _conflictSub;
  StreamSubscription<List<ClientSessionView>>? _sessionsSub;
  List<ClientSessionView> _sessionsList = const [];

  /// Общие подписки блока (каталог, хосты, журнал шагов): живут, пока открыт блок, и не зависят от чата.
  var _sharedWatching = false;
  StreamSubscription<ModelCatalogState>? _catalogSub;
  StreamSubscription<List<Host>>? _hostsSub;
  final _stepsSubs = <StreamSubscription<String?>>[];
  StreamSubscription<String?>? _pinsSub;
  StreamSubscription<String?>? _defaultModelSub;
  StreamSubscription<String?>? _defaultReasoningSub;
  StreamSubscription<String>? _draftSub;
  final Map<String, StringBuffer> _pendingLive = {};
  Timer? _liveTimer;

  static const _liveThrottle = Duration(milliseconds: 100);

  /// Каталог моделей профиля для диалога выбора в композере.
  ModelCatalogSource get modelCatalog => _hub.models;

  /// Состояние загрузки моделей: чип композера и док слушают его отдельно,
  /// чтобы прогресс не перестраивал ленту.
  ModelRuntimeSource get modelRuntime => _runtimeOverride ?? _hub.models;

  /// Терминал, в котором сейчас выполняется запуск; `null`, если он не выполняется в PTY или уже завершён.
  HostTerminal? terminalFor(String runId) =>
      _hub.registry.find(runId)?.terminal;

  /// Состояние на время смены чата. Композер (чат для настроек, модель, папка, хосты, черновик) и каталог
  /// остаются от прежнего чата, пока не придут данные нового: без пустого кадра и мелькания. Лента,
  /// подтверждения и вопросы относятся к старому чату и сбрасываются.
  ChatState _switchState(ChatOpened event) {
    // Черновик нового чата берём из памяти или из списка: поле ввода сразу показывает его текст.
    _drafts.prime(event.chatId, event.seedChat);
    final limit = _contextLimitOf(
      event.seedChat,
      state.catalog,
      state.defaultModelId,
    );
    return _pushDraft(
      ChatState(
        chatId: event.chatId,
        // Настройки нового чата к другому чату не относятся: при переключении их не показываем.
        chat: event.seedChat ?? (state.unsaved ? null : state.chat),
        hosts: event.seedHosts.isEmpty ? state.hosts : event.seedHosts,
        catalog: state.catalog,
        limits: state.limits,
        pinnedModels: state.pinnedModels,
        stepsDisplay: state.stepsDisplay,
        defaultModelId: state.defaultModelId,
        defaultReasoning: state.defaultReasoning,
        // Лимит предыдущего чата к новому не относится: его посчитает
        // _onOpened по загруженному чату и каталогу.
        contextLimit: limit,
        contextWindowKnown: limit != null,
        draftId: state.draftId,
        isRunning: _session?.isRunning ?? false,
        queue: _queueTexts(),
        approvals: _hub.broker.pendingApprovals(event.chatId),
        questions: _hub.broker.pendingQuestions(event.chatId),
        editFileChanges: _hub.broker.pendingEditFileChanges(event.chatId),
        draftConflict: _drafts.conflictFor(event.chatId),
        otherSessions: _otherSessions(event.chatId),
        loading: true,
      ),
      _drafts.of(event.chatId),
    );
  }

  /// Кладёт черновик в поле ввода: текст и вложения. ChatBody переписывает поле, когда меняется [draftId].
  ChatState _pushDraft(ChatState from, ChatDraft draft) {
    _composerText = draft.text;
    _composerMentions = draft.mentions;
    return from.copyWith(
      draft: draft.text,
      draftId: from.draftId + 1,
      attachments: draft.attachments,
      mentions: draft.mentions,
    );
  }

  /// Текущий черновик (текст из блока и вложения) — в память и, с задержкой, в БД.
  void _saveDraft() {
    final chatId = state.chatId;
    if (chatId == null) return;
    _drafts.update(
      chatId,
      ChatDraft(
        text: _composerText,
        attachments: state.attachments,
        mentions: _composerMentions,
      ),
    );
  }

  /// Начальное состояние из уже известных данных (список чатов и каталог в памяти). Только чтения,
  /// без сети и без БД: блок стартует с правильной шапкой, черновиком и композером.
  static ChatState _seedState(
    ChatApi hub,
    ChatDraftStore drafts,
    Chat? chat,
    List<Host> hosts,
  ) {
    // Новый чат: всё уже в памяти (хосты, настройки), поэтому первый кадр строит готовый экран.
    if (chat == null) return _newChatState(hub, hosts, draftId: 0);
    drafts.prime(chat.id, chat);
    final draft = drafts.of(chat.id);
    final session = hub.session(chat.id);
    final limit = _contextLimitOf(
      chat,
      hub.models.state,
      hub.settings.cached(SettingsRepository.keyDefaultModel),
    );
    return ChatState(
      chatId: chat.id,
      chat: chat,
      hosts: hosts,
      catalog: hub.models.state,
      // Последний точный размер контекста из БД: чип виден сразу после
      // открытия чата, не дожидаясь нового запроса.
      promptTokens: chat.lastPromptTokens,
      contextLimit: limit,
      contextWindowKnown: limit != null,
      defaultReasoning: hub.settings.cachedReasoning(
        SettingsRepository.keyDefaultReasoning,
      ),
      approvals: hub.broker.pendingApprovals(chat.id),
      questions: hub.broker.pendingQuestions(chat.id),
      isRunning: session.isRunning,
      queue: [for (final item in session.queue) item.text],
      draft: draft.text,
      attachments: draft.attachments,
      mentions: draft.mentions,
      loading: true,
    );
  }

  @override
  Future<void> close() async {
    _liveTimer?.cancel();
    for (final sub in _stepsSubs) {
      await sub.cancel();
    }
    await _pinsSub?.cancel();
    await _defaultModelSub?.cancel();
    await _defaultReasoningSub?.cancel();
    await _draftSub?.cancel();
    await _sessionSub?.cancel();
    await _liveSub?.cancel();
    await _approvalSub?.cancel();
    await _questionSub?.cancel();
    await _editFileChangesSub?.cancel();
    await _resolutionSub?.cancel();
    await _conflictSub?.cancel();
    _sessions?.setPresence(clearActiveChat: true);
    await _sessionsSub?.cancel();
    await _catalogSub?.cancel();
    await _hostsSub?.cancel();
    // Закрытие чата сохраняет его черновик сразу, не дожидаясь задержки записи.
    await _drafts.flush();
    return super.close();
  }

  /// Открытия идут по очереди: поздний ответ БД от предыдущего открытия не перезапишет более позднее.
  Future<void> _onOpenEvent(ChatOpenEvent event, Emitter<ChatState> emit) =>
      switch (event) {
        ChatOpened() => _onOpened(event, emit),
        ChatDraftOpened() => _onDraftOpened(event, emit),
      };

  /// Общие подписки блока: каталог моделей, хосты и настройки журнала шагов. Ставятся один раз,
  /// до первого чтения, чтобы изменение между чтением и подпиской не терялось.
  void _watchShared() {
    if (_sharedWatching) return;
    _sharedWatching = true;
    // Хосты общие для всех чатов: список в композере обновляется при любом изменении, в том числе
    // пока чат открыт. Первое значение пропускаем: открытие читает хосты само, после подписки.
    _hostsSub = _hub.hostStore
        .watchAll()
        .skip(1)
        .listen((hosts) => add(_HostsChanged(hosts)));
    for (final key in [
      SettingsRepository.keyStepsGroup,
      SettingsRepository.keyStepsThoughts,
      SettingsRepository.keyStepsTools,
    ]) {
      _stepsSubs.add(
        _hub.settings.watch(key).listen((_) => add(const _StepsChanged())),
      );
    }
    // Закрепления пишут и Settings, и композер (в том числе другой чат), и агент: подписка на ключ в БД.
    _pinsSub = _hub.settings
        .watch(SettingsRepository.keyPinnedModels)
        .listen((_) => add(const _PinnedChanged()));
    // В daemon-режиме настройки приходят асинхронно: кэш может быть пуст на
    // первом кадре, поэтому новый чат догоняет модель по умолчанию подпиской.
    _defaultModelSub = _hub.settings
        .watch(SettingsRepository.keyDefaultModel)
        .listen((_) => add(const _DefaultModelChanged()));
    _defaultReasoningSub = _hub.settings
        .watch(SettingsRepository.keyDefaultReasoning)
        .listen((_) => add(const _DefaultModelChanged()));
    // Каталог может обновиться в фоне (старт, таймер, Settings): чат перерисует подпись модели и маркер.
    _catalogSub = _hub.models.watch().listen(
      (catalog) => add(_CatalogChanged(catalog)),
    );
    _draftSub = _hub.chatStore.watchDraftChanges().listen(
      (chatId) => unawaited(_refreshDraft(chatId)),
    );
  }

  Future<void> _refreshDraft(String chatId) async {
    if (chatId != state.chatId) return;
    final chat = await _hub.chatStore.chat(chatId);
    if (chat == null || isClosed) return;
    if (!_drafts.applyRemote(chatId, chat)) return;
    // ignore: invalid_use_of_visible_for_testing_member, состояние меняет внешний SSE-поток
    emit(_pushDraft(state, chat.draft));
  }

  /// Снимает подписки на сессию чата, если они были.
  Future<void> _detach() async {
    await _sessionSub?.cancel();
    await _liveSub?.cancel();
    await _approvalSub?.cancel();
    await _questionSub?.cancel();
    await _editFileChangesSub?.cancel();
    _sessionSub = null;
    _liveSub = null;
    _approvalSub = null;
    _questionSub = null;
    _editFileChangesSub = null;
    _resolutionSub = null;
    _conflictSub = null;
    _sessions?.setPresence(clearActiveChat: true);
    await _sessionsSub?.cancel();
    _sessionsSub = null;
    _pendingLive.clear();
    _session = null;
  }

  /// Подписывается на сессию, живой вывод, подтверждения и вопросы чата [chatId].
  Future<void> _attach(String chatId) async {
    await _detach();
    _session = _hub.session(chatId);
    _sessionSub = _session!.events.listen((e) => add(_SessionEvent(e)));
    _liveSub = _bus.stream
        .where((c) => c.chatId == chatId)
        .listen((c) => add(_LiveChunk(c.toolCallId, c.text)));
    _approvalSub = _hub.broker.approvalRequests
        .where((r) => r.chatId == chatId)
        .listen((_) => add(const _Refresh()));
    _questionSub = _hub.broker.questions
        .where((q) => q.chatId == chatId)
        .listen((_) => add(const _Refresh()));
    _editFileChangesSub = _hub.broker.editFileChangesRequests
        .where((request) => request.chatId == chatId)
        .listen((_) => add(const _Refresh()));
    _resolutionSub = _hub.broker.resolutions
        .where((resolution) => resolution.chatId == chatId)
        .listen((_) => add(const _Refresh()));
    _conflictSub = _drafts.conflicts
        .where((conflict) => conflict.chatId == chatId)
        .listen((conflict) => add(_ConflictChanged(conflict)));
    final sessions = _sessions;
    if (sessions != null) {
      sessions.setPresence(activeChatId: chatId);
      _sessionsSub = sessions.clientSessions.listen(
        (items) => add(_SessionsChanged(items)),
      );
      unawaited(_refreshSessions(sessions));
    }
  }

  Future<void> _onOpened(ChatOpened event, Emitter<ChatState> emit) async {
    await _attach(event.chatId);
    // Смена чата: композер и шапка держат прежние значения до прихода данных нового чата.
    if (state.chatId != event.chatId) emit(_switchState(event));
    // После первого состояния: подписка на каталог сразу отдаёт текущее значение, и оно не должно
    // выйти отдельным кадром до загрузки чата.
    _watchShared();

    final shared = await _readShared();
    final snapshot = await _readChat(event.chatId);
    final usage = await _usageOf(event.chatId);
    final project = await _hub.projectStore.forChat(event.chatId);
    // Карточки этого чата — из базы, не при старте приложения.
    // Если ход уже продолжен после старта, здесь только показываем карточки.
    await _session?.restoreUnanswered();
    final turn = _session?.turnSnapshot ?? const TurnSnapshot();
    // Последний точный usage из БД важнее оценки, которая могла остаться в
    // состоянии от предыдущего кадра.
    final restoredTokens = snapshot.chat?.lastPromptTokens;
    final knownLimit = _contextLimitOf(
      snapshot.chat,
      _hub.models.state,
      shared.defaultModel,
    );
    // Один emit на открытие: каждый промежуточный emit перестраивает весь экран чата на UI-потоке.
    final loaded = state.copyWith(
      hosts: shared.hosts,
      limits: shared.limits,
      catalog: _hub.models.state,
      pinnedModels: shared.pinned,
      stepsDisplay: shared.stepsDisplay,
      defaultModelId: shared.defaultModel,
      defaultReasoning: shared.defaultReasoning,
      chat: snapshot.chat,
      project: project,
      messages: snapshot.messages,
      runs: snapshot.runs,
      approvals: _hub.broker.pendingApprovals(event.chatId),
      questions: _hub.broker.pendingQuestions(event.chatId),
      editFileChanges: _hub.broker.pendingEditFileChanges(event.chatId),
      draftConflict: _drafts.conflictFor(event.chatId),
      otherSessions: _otherSessions(event.chatId),
      // Последний точный usage и окно модели доступны до первого запроса:
      // чип не пропадает после перезапуска и не берёт лимит чужого чата.
      promptTokens: restoredTokens ?? state.promptTokens,
      promptTokensEstimated:
          restoredTokens == null && state.promptTokensEstimated,
      contextLimit: knownLimit,
      clearContextLimit: knownLimit == null,
      contextWindowKnown: knownLimit != null,
      dailyCostUsd: usage.usage.costUsd,
      dailyBudgetUsd: usage.budget,
      clearDailyBudget: usage.budget == null,
      compactionInfo: usage.compaction,
      clearCompactionInfo: usage.compaction == null,
      isRunning: _session?.isRunning ?? false,
      streamText: turn.text,
      streamReasoning: turn.reasoning,
      queue: _queueTexts(),
      loading: false,
      unsaved: false,
    );
    // Черновик из записи чата нужен, только если в памяти его не было (без списка чатов). Иначе поле уже верное.
    final restored = _drafts.prime(event.chatId, snapshot.chat);
    emit(restored ? _pushDraft(loaded, _drafts.of(event.chatId)) : loaded);
    // Детали моделей чата и закреплённых сохраняются, чтобы их название показывалось без загрузки списка.
    await _hub.models.remember([
      ?state.effectiveModelId,
      ...state.pinnedModels,
    ]);
  }

  /// Общие для всех чатов настройки из БД: хосты, лимиты, закреплённые модели, журнал шагов и модель
  /// по умолчанию. Только локальные чтения: каталог уже в памяти, сеть здесь не ждём.
  Future<List<Host>> _hostsOrEmpty() async {
    try {
      return await _hub.hostStore.all();
    } on Object {
      return const [];
    }
  }

  Future<
    ({
      List<Host> hosts,
      AppLimits limits,
      List<String> pinned,
      StepsDisplay stepsDisplay,
      String? defaultModel,
      ReasoningPreference defaultReasoning,
    })
  >
  _readShared() async => (
    hosts: await _hostsOrEmpty(),
    limits: await _hub.limits(),
    pinned: await _hub.settings.readPinnedModels(),
    stepsDisplay: await _hub.settings.readStepsDisplay(),
    defaultModel: await _hub.settings.read(SettingsRepository.keyDefaultModel),
    defaultReasoning: await _hub.settings.readReasoning(
      SettingsRepository.keyDefaultReasoning,
    ),
  );

  /// Окно контекста для чипа и диалога до первого события usage.
  ///
  /// Источники по убыванию свежести: живой каталог, сохранённые детали модели,
  /// поле чата. Чат с моделью по умолчанию своего окна не хранит, поэтому без
  /// каталога он выглядел бы как 128k даже для модели на миллион токенов.
  static int? _contextLimitOf(
    Chat? chat,
    ModelCatalogState catalog,
    String? defaultModelId,
  ) {
    final own = chat?.model;
    final model = own != null && own.isNotEmpty ? own : defaultModelId;
    if (model == null || model.isEmpty) return chat?.contextLength;
    return catalog.modelOf(model)?.contextLength ??
        catalog.saved[model]?.contextLength ??
        chat?.contextLength;
  }

  /// Состояние нового чата из настроек и хостов в памяти: без чтений БД и сети. Черновик в блоке пока
  /// не записан: чат появится в БД с первым сообщением (см. [ChatApi.draftChat]).
  static ChatState _newChatState(
    ChatApi hub,
    List<Host> hosts, {
    required int draftId,
  }) {
    final settings = hub.settings;
    final hostId = _defaultHostId(hosts);
    final host = hosts.where((h) => h.id == hostId).firstOrNull;
    final chat = hub.draftChat(hostId: hostId, host: host);
    final defaultModelId = settings.cached(SettingsRepository.keyDefaultModel);
    final limit = _contextLimitOf(chat, hub.models.state, defaultModelId);
    return ChatState(
      hosts: hosts,
      limits: settings.cachedLimits(),
      catalog: hub.models.state,
      pinnedModels: settings.cachedPinnedModels(),
      stepsDisplay: settings.cachedStepsDisplay(),
      defaultModelId: defaultModelId,
      defaultReasoning: settings.cachedReasoning(
        SettingsRepository.keyDefaultReasoning,
      ),
      contextLimit: limit,
      contextWindowKnown: limit != null,
      draftId: draftId,
      chatId: chat.id,
      chat: chat,
      unsaved: true,
    );
  }

  /// Хост по умолчанию для нового чата: локальный, а на iOS (без локального Host) удалённый (см. [preferredRemoteHost]).
  static String _defaultHostId(List<Host> hosts) {
    if (AppPlatform.current.hasLocalHost) return HostRepository.localHostId;
    return preferredRemoteHost(hosts)?.id ?? HostRepository.localHostId;
  }

  /// Новый чат. Обычно блок уже создан с готовым черновиком (см. [_seedState]), и открывать второй не нужно.
  /// Иначе (блок переиспользован после отправки) переносим черновик текущего чата в новый и очищаем исходный.
  Future<void> _onDraftOpened(
    ChatDraftOpened _,
    Emitter<ChatState> emit,
  ) async {
    final from = state.chatId;
    if (state.unsaved && from != null) {
      // Сначала хосты, потом подписки: их первые эмиты не должны опережать загрузку списка.
      if (state.hosts.isEmpty) {
        emit(state.copyWith(hosts: await _hostsOrEmpty()));
      }
      _watchShared();
      return;
    }
    final carried = from != null && !state.unsaved && !_drafts.of(from).isEmpty;
    await _detach();
    // Хосты из списка уже в памяти; блок, созданный без списка, читает их из БД.
    final hosts = state.hosts.isEmpty ? await _hostsOrEmpty() : state.hosts;
    final next = _newChatState(_hub, hosts, draftId: state.draftId);
    final chatId = next.chatId!;
    // Перенос меняет память синхронно; запись в БД уходит в фон, чтобы не задерживать первый кадр.
    if (carried) unawaited(_drafts.move(from, chatId));
    _watchShared();
    emit(_pushDraft(next, _drafts.of(chatId)));
  }

  Future<void> _onSubmitted(
    ChatSubmitted event,
    Emitter<ChatState> emit,
  ) async {
    if (event.text.trim().isEmpty && event.attachments.isEmpty) return;
    final created = state.unsaved;
    if (created) await _saveNewChat(emit);
    final session = _session;
    if (session == null) return;
    // Отправленное сразу уходит из черновика: набор во время отправки начнётся уже с пустого поля.
    _composerText = '';
    _composerMentions = const [];
    emit(state.copyWith(attachments: const [], mentions: const []));
    _saveDraft();
    await session.submit(
      event.text,
      attachments: event.attachments,
      mentions: event.mentions,
      sendNow: event.sendNow,
    );
    emit(state.copyWith(queue: _queueTexts(), clearFailure: true));
    if (created) onChatCreated?.call(state.chatId!);
  }

  /// Первая отправка в новом чате: чат получает проект, записывается в БД, и блок начинает слушать его сессию.
  Future<void> _saveNewChat(Emitter<ChatState> emit) async {
    final now = DateTime.now();
    var chat = state.chat!.copyWith(createdAt: now, updatedAt: now);
    chat = await _hub.projects.attach(chat);
    await _hub.chatStore.createChat(chat);
    await _attach(chat.id);
    final project = await _hub.projectStore.forChat(chat.id);
    emit(state.copyWith(chat: chat, project: project, unsaved: false));
  }

  /// Изменения настроек нового чата остаются в памяти: запись появится с первой отправкой.
  ///
  /// Сохраняются только переданные поля. Полная запись строки затирала бы
  /// заголовок или workspace, изменённые другим клиентом.
  Future<Chat> _persistChat(
    Chat chat, {
    String? title,
    String? model,
    ReasoningPreference? reasoning,
    PolicyMode? policyMode,
    String? workspace,
    bool workspaceSpecified = false,
  }) async {
    if (state.unsaved) return chat;
    Future<Chat> send(int? expectedRevision) => _hub.chatStore.updateChat(
      chat.id,
      title: title,
      model: model,
      reasoning: reasoning,
      policyMode: policyMode,
      workspace: workspace,
      workspaceSpecified: workspaceSpecified,
      expectedRevision: expectedRevision,
    );
    try {
      return await send(chat.revision);
    } on AgentApiException catch (error) {
      if (error.code != 'chat_conflict') rethrow;
      // Пока мы собирали PATCH, другой клиент изменил чат. Перечитываем
      // ревизию и повторяем только свои поля.
      final fresh = await _hub.chatStore.chat(chat.id);
      if (fresh == null) rethrow;
      return send(fresh.revision);
    }
  }

  void _onDraftEdited(ChatDraftEdited event, Emitter<ChatState> emit) {
    // Поле уведомляет и о смене выделения (например, при получении фокуса).
    // Упоминания могут измениться и без текста: сменился полный путь при том
    // же basename. Сравнение по обоим полям сохраняет это изменение.
    if (event.text == _composerText &&
        listEquals(event.mentions, _composerMentions)) {
      return;
    }
    _composerText = event.text;
    _composerMentions = event.mentions;
    _saveDraft();
  }

  void _onAttachmentsAdded(
    ChatAttachmentsAdded event,
    Emitter<ChatState> emit,
  ) {
    final room = state.limits.attachmentsPerMessage - state.attachments.length;
    if (room <= 0) return;
    emit(
      state.copyWith(
        attachments: [...state.attachments, ...event.items.take(room)],
      ),
    );
    _saveDraft();
  }

  void _onAttachmentRemoved(
    ChatAttachmentRemoved event,
    Emitter<ChatState> emit,
  ) {
    if (event.index < 0 || event.index >= state.attachments.length) return;
    emit(
      state.copyWith(
        attachments: [...state.attachments]..removeAt(event.index),
      ),
    );
    _saveDraft();
  }

  /// Сколько отложенных задач попадёт в форк до [untilMessageId]. null —
  /// прочитать не удалось.
  ///
  /// Нужно экрану перед форком из ответа: вопрос о переносе задач задаётся до
  /// события, потому что диалог — дело интерфейса, а не блока. Учитываются
  /// только задачи выше линии форка: ниже линии они не переносятся.
  Future<int?> pendingScheduledTasks({String? untilMessageId}) async {
    final chatId = state.chatId;
    if (chatId == null) return 0;
    try {
      return await _hub.pendingScheduledTasks(
        chatId,
        untilMessageId: untilMessageId,
      );
    } on Object {
      return null;
    }
  }

  Future<void> _onFork(ChatForkRequested event, Emitter<ChatState> emit) async {
    final chatId = state.chatId;
    if (chatId == null || state.isRunning) return;
    try {
      final forked = await _hub.forkChat(
        chatId,
        untilMessageId: event.messageId,
        title: event.title,
        copyPendingTasks: event.copyPendingTasks,
      );
      if (forked != null) onChatCreated?.call(forked.id);
    } on Object catch (error, stack) {
      // Форк не должен ломать открытый чат, но молчать нельзя: иначе «ничего
      // не произошло» не отличить от сбоя. Разбираться по журналу приложения.
      AppLog.root.warning('cannot fork chat $chatId', error, stack);
    }
  }

  void _onApproval(ChatApprovalAnswered event, Emitter<ChatState> emit) {
    _hub.broker.resolveApproval(event.requestId, event.decision);
    emit(
      state.copyWith(approvals: _hub.broker.pendingApprovals(state.chatId!)),
    );
  }

  void _onQuestion(ChatQuestionAnswered event, Emitter<ChatState> emit) {
    _hub.broker.answer(event.questionId, event.text);
    emit(
      state.copyWith(questions: _hub.broker.pendingQuestions(state.chatId!)),
    );
  }

  Future<void> _onEdited(
    ChatMessageEdited event,
    Emitter<ChatState> emit,
  ) async {
    var accepted = false;
    try {
      accepted =
          await _session?.editUserMessage(
            event.messageId,
            event.text,
            attachments: event.attachments,
            mentions: event.mentions,
          ) ??
          false;
    } on StateError catch (error) {
      emit(state.copyWith(failure: error.message));
    }
    await _reload(emit);
    event.onDone?.call(accepted);
  }

  Future<void> _onDeletedAfter(
    ChatDeletedAfter event,
    Emitter<ChatState> emit,
  ) async {
    try {
      await _session?.deleteAfter(event.messageId);
    } on StateError catch (error) {
      emit(state.copyWith(failure: error.message));
    }
    await _reload(emit);
  }

  void _onEditFileChanges(
    ChatEditFileChangesAnswered event,
    Emitter<ChatState> emit,
  ) {
    _hub.broker.resolveEditFileChanges(event.requestId, event.choice);
    final chatId = state.chatId;
    if (chatId == null) return;
    emit(
      state.copyWith(
        editFileChanges: _hub.broker.pendingEditFileChanges(chatId),
      ),
    );
  }

  Future<void> _onModelChanged(
    ChatModelChanged event,
    Emitter<ChatState> emit,
  ) async {
    final chat = state.chat;
    if (chat == null) return;
    final modelChanged = chat.model != event.model.id;
    final updated = chat.copyWith(
      model: event.model.id,
      contextLength: event.model.contextLength,
      reasoning: event.reasoning,
    );
    await _hub.models.remember([event.model.id]);
    final saved = await _persistChat(
      updated,
      model: updated.model,
      reasoning: updated.reasoning,
    );
    final shown = saved.copyWith(contextLength: updated.contextLength);
    final limit = _contextLimitOf(shown, state.catalog, state.defaultModelId);
    emit(
      state.copyWith(
        chat: shown,
        contextLimit: limit,
        clearContextLimit: limit == null,
        contextWindowKnown: limit != null,
      ),
    );
    // Новое окно модели может быть меньше: проверяем бюджет сразу, не дожидаясь следующего хода.
    // Смена только уровня рассуждений окно не меняет.
    if (!modelChanged) return;
    final session = _session;
    if (session != null && !session.isRunning) unawaited(session.compactNow());
  }

  Future<void> _onReasoningChanged(
    ChatReasoningChanged event,
    Emitter<ChatState> emit,
  ) async {
    final chat = state.chat;
    if (chat == null || chat.reasoning == event.reasoning) return;
    final updated = chat.copyWith(reasoning: event.reasoning);
    final saved = await _persistChat(updated, reasoning: updated.reasoning);
    emit(state.copyWith(chat: saved));
  }

  Future<void> _onModelPinToggled(
    ChatModelPinToggled event,
    Emitter<ChatState> emit,
  ) async {
    final pins = [...state.pinnedModels];
    if (!pins.remove(event.modelId)) pins.add(event.modelId);
    if (pins.contains(event.modelId)) {
      await _hub.models.remember([event.modelId]);
    }
    await _hub.settings.savePinnedModels(pins);
    emit(state.copyWith(pinnedModels: pins));
  }

  void _onQueueEdited(ChatQueueEdited event, Emitter<ChatState> emit) {
    final item = _session?.takeQueued(event.index);
    if (item == null) return;
    emit(
      _pushDraft(
        state,
        ChatDraft(
          text: item.text,
          attachments: state.attachments,
          mentions: item.mentions,
        ),
      ),
    );
  }

  Future<void> _onCompactRequested(
    ChatCompactRequested event,
    Emitter<ChatState> emit,
  ) async {
    final session = _session;
    if (session == null || session.isRunning) return;
    await session.compactNow(force: true);
  }

  Future<void> _onDailyBudgetChanged(
    ChatDailyBudgetChanged event,
    Emitter<ChatState> emit,
  ) async {
    final chatId = state.chatId;
    if (chatId == null) return;
    await _hub.settings.saveDailyBudget(chatId, event.budgetUsd);
    emit(
      state.copyWith(
        dailyBudgetUsd: event.budgetUsd,
        clearDailyBudget: event.budgetUsd == null,
      ),
    );
  }

  Future<void> _onPolicyChanged(
    ChatPolicyChanged event,
    Emitter<ChatState> emit,
  ) async {
    final chat = state.chat;
    if (chat == null) return;
    final updated = chat.copyWith(policyMode: event.mode);
    final saved = await _persistChat(updated, policyMode: updated.policyMode);
    emit(state.copyWith(chat: saved));
  }

  Future<void> _onHostChanged(
    ChatHostChanged event,
    Emitter<ChatState> emit,
  ) async {
    final chat = state.chat;
    if (chat == null || (_session?.isRunning ?? false)) return;
    if (state.unsaved) {
      final host = state.hosts.where((h) => h.id == event.hostId).firstOrNull;
      final workspace = host == null
          ? null
          : _hub.projects.configuredWorkspace(host);
      final updated = chat.copyWith(
        hostId: event.hostId,
        workspace: workspace,
        clearWorkspace: workspace == null,
        clearProjectId: true,
      );
      emit(state.copyWith(chat: updated, clearProject: true));
      return;
    }
    final updated = await _hub.projects.relocate(chat, hostId: event.hostId);
    final project = await _hub.projectStore.forChat(updated.id);
    emit(state.copyWith(chat: updated, project: project, trustNeeded: false));
  }

  Future<void> _onWorkspaceChanged(
    ChatWorkspaceChanged event,
    Emitter<ChatState> emit,
  ) async {
    final chat = state.chat;
    if (chat == null) return;
    if (state.unsaved) {
      final trimmed = event.workspace?.trim();
      final workspace = trimmed == null || trimmed.isEmpty ? null : trimmed;
      final updated = chat.copyWith(
        workspace: workspace,
        clearWorkspace: workspace == null,
        clearProjectId: true,
      );
      emit(state.copyWith(chat: updated, clearProject: true));
      return;
    }
    final updated = await _hub.projects.relocate(
      chat,
      workspace: event.workspace,
      workspaceSpecified: true,
    );
    final project = await _hub.projectStore.forChat(updated.id);
    emit(state.copyWith(chat: updated, project: project, trustNeeded: false));
  }

  Future<void> _onTrusted(
    ChatWorkspaceTrusted event,
    Emitter<ChatState> emit,
  ) async {
    final chat = state.chat;
    final project = state.project;
    if (chat == null) return;
    if (project != null) {
      await _hub.projects.trustWorkspace(project.id);
      final updated = await _hub.projectStore.byId(project.id);
      emit(state.copyWith(project: updated, trustNeeded: false));
      return;
    }
    final workspace = chat.workspace;
    if (workspace == null) return;
    await _hub.settings.setTrusted(chat.hostId, workspace, trusted: true);
    emit(state.copyWith(trustNeeded: false));
  }

  Future<void> _onRunStop(
    ChatRunStopRequested event,
    Emitter<ChatState> emit,
  ) async {
    final exec = _hub.registry.find(event.runId);
    if (exec == null) return;
    await _hub.registry.stop(exec, force: false);
  }

  Future<void> _onSessionEvent(
    _SessionEvent wrapper,
    Emitter<ChatState> emit,
  ) async {
    final event = wrapper.event;
    switch (event) {
      case AgentTurnStarted():
        emit(
          state.copyWith(
            isRunning: true,
            stepLimitReached: false,
            budgetReached: false,
            stalledReached: false,
            clearFailure: true,
            streamText: '',
            streamReasoning: '',
          ),
        );
      case AgentTurnFinished(:final end):
        emit(
          state.copyWith(
            isRunning: false,
            streamText: '',
            streamReasoning: '',
            stepLimitReached: end == TurnEnd.stepLimit,
            budgetReached: end == TurnEnd.budget,
            stalledReached: end == TurnEnd.stalled,
            queue: _queueTexts(),
          ),
        );
        await _reload(emit);
      case AgentTurnSnapshot(:final text, :final reasoning, :final isRunning):
        emit(
          state.copyWith(
            isRunning: isRunning,
            streamText: text,
            streamReasoning: reasoning,
          ),
        );
      case AgentTextDelta(:final text, :final reset):
        emit(state.copyWith(streamText: reset ? '' : state.streamText + text));
      case AgentReasoningDelta(:final text, :final reset):
        emit(
          state.copyWith(
            streamReasoning: reset ? '' : state.streamReasoning + text,
          ),
        );
      case AgentMessageAdded(:final message):
        final isAssistant = message.role == MessageRole.assistant;
        emit(
          state.copyWith(
            streamText: isAssistant ? '' : state.streamText,
            streamReasoning: isAssistant ? '' : state.streamReasoning,
            messages: withMessage(state.messages, message),
          ),
        );
      case AgentRunChanged(:final run):
        emit(
          state.copyWith(
            runs: withRun(state.runs, run),
            live: liveWithRuns(state.live, state.runs, run),
          ),
        );
      case AgentTurnChangesetChanged():
        break;
      case AgentQueueChanged():
        emit(state.copyWith(queue: _queueTexts()));
      case AgentFailureRaised(:final failure):
        emit(
          state.copyWith(
            failure: failure.message,
            failureModelMissing: failure is LlmFailure && failure.modelNotFound,
          ),
        );
      case AgentTrustNeeded():
        emit(state.copyWith(trustNeeded: true));
      case AgentUsageUpdated(
        :final promptTokens,
        :final estimated,
        :final contextWindowKnown,
        :final limit,
        :final breakdown,
        :final dailyCostUsd,
        :final dailyBudgetUsd,
      ):
        emit(
          state.copyWith(
            promptTokens: promptTokens,
            promptTokensEstimated: estimated,
            contextWindowKnown: contextWindowKnown,
            contextLimit: limit,
            contextBreakdown: breakdown,
            dailyCostUsd: dailyCostUsd,
            dailyBudgetUsd: dailyBudgetUsd,
          ),
        );
      case AgentStateChanged():
        await _reload(emit);
    }
  }

  Future<void> _onConflictKeepLocal(
    ChatDraftConflictKeepLocal event,
    Emitter<ChatState> emit,
  ) async {
    final chatId = state.chatId;
    if (chatId == null) return;
    await _drafts.keepLocal(chatId);
    emit(state.copyWith(clearDraftConflict: true));
  }

  void _onConflictAcceptRemote(
    ChatDraftConflictAcceptRemote event,
    Emitter<ChatState> emit,
  ) {
    final chatId = state.chatId;
    if (chatId == null) return;
    final conflict = state.draftConflict;
    _drafts.acceptRemote(chatId);
    // Для черновика композера сразу показываем серверный текст. Для правок
    // сообщений источник — хранилище; достаточно убрать баннер и перерисовать.
    if (conflict?.kind == DraftConflictKind.draft) {
      emit(
        _pushDraft(
          state.copyWith(clearDraftConflict: true),
          _drafts.of(chatId),
        ),
      );
    } else {
      emit(state.copyWith(clearDraftConflict: true));
    }
  }

  void _onConflictChanged(_ConflictChanged event, Emitter<ChatState> emit) {
    emit(state.copyWith(draftConflict: event.conflict));
  }

  ClientSessionApi? get _sessions {
    final Object hub = _hub;
    return hub is ClientSessionApi ? hub : null;
  }

  Future<void> _refreshSessions(ClientSessionApi sessions) async {
    try {
      await sessions.refreshClientSessions();
    } on Object {
      // Присутствие не критично для работы чата.
    }
  }

  List<ClientSessionView> _otherSessions(String? chatId) {
    if (chatId == null) return const [];
    return [
      for (final session in _sessionsList)
        if (!session.current &&
            session.activeChatId == chatId &&
            session.online)
          session,
    ];
  }

  void _onSessionsChanged(_SessionsChanged event, Emitter<ChatState> emit) {
    _sessionsList = event.sessions;
    emit(state.copyWith(otherSessions: _otherSessions(state.chatId)));
  }

  void _onLiveChunk(_LiveChunk event, Emitter<ChatState> emit) {
    _pendingLive.putIfAbsent(event.runId, StringBuffer.new).write(event.text);
    _liveTimer ??= Timer(_liveThrottle, () {
      _liveTimer = null;
      add(const _LiveFlush());
    });
  }

  void _onLiveFlush(_LiveFlush event, Emitter<ChatState> emit) {
    final next = Map<String, String>.of(state.live);
    for (final entry in _pendingLive.entries) {
      next[entry.key] = '${next[entry.key] ?? ''}${entry.value}';
    }
    _pendingLive.clear();
    emit(state.copyWith(live: next));
  }

  Future<void> _onStepsChanged(
    _StepsChanged event,
    Emitter<ChatState> emit,
  ) async {
    final display = await _hub.settings.readStepsDisplay();
    emit(state.copyWith(stepsDisplay: display));
  }

  /// Перечитывает закрепления из БД: источник правды один, поэтому состояние чата совпадает с настройками.
  Future<void> _onPinnedChanged(
    _PinnedChanged event,
    Emitter<ChatState> emit,
  ) async {
    final pinned = await _hub.settings.readPinnedModels();
    emit(state.copyWith(pinnedModels: pinned));
  }

  Future<void> _onDefaultModelChanged(
    _DefaultModelChanged event,
    Emitter<ChatState> emit,
  ) async {
    final model = await _hub.settings.read(SettingsRepository.keyDefaultModel);
    final reasoning = await _hub.settings.readReasoning(
      SettingsRepository.keyDefaultReasoning,
    );
    // Чат без своей модели следует за моделью по умолчанию: вместе с ней
    // меняется и окно контекста.
    final own = state.chat?.model;
    final followsDefault = own == null || own.isEmpty;
    final limit = followsDefault
        ? _contextLimitOf(state.chat, state.catalog, model)
        : state.contextLimit;
    emit(
      state.copyWith(
        defaultModelId: model,
        defaultReasoning: reasoning,
        contextLimit: limit,
        clearContextLimit: followsDefault && limit == null,
        contextWindowKnown: followsDefault
            ? limit != null
            : state.contextWindowKnown,
      ),
    );
  }

  Future<void> _onRefresh(_Refresh event, Emitter<ChatState> emit) async {
    final chatId = state.chatId;
    if (chatId == null) return;
    emit(
      state.copyWith(
        approvals: _hub.broker.pendingApprovals(chatId),
        questions: _hub.broker.pendingQuestions(chatId),
        editFileChanges: _hub.broker.pendingEditFileChanges(chatId),
      ),
    );
  }

  /// Чат, сообщения и запуски из БД. Без emit: вызывающий сам решает, когда перерисовать экран.
  Future<({Chat? chat, List<ChatMessage> messages, List<ToolRun> runs})>
  _readChat(String chatId) async {
    final chat = await _hub.chatStore.chat(chatId);
    final messages = await _hub.chatStore.messages(chatId);
    final runs = await _hub.chatStore.toolRunsForChat(chatId);
    return (chat: chat, messages: messages, runs: runs);
  }

  Future<void> _reload(Emitter<ChatState> emit) async {
    final chatId = state.chatId;
    if (chatId == null) return;
    final snapshot = await _readChat(chatId);
    final usage = await _usageOf(chatId);
    final activeIds = {
      for (final r in snapshot.runs)
        if (r.isActive) r.id,
    };
    final live = {
      for (final entry in state.live.entries)
        if (activeIds.contains(entry.key)) entry.key: entry.value,
    };
    final limit = _contextLimitOf(
      snapshot.chat,
      state.catalog,
      state.defaultModelId,
    );
    emit(
      state.copyWith(
        chat: snapshot.chat,
        messages: snapshot.messages,
        runs: snapshot.runs,
        live: live,
        approvals: _hub.broker.pendingApprovals(chatId),
        questions: _hub.broker.pendingQuestions(chatId),
        editFileChanges: _hub.broker.pendingEditFileChanges(chatId),
        isRunning: _session?.isRunning ?? false,
        contextLimit: limit,
        clearContextLimit: limit == null,
        contextWindowKnown: limit != null,
        dailyCostUsd: usage.usage.costUsd,
        dailyBudgetUsd: usage.budget,
        clearDailyBudget: usage.budget == null,
        compactionInfo: usage.compaction,
        clearCompactionInfo: usage.compaction == null,
      ),
    );
  }

  Future<
    ({ChatDailyUsage usage, double? budget, ChatCompactionInfo? compaction})
  >
  _usageOf(String chatId) async => (
    usage: await _hub.settings.readDailyUsage(chatId),
    budget: await _hub.settings.readDailyBudget(chatId),
    compaction: await _hub.settings.readCompactionInfo(chatId),
  );

  List<String> _queueTexts() => [
    for (final item in _session?.queue ?? const <QueuedPrompt>[]) item.text,
  ];
}

final class _ConflictChanged extends ChatEvent {
  const _ConflictChanged(this.conflict);

  final DraftConflict conflict;
}

final class _SessionsChanged extends ChatEvent {
  const _SessionsChanged(this.sessions);

  final List<ClientSessionView> sessions;
}

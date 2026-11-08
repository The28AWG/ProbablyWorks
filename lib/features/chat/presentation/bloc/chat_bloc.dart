import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/domain/steps_display.dart';
import 'package:probably_works/agent/exec/live_output_bus.dart';
import 'package:probably_works/agent/interaction/interaction_broker.dart';
import 'package:probably_works/agent/loop/agent_event.dart';
import 'package:probably_works/agent/loop/agent_hub.dart';
import 'package:probably_works/agent/loop/chat_session.dart';
import 'package:probably_works/agent/loop/prompt_queue.dart';
import 'package:probably_works/core/config/app_limits.dart';
import 'package:probably_works/core/data/chat_draft_store.dart';
import 'package:probably_works/core/data/host_repository.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/error/app_failure.dart';
import 'package:probably_works/core/platform/app_platform.dart';
import 'package:probably_works/host/host_terminal.dart';
import 'package:probably_works/providers/ai/llm_port.dart';
import 'package:probably_works/providers/ai/model_catalog.dart';

// ---- events -----------------------------------------------------------------

sealed class ChatEvent extends Equatable {
  const ChatEvent();

  @override
  List<Object?> get props => [];
}

/// Открытие чата: существующего или нового. Такие события идут по очереди (см. [ChatBloc]).
sealed class ChatOpenEvent extends ChatEvent {
  const ChatOpenEvent();
}

final class ChatOpened extends ChatOpenEvent {
  const ChatOpened(this.chatId, {this.seedChat, this.seedHosts = const []});

  final String chatId;

  /// Чат из уже загруженного списка (см. [ChatBloc]): показывается сразу, до чтения данных.
  final Chat? seedChat;
  final List<Host> seedHosts;

  @override
  List<Object?> get props => [chatId];
}

/// Текст в поле ввода изменился (набор, вставка, очистка). Состояние не меняется, чтобы каждый символ
/// не перерисовывал экран: блок только запоминает черновик.
final class ChatDraftEdited extends ChatEvent {
  const ChatDraftEdited(this.text);

  final String text;

  @override
  List<Object?> get props => [text];
}

/// К черновику добавлены вложения (файлы уже прочитаны). Сверх лимита сообщения отбрасываются.
final class ChatAttachmentsAdded extends ChatEvent {
  const ChatAttachmentsAdded(this.items);

  final List<AttachmentRef> items;

  @override
  List<Object?> get props => [items];
}

final class ChatAttachmentRemoved extends ChatEvent {
  const ChatAttachmentRemoved(this.index);

  final int index;

  @override
  List<Object?> get props => [index];
}

final class ChatSubmitted extends ChatEvent {
  const ChatSubmitted(
    this.text, {
    this.attachments = const [],
    this.sendNow = false,
  });

  final String text;
  final List<AttachmentRef> attachments;
  final bool sendNow;
}

final class ChatStopped extends ChatEvent {
  const ChatStopped();
}

final class ChatContinued extends ChatEvent {
  const ChatContinued();
}

final class ChatApprovalAnswered extends ChatEvent {
  const ChatApprovalAnswered(this.requestId, {required this.allow});

  final String requestId;
  final bool allow;

  @override
  List<Object?> get props => [requestId, allow];
}

final class ChatQuestionAnswered extends ChatEvent {
  const ChatQuestionAnswered(this.questionId, this.text);

  final String questionId;
  final String text;

  @override
  List<Object?> get props => [questionId, text];
}

final class ChatMessageEdited extends ChatEvent {
  const ChatMessageEdited(this.messageId, this.text);

  final String messageId;
  final String text;

  @override
  List<Object?> get props => [messageId, text];
}

final class ChatDeletedAfter extends ChatEvent {
  const ChatDeletedAfter(this.messageId);

  final String messageId;

  @override
  List<Object?> get props => [messageId];
}

final class ChatModelChanged extends ChatEvent {
  const ChatModelChanged(this.model);

  final LlmModelInfo model;

  @override
  List<Object?> get props => [model.id];
}

final class ChatPolicyChanged extends ChatEvent {
  const ChatPolicyChanged(this.mode);

  final PolicyMode mode;

  @override
  List<Object?> get props => [mode];
}

final class ChatHostChanged extends ChatEvent {
  const ChatHostChanged(this.hostId);

  final String hostId;

  @override
  List<Object?> get props => [hostId];
}

final class ChatWorkspaceChanged extends ChatEvent {
  const ChatWorkspaceChanged(this.workspace);

  final String? workspace;

  @override
  List<Object?> get props => [workspace];
}

final class ChatWorkspaceTrusted extends ChatEvent {
  const ChatWorkspaceTrusted();
}

final class ChatRunStopRequested extends ChatEvent {
  const ChatRunStopRequested(this.runId);

  final String runId;

  @override
  List<Object?> get props => [runId];
}

/// Элемент очереди: отправить сейчас (прерывает текущий шаг модели).
final class ChatQueueSendNow extends ChatEvent {
  const ChatQueueSendNow(this.index);

  final int index;

  @override
  List<Object?> get props => [index];
}

/// Элемент очереди: удалить.
final class ChatQueueRemoved extends ChatEvent {
  const ChatQueueRemoved(this.index);

  final int index;

  @override
  List<Object?> get props => [index];
}

/// Элемент очереди: вернуть текст в поле ввода для правки.
final class ChatQueueEdited extends ChatEvent {
  const ChatQueueEdited(this.index);

  final int index;

  @override
  List<Object?> get props => [index];
}

/// Новый чат: стартовый экран без записи в БД. Чат создаётся при первой отправке. Черновик текущего
/// чата переносится в новый, а исходный очищается.
final class ChatDraftOpened extends ChatOpenEvent {
  const ChatDraftOpened();
}

/// Закрепить или открепить модель в быстром списке.
final class ChatModelPinToggled extends ChatEvent {
  const ChatModelPinToggled(this.modelId);

  final String modelId;

  @override
  List<Object?> get props => [modelId];
}

/// Ручное сжатие истории (кнопка в контексте).
final class ChatCompactRequested extends ChatEvent {
  const ChatCompactRequested();

  @override
  List<Object?> get props => [];
}

/// Внутренние события: поток из сессии, брокера и шины вывода.
final class _SessionEvent extends ChatEvent {
  const _SessionEvent(this.event);

  final AgentEvent event;
}

final class _LiveChunk extends ChatEvent {
  const _LiveChunk(this.runId, this.text);

  final String runId;
  final String text;

  @override
  List<Object?> get props => [runId, text];
}

final class _LiveFlush extends ChatEvent {
  const _LiveFlush();
}

final class _Refresh extends ChatEvent {
  const _Refresh();
}

/// Каталог моделей изменился (загружен, обновлён в фоне или запомнены детали моделей).
final class _CatalogChanged extends ChatEvent {
  const _CatalogChanged(this.catalog);

  final ModelCatalogState catalog;
}

/// Настройки журнала шагов изменились в Settings: перечитать их, даже если чат уже открыт.
final class _StepsChanged extends ChatEvent {
  const _StepsChanged();
}

/// Закреплённые модели изменились в Settings или в композере другого чата: список выбора обновляется сразу.
final class _PinnedChanged extends ChatEvent {
  const _PinnedChanged();
}

/// Список хостов изменился (добавлен, отредактирован, удалён): меню хостов в композере обновляется сразу.
final class _HostsChanged extends ChatEvent {
  const _HostsChanged(this.hosts);

  final List<Host> hosts;

  @override
  List<Object?> get props => [hosts];
}

// ---- state ------------------------------------------------------------------

class ChatState extends Equatable {
  const ChatState({
    this.chatId,
    this.chat,
    this.messages = const [],
    this.runs = const [],
    this.queue = const [],
    this.approvals = const [],
    this.questions = const [],
    this.hosts = const [],
    this.catalog = const ModelCatalogState(),
    this.pinnedModels = const [],
    this.stepsDisplay = StepsDisplay.defaults,
    this.defaultModelId,
    this.limits = AppLimits.defaults,
    this.streamText = '',
    this.streamReasoning = '',
    this.live = const {},
    this.isRunning = false,
    this.stepLimitReached = false,
    this.failure,
    this.failureModelMissing = false,
    this.promptTokens,
    this.contextLimit,
    this.trustNeeded = false,
    this.loading = false,
    this.attachments = const [],
    this.draft = '',
    this.draftId = 0,
    this.unsaved = false,
  });

  final String? chatId;
  final Chat? chat;

  /// Чат ещё не записан в БД (новый чат до первой отправки). Его настройки живут в памяти.
  final bool unsaved;
  final List<ChatMessage> messages;
  final List<ToolRun> runs;
  final List<String> queue;
  final List<ApprovalRequest> approvals;
  final List<UserQuestion> questions;
  final List<Host> hosts;

  /// Каталог моделей: список, статус загрузки и сохранённые детали выбранных моделей.
  final ModelCatalogState catalog;

  /// Закреплённые id моделей из Settings (показываются первыми в picker).
  final List<String> pinnedModels;

  /// Поведение журнала шагов из Settings: группировка, видимость мыслей и вызовов.
  final StepsDisplay stepsDisplay;

  /// Модель по умолчанию из Settings. Новый чат её не копирует: агент берёт её, пока у чата нет своей.
  final String? defaultModelId;
  final AppLimits limits;

  /// Модель, которую агент реально использует в этом чате: своя или по умолчанию. Null, если ничего не выбрано.
  String? get effectiveModelId {
    final own = chat?.model;
    if (own != null && own.isNotEmpty) return own;
    if (defaultModelId != null && defaultModelId!.isNotEmpty) {
      return defaultModelId;
    }
    return null;
  }

  /// Модели пока нет, но чат ещё грузится: модель по умолчанию из Settings не прочитана, и отсутствие
  /// выбора пока не доказано. Предупреждать об этом рано; после загрузки null означает реальную ошибку.
  bool get modelPending => loading && effectiveModelId == null;

  /// Статус модели чата по кешу каталога. Недоступная модель не блокирует отправку: `!` предупреждает.
  ModelStatus get modelStatus => catalog.statusOf(effectiveModelId);

  bool get modelUnavailable => modelStatus == ModelStatus.unavailable;

  /// Текст шага, который ещё не записан в БД (живой стрим).
  final String streamText;

  /// Рассуждения модели, которые ещё не записаны в БД (живой стрим).
  final String streamReasoning;

  /// Живой вывод команд по runId (только пока команда выполняется).
  final Map<String, String> live;
  final bool isRunning;
  final bool stepLimitReached;
  final String? failure;

  /// Последняя ошибка — модель не найдена на сервере (см. [failureIsModelMissing]).
  final bool failureModelMissing;

  /// Ошибка есть и она из-за модели: док показывает предупреждение о модели вместо сырого текста.
  bool get failureIsModelMissing => failure != null && failureModelMissing;
  final int? promptTokens;
  final int? contextLimit;
  final bool trustNeeded;
  final bool loading;

  /// Вложения черновика текущего чата (до отправки).
  final List<AttachmentRef> attachments;

  /// Текст, который нужно положить в поле ввода: смена чата, правка элемента очереди, подсказка.
  /// [draftId] меняется на каждый такой запрос, поэтому поле переписывается только по нему.
  final String draft;
  final int draftId;

  ChatState copyWith({
    String? chatId,
    Chat? chat,
    List<ChatMessage>? messages,
    List<ToolRun>? runs,
    List<String>? queue,
    List<ApprovalRequest>? approvals,
    List<UserQuestion>? questions,
    List<Host>? hosts,
    ModelCatalogState? catalog,
    List<String>? pinnedModels,
    StepsDisplay? stepsDisplay,
    String? defaultModelId,
    AppLimits? limits,
    String? streamText,
    String? streamReasoning,
    Map<String, String>? live,
    bool? isRunning,
    bool? stepLimitReached,
    String? failure,
    bool? failureModelMissing,
    bool clearFailure = false,
    int? promptTokens,
    int? contextLimit,
    bool? trustNeeded,
    bool? loading,
    List<AttachmentRef>? attachments,
    String? draft,
    int? draftId,
    bool? unsaved,
  }) => ChatState(
    chatId: chatId ?? this.chatId,
    chat: chat ?? this.chat,
    messages: messages ?? this.messages,
    runs: runs ?? this.runs,
    queue: queue ?? this.queue,
    approvals: approvals ?? this.approvals,
    questions: questions ?? this.questions,
    hosts: hosts ?? this.hosts,
    catalog: catalog ?? this.catalog,
    pinnedModels: pinnedModels ?? this.pinnedModels,
    stepsDisplay: stepsDisplay ?? this.stepsDisplay,
    defaultModelId: defaultModelId ?? this.defaultModelId,
    limits: limits ?? this.limits,
    streamText: streamText ?? this.streamText,
    streamReasoning: streamReasoning ?? this.streamReasoning,
    live: live ?? this.live,
    isRunning: isRunning ?? this.isRunning,
    stepLimitReached: stepLimitReached ?? this.stepLimitReached,
    failure: clearFailure ? null : (failure ?? this.failure),
    failureModelMissing: failureModelMissing ?? this.failureModelMissing,
    promptTokens: promptTokens ?? this.promptTokens,
    contextLimit: contextLimit ?? this.contextLimit,
    trustNeeded: trustNeeded ?? this.trustNeeded,
    loading: loading ?? this.loading,
    attachments: attachments ?? this.attachments,
    draft: draft ?? this.draft,
    draftId: draftId ?? this.draftId,
    unsaved: unsaved ?? this.unsaved,
  );

  @override
  List<Object?> get props => [
    chatId,
    chat,
    messages,
    runs,
    queue,
    approvals,
    questions,
    hosts,
    catalog,
    pinnedModels,
    stepsDisplay,
    defaultModelId,
    limits,
    streamText,
    streamReasoning,
    live,
    isRunning,
    stepLimitReached,
    failure,
    failureModelMissing,
    promptTokens,
    contextLimit,
    trustNeeded,
    loading,
    attachments,
    draft,
    draftId,
    unsaved,
  ];
}

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
  }) : super(initialState ?? _seedState(_hub, _drafts, seedChat, seedHosts)) {
    _composerText = state.draft;
    on<ChatOpenEvent>(_onOpenEvent, transformer: _sequential());
    on<ChatDraftEdited>(_onDraftEdited);
    on<ChatAttachmentsAdded>(_onAttachmentsAdded);
    on<ChatAttachmentRemoved>(_onAttachmentRemoved);
    on<ChatSubmitted>(_onSubmitted);
    on<ChatStopped>((_, _) async => _session?.stop());
    on<ChatContinued>((_, _) async => _session?.continueAfterStepLimit());
    on<ChatApprovalAnswered>(_onApproval);
    on<ChatQuestionAnswered>(_onQuestion);
    on<ChatMessageEdited>(_onEdited);
    on<ChatDeletedAfter>(_onDeletedAfter);
    on<ChatModelChanged>(_onModelChanged);
    on<ChatModelPinToggled>(_onModelPinToggled);
    on<ChatPolicyChanged>(_onPolicyChanged);
    on<ChatHostChanged>(_onHostChanged);
    on<ChatWorkspaceChanged>(_onWorkspaceChanged);
    on<ChatWorkspaceTrusted>(_onTrusted);
    on<ChatRunStopRequested>(_onRunStop);
    on<ChatQueueSendNow>(
      (event, _) async => _session?.promoteQueued(event.index),
    );
    on<ChatQueueRemoved>((event, _) async => _session?.takeQueued(event.index));
    on<ChatQueueEdited>(_onQueueEdited);
    on<ChatCompactRequested>(_onCompactRequested);
    on<_SessionEvent>(_onSessionEvent);
    on<_LiveChunk>(_onLiveChunk);
    on<_LiveFlush>(_onLiveFlush);
    on<_Refresh>(_onRefresh);
    on<_StepsChanged>(_onStepsChanged);
    on<_PinnedChanged>(_onPinnedChanged);
    on<_CatalogChanged>(
      (event, emit) => emit(state.copyWith(catalog: event.catalog)),
    );
    on<_HostsChanged>(
      (event, emit) => emit(state.copyWith(hosts: event.hosts)),
    );
  }

  final AgentHub _hub;
  final LiveOutputBus _bus;
  final ChatDraftStore _drafts;

  /// Вызывается, когда новый чат записан в БД после первой отправки: экран переключает выбор на него.
  final void Function(String chatId)? onChatCreated;

  /// Текст поля ввода, как его знает блок: обновляется из [ChatDraftEdited] без перерисовки.
  String _composerText = '';

  /// Подписки на сессию выбранного чата; меняются при смене чата.
  ChatSession? _session;
  StreamSubscription<AgentEvent>? _sessionSub;
  StreamSubscription<LiveChunk>? _liveSub;
  StreamSubscription<ApprovalRequest>? _approvalSub;
  StreamSubscription<UserQuestion>? _questionSub;

  /// Общие подписки блока (каталог, хосты, журнал шагов): живут, пока открыт блок, и не зависят от чата.
  var _sharedWatching = false;
  StreamSubscription<ModelCatalogState>? _catalogSub;
  StreamSubscription<List<Host>>? _hostsSub;
  final _stepsSubs = <StreamSubscription<String?>>[];
  StreamSubscription<String?>? _pinsSub;
  final Map<String, StringBuffer> _pendingLive = {};
  Timer? _liveTimer;

  static const _liveThrottle = Duration(milliseconds: 100);

  /// Терминал, в котором сейчас выполняется запуск; `null`, если он не выполняется в PTY или уже завершён.
  HostTerminal? terminalFor(String runId) =>
      _hub.registry.find(runId)?.terminal;

  /// Состояние на время смены чата. Композер (чат для настроек, модель, папка, хосты, черновик) и каталог
  /// остаются от прежнего чата, пока не придут данные нового: без пустого кадра и мелькания. Лента,
  /// подтверждения и вопросы относятся к старому чату и сбрасываются.
  ChatState _switchState(ChatOpened event) {
    // Черновик нового чата берём из памяти или из списка: поле ввода сразу показывает его текст.
    _drafts.prime(event.chatId, event.seedChat);
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
        contextLimit: state.contextLimit,
        draftId: state.draftId,
        isRunning: _session?.isRunning ?? false,
        queue: _queueTexts(),
        approvals: _hub.broker.pendingApprovals(event.chatId),
        questions: _hub.broker.pendingQuestions(event.chatId),
        loading: true,
      ),
      _drafts.of(event.chatId),
    );
  }

  /// Кладёт черновик в поле ввода: текст и вложения. ChatBody переписывает поле, когда меняется [draftId].
  ChatState _pushDraft(ChatState from, ChatDraft draft) {
    _composerText = draft.text;
    return from.copyWith(
      draft: draft.text,
      draftId: from.draftId + 1,
      attachments: draft.attachments,
    );
  }

  /// Текущий черновик (текст из блока и вложения) — в память и, с задержкой, в БД.
  void _saveDraft() {
    final chatId = state.chatId;
    if (chatId == null) return;
    _drafts.update(
      chatId,
      ChatDraft(text: _composerText, attachments: state.attachments),
    );
  }

  /// Начальное состояние из уже известных данных (список чатов и каталог в памяти). Только чтения,
  /// без сети и без БД: блок стартует с правильной шапкой, черновиком и композером.
  static ChatState _seedState(
    AgentHub hub,
    ChatDraftStore drafts,
    Chat? chat,
    List<Host> hosts,
  ) {
    // Новый чат: всё уже в памяти (хосты, настройки), поэтому первый кадр строит готовый экран.
    if (chat == null) return _newChatState(hub, hosts, draftId: 0);
    drafts.prime(chat.id, chat);
    final draft = drafts.of(chat.id);
    final session = hub.session(chat.id);
    return ChatState(
      chatId: chat.id,
      chat: chat,
      hosts: hosts,
      catalog: hub.models.state,
      approvals: hub.broker.pendingApprovals(chat.id),
      questions: hub.broker.pendingQuestions(chat.id),
      isRunning: session.isRunning,
      queue: [for (final item in session.queue) item.text],
      draft: draft.text,
      attachments: draft.attachments,
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
    await _sessionSub?.cancel();
    await _liveSub?.cancel();
    await _approvalSub?.cancel();
    await _questionSub?.cancel();
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
    _hostsSub = _hub.hosts
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
    // Каталог может обновиться в фоне (старт, таймер, Settings): чат перерисует подпись модели и маркер.
    _catalogSub = _hub.models.watch().listen(
      (catalog) => add(_CatalogChanged(catalog)),
    );
  }

  /// Снимает подписки на сессию чата, если они были.
  Future<void> _detach() async {
    await _sessionSub?.cancel();
    await _liveSub?.cancel();
    await _approvalSub?.cancel();
    await _questionSub?.cancel();
    _sessionSub = null;
    _liveSub = null;
    _approvalSub = null;
    _questionSub = null;
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
    // Карточки этого чата — из базы, не при старте приложения.
    // Если ход уже продолжен после старта, здесь только показываем карточки.
    await _session?.restoreUnanswered();
    // Один emit на открытие: каждый промежуточный emit перестраивает весь экран чата на UI-потоке.
    final loaded = state.copyWith(
      hosts: shared.hosts,
      limits: shared.limits,
      catalog: _hub.models.state,
      pinnedModels: shared.pinned,
      stepsDisplay: shared.stepsDisplay,
      defaultModelId: shared.defaultModel,
      chat: snapshot.chat,
      messages: snapshot.messages,
      runs: snapshot.runs,
      approvals: _hub.broker.pendingApprovals(event.chatId),
      questions: _hub.broker.pendingQuestions(event.chatId),
      contextLimit: snapshot.chat?.contextLength ?? state.contextLimit,
      isRunning: _session?.isRunning ?? false,
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
  Future<
    ({
      List<Host> hosts,
      AppLimits limits,
      List<String> pinned,
      StepsDisplay stepsDisplay,
      String? defaultModel,
    })
  >
  _readShared() async => (
    hosts: await _hub.hosts.all(),
    limits: await _hub.limits(),
    pinned: await _hub.settings.readPinnedModels(),
    stepsDisplay: await _hub.settings.readStepsDisplay(),
    defaultModel: await _hub.settings.read(SettingsRepository.keyDefaultModel),
  );

  /// Состояние нового чата из настроек и хостов в памяти: без чтений БД и сети. Черновик в блоке пока
  /// не записан: чат появится в БД с первым сообщением (см. [AgentHub.draftChat]).
  static ChatState _newChatState(
    AgentHub hub,
    List<Host> hosts, {
    required int draftId,
  }) {
    final settings = hub.settings;
    final chat = hub.draftChat(hostId: _defaultHostId(hosts));
    return ChatState(
      hosts: hosts,
      limits: settings.cachedLimits(),
      catalog: hub.models.state,
      pinnedModels: settings.cachedPinnedModels(),
      stepsDisplay: settings.cachedStepsDisplay(),
      defaultModelId: settings.cached(SettingsRepository.keyDefaultModel),
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
        emit(state.copyWith(hosts: await _hub.hosts.all()));
      }
      _watchShared();
      return;
    }
    final carried = from != null && !state.unsaved && !_drafts.of(from).isEmpty;
    await _detach();
    // Хосты из списка уже в памяти; блок, созданный без списка, читает их из БД.
    final hosts = state.hosts.isEmpty ? await _hub.hosts.all() : state.hosts;
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
    emit(state.copyWith(attachments: const []));
    _saveDraft();
    await session.submit(
      event.text,
      attachments: event.attachments,
      sendNow: event.sendNow,
    );
    emit(state.copyWith(queue: _queueTexts(), clearFailure: true));
    if (created) onChatCreated?.call(state.chatId!);
  }

  /// Первая отправка в новом чате: чат записывается в БД, и блок начинает слушать его сессию.
  Future<void> _saveNewChat(Emitter<ChatState> emit) async {
    final now = DateTime.now();
    final chat = state.chat!.copyWith(createdAt: now, updatedAt: now);
    await _hub.chats.saveChat(chat);
    await _attach(chat.id);
    emit(state.copyWith(chat: chat, unsaved: false));
  }

  /// Изменения настроек нового чата остаются в памяти: запись появится с первой отправкой.
  Future<void> _persistChat(Chat chat) async {
    if (!state.unsaved) await _hub.chats.saveChat(chat);
  }

  void _onDraftEdited(ChatDraftEdited event, Emitter<ChatState> emit) {
    // Поле уведомляет и о смене выделения (например, при получении фокуса): тот же текст в черновик не пишем.
    if (event.text == _composerText) return;
    _composerText = event.text;
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

  void _onApproval(ChatApprovalAnswered event, Emitter<ChatState> emit) {
    _hub.broker.resolveApproval(event.requestId, allow: event.allow);
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
    await _session?.editUserMessage(event.messageId, event.text);
  }

  Future<void> _onDeletedAfter(
    ChatDeletedAfter event,
    Emitter<ChatState> emit,
  ) async {
    await _session?.deleteAfter(event.messageId);
  }

  Future<void> _onModelChanged(
    ChatModelChanged event,
    Emitter<ChatState> emit,
  ) async {
    final chat = state.chat;
    if (chat == null) return;
    final updated = chat.copyWith(
      model: event.model.id,
      contextLength: event.model.contextLength,
    );
    await _hub.models.remember([event.model.id]);
    await _persistChat(updated);
    emit(
      state.copyWith(chat: updated, contextLimit: event.model.contextLength),
    );
    // Новое окно модели может быть меньше: проверяем бюджет сразу, не дожидаясь следующего хода.
    final session = _session;
    if (session != null && !session.isRunning) unawaited(session.compactNow());
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
        ChatDraft(text: item.text, attachments: state.attachments),
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

  Future<void> _onPolicyChanged(
    ChatPolicyChanged event,
    Emitter<ChatState> emit,
  ) async {
    final chat = state.chat;
    if (chat == null) return;
    final updated = chat.copyWith(policyMode: event.mode);
    await _persistChat(updated);
    emit(state.copyWith(chat: updated));
  }

  Future<void> _onHostChanged(
    ChatHostChanged event,
    Emitter<ChatState> emit,
  ) async {
    final chat = state.chat;
    if (chat == null || (_session?.isRunning ?? false)) return;
    final updated = chat.copyWith(hostId: event.hostId);
    await _persistChat(updated);
    emit(state.copyWith(chat: updated));
  }

  Future<void> _onWorkspaceChanged(
    ChatWorkspaceChanged event,
    Emitter<ChatState> emit,
  ) async {
    final chat = state.chat;
    if (chat == null) return;
    final updated = chat.copyWith(workspace: event.workspace);
    await _persistChat(updated);
    emit(state.copyWith(chat: updated, trustNeeded: false));
  }

  Future<void> _onTrusted(
    ChatWorkspaceTrusted event,
    Emitter<ChatState> emit,
  ) async {
    final chat = state.chat;
    final workspace = chat?.workspace;
    if (chat == null || workspace == null) return;
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
            queue: _queueTexts(),
          ),
        );
        await _reload(emit);
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
          ),
        );
        await _reload(emit);
      case AgentRunChanged():
        await _reload(emit);
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
      case AgentUsageUpdated(:final promptTokens, :final limit):
        emit(state.copyWith(promptTokens: promptTokens, contextLimit: limit));
      case AgentStateChanged():
        await _reload(emit);
    }
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

  Future<void> _onRefresh(_Refresh event, Emitter<ChatState> emit) async {
    final chatId = state.chatId;
    if (chatId == null) return;
    emit(
      state.copyWith(
        approvals: _hub.broker.pendingApprovals(chatId),
        questions: _hub.broker.pendingQuestions(chatId),
      ),
    );
  }

  /// Чат, сообщения и запуски из БД. Без emit: вызывающий сам решает, когда перерисовать экран.
  Future<({Chat? chat, List<ChatMessage> messages, List<ToolRun> runs})>
  _readChat(String chatId) async {
    final chat = await _hub.chats.chat(chatId);
    final messages = await _hub.chats.messages(chatId);
    final runs = await _hub.chats.toolRunsForChat(chatId);
    return (chat: chat, messages: messages, runs: runs);
  }

  /// Перечитывает чат, сообщения и запуски из БД; очищает живой вывод завершившихся запусков.
  Future<void> _reload(Emitter<ChatState> emit) async {
    final chatId = state.chatId;
    if (chatId == null) return;
    final snapshot = await _readChat(chatId);
    final activeIds = {
      for (final r in snapshot.runs)
        if (r.isActive) r.id,
    };
    final live = {
      for (final entry in state.live.entries)
        if (activeIds.contains(entry.key)) entry.key: entry.value,
    };
    emit(
      state.copyWith(
        chat: snapshot.chat,
        messages: snapshot.messages,
        runs: snapshot.runs,
        live: live,
        approvals: _hub.broker.pendingApprovals(chatId),
        questions: _hub.broker.pendingQuestions(chatId),
        isRunning: _session?.isRunning ?? false,
        contextLimit: snapshot.chat?.contextLength ?? state.contextLimit,
      ),
    );
  }

  List<String> _queueTexts() => [
    for (final item in _session?.queue ?? const <QueuedPrompt>[]) item.text,
  ];
}

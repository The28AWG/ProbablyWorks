import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/exec/live_output_bus.dart';
import 'package:probably_works/agent/interaction/interaction_broker.dart';
import 'package:probably_works/agent/loop/agent_event.dart';
import 'package:probably_works/agent/loop/agent_hub.dart';
import 'package:probably_works/agent/loop/chat_session.dart';
import 'package:probably_works/agent/loop/prompt_queue.dart';
import 'package:probably_works/core/config/app_limits.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/providers/ai/llm_port.dart';

// ---- events -----------------------------------------------------------------

sealed class ChatEvent extends Equatable {
  const ChatEvent();

  @override
  List<Object?> get props => [];
}

final class ChatOpened extends ChatEvent {
  const ChatOpened(this.chatId);

  final String chatId;

  @override
  List<Object?> get props => [chatId];
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
    this.models = const [],
    this.pinnedModels = const [],
    this.limits = AppLimits.defaults,
    this.streamText = '',
    this.live = const {},
    this.isRunning = false,
    this.stepLimitReached = false,
    this.failure,
    this.promptTokens,
    this.contextLimit,
    this.trustNeeded = false,
    this.loading = false,
    this.draft = '',
    this.draftId = 0,
  });

  final String? chatId;
  final Chat? chat;
  final List<ChatMessage> messages;
  final List<ToolRun> runs;
  final List<String> queue;
  final List<ApprovalRequest> approvals;
  final List<UserQuestion> questions;
  final List<Host> hosts;
  final List<LlmModelInfo> models;

  /// Закреплённые id моделей из Settings (показываются первыми в picker).
  final List<String> pinnedModels;
  final AppLimits limits;

  /// Текст шага, который ещё не записан в БД (живой стрим).
  final String streamText;

  /// Живой вывод команд по runId (только пока команда выполняется).
  final Map<String, String> live;
  final bool isRunning;
  final bool stepLimitReached;
  final String? failure;
  final int? promptTokens;
  final int? contextLimit;
  final bool trustNeeded;
  final bool loading;

  /// Текст, который нужно положить в поле ввода (правка элемента очереди). [draftId] меняется на каждый запрос.
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
    List<LlmModelInfo>? models,
    List<String>? pinnedModels,
    AppLimits? limits,
    String? streamText,
    Map<String, String>? live,
    bool? isRunning,
    bool? stepLimitReached,
    String? failure,
    bool clearFailure = false,
    int? promptTokens,
    int? contextLimit,
    bool? trustNeeded,
    bool? loading,
    String? draft,
    int? draftId,
  }) => ChatState(
    chatId: chatId ?? this.chatId,
    chat: chat ?? this.chat,
    messages: messages ?? this.messages,
    runs: runs ?? this.runs,
    queue: queue ?? this.queue,
    approvals: approvals ?? this.approvals,
    questions: questions ?? this.questions,
    hosts: hosts ?? this.hosts,
    models: models ?? this.models,
    pinnedModels: pinnedModels ?? this.pinnedModels,
    limits: limits ?? this.limits,
    streamText: streamText ?? this.streamText,
    live: live ?? this.live,
    isRunning: isRunning ?? this.isRunning,
    stepLimitReached: stepLimitReached ?? this.stepLimitReached,
    failure: clearFailure ? null : (failure ?? this.failure),
    promptTokens: promptTokens ?? this.promptTokens,
    contextLimit: contextLimit ?? this.contextLimit,
    trustNeeded: trustNeeded ?? this.trustNeeded,
    loading: loading ?? this.loading,
    draft: draft ?? this.draft,
    draftId: draftId ?? this.draftId,
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
    models,
    pinnedModels,
    limits,
    streamText,
    live,
    isRunning,
    stepLimitReached,
    failure,
    promptTokens,
    contextLimit,
    trustNeeded,
    loading,
    draft,
    draftId,
  ];
}

// ---- bloc -------------------------------------------------------------------

/// UI-состояние одного чата. Данные истины — в БД; состояние держит только то, что нужно отрисовать сейчас.
class ChatBloc extends Bloc<ChatEvent, ChatState> {
  ChatBloc(this._hub, this._bus) : super(const ChatState()) {
    on<ChatOpened>(_onOpened);
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
  }

  final AgentHub _hub;
  final LiveOutputBus _bus;

  ChatSession? _session;
  StreamSubscription<AgentEvent>? _sessionSub;
  StreamSubscription<LiveChunk>? _liveSub;
  StreamSubscription<ApprovalRequest>? _approvalSub;
  StreamSubscription<UserQuestion>? _questionSub;
  final Map<String, StringBuffer> _pendingLive = {};
  Timer? _liveTimer;

  static const _liveThrottle = Duration(milliseconds: 100);

  @override
  Future<void> close() async {
    _liveTimer?.cancel();
    await _sessionSub?.cancel();
    await _liveSub?.cancel();
    await _approvalSub?.cancel();
    await _questionSub?.cancel();
    return super.close();
  }

  Future<void> _onOpened(ChatOpened event, Emitter<ChatState> emit) async {
    await _sessionSub?.cancel();
    await _liveSub?.cancel();
    await _approvalSub?.cancel();
    await _questionSub?.cancel();
    _pendingLive.clear();
    _session = _hub.session(event.chatId);
    emit(ChatState(chatId: event.chatId, loading: true));
    _sessionSub = _session!.events.listen((e) => add(_SessionEvent(e)));
    _liveSub = _bus.stream
        .where((c) => c.chatId == event.chatId)
        .listen((c) => add(_LiveChunk(c.toolCallId, c.text)));
    _approvalSub = _hub.broker.approvalRequests
        .where((r) => r.chatId == event.chatId)
        .listen((_) => add(const _Refresh()));
    _questionSub = _hub.broker.questions
        .where((q) => q.chatId == event.chatId)
        .listen((_) => add(const _Refresh()));

    final hosts = await _hub.hosts.all();
    final limits = await _hub.limits();
    var models = const <LlmModelInfo>[];
    try {
      models = await _hub.llm.listModels();
    } on Object {
      models = const [];
    }
    final pinned = await _hub.settings.readPinnedModels();
    emit(
      state.copyWith(
        hosts: hosts,
        limits: limits,
        models: models,
        pinnedModels: pinned,
      ),
    );
    await _reload(emit);
    emit(
      state.copyWith(
        loading: false,
        isRunning: _session!.isRunning,
        queue: _queueTexts(),
      ),
    );
  }

  Future<void> _onSubmitted(
    ChatSubmitted event,
    Emitter<ChatState> emit,
  ) async {
    final session = _session;
    if (session == null) return;
    await session.submit(
      event.text,
      attachments: event.attachments,
      sendNow: event.sendNow,
    );
    emit(state.copyWith(queue: _queueTexts(), clearFailure: true));
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
    await _hub.chats.saveChat(updated);
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
    await _hub.settings.savePinnedModels(pins);
    emit(state.copyWith(pinnedModels: pins));
  }

  void _onQueueEdited(ChatQueueEdited event, Emitter<ChatState> emit) {
    final item = _session?.takeQueued(event.index);
    if (item == null) return;
    emit(state.copyWith(draft: item.text, draftId: state.draftId + 1));
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
    await _hub.chats.saveChat(updated);
    emit(state.copyWith(chat: updated));
  }

  Future<void> _onHostChanged(
    ChatHostChanged event,
    Emitter<ChatState> emit,
  ) async {
    final chat = state.chat;
    if (chat == null || _session!.isRunning) return;
    final updated = chat.copyWith(hostId: event.hostId);
    await _hub.chats.saveChat(updated);
    emit(state.copyWith(chat: updated));
  }

  Future<void> _onWorkspaceChanged(
    ChatWorkspaceChanged event,
    Emitter<ChatState> emit,
  ) async {
    final chat = state.chat;
    if (chat == null) return;
    final updated = chat.copyWith(workspace: event.workspace);
    await _hub.chats.saveChat(updated);
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
          ),
        );
      case AgentTurnFinished(:final end):
        emit(
          state.copyWith(
            isRunning: false,
            streamText: '',
            stepLimitReached: end == TurnEnd.stepLimit,
            queue: _queueTexts(),
          ),
        );
        await _reload(emit);
      case AgentTextDelta(:final text, :final reset):
        emit(state.copyWith(streamText: reset ? '' : state.streamText + text));
      case AgentMessageAdded(:final message):
        emit(
          state.copyWith(
            streamText: message.role == MessageRole.assistant
                ? ''
                : state.streamText,
          ),
        );
        await _reload(emit);
      case AgentRunChanged():
        await _reload(emit);
      case AgentQueueChanged():
        emit(state.copyWith(queue: _queueTexts()));
      case AgentFailureRaised(:final failure):
        emit(state.copyWith(failure: failure.message));
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

  /// Перечитывает чат, сообщения и запуски из БД; очищает живой вывод завершившихся запусков.
  Future<void> _reload(Emitter<ChatState> emit) async {
    final chatId = state.chatId;
    if (chatId == null) return;
    final chat = await _hub.chats.chat(chatId);
    final messages = await _hub.chats.messages(chatId);
    final runs = await _hub.chats.toolRunsForChat(chatId);
    final activeIds = {
      for (final r in runs)
        if (r.isActive) r.id,
    };
    final live = {
      for (final entry in state.live.entries)
        if (activeIds.contains(entry.key)) entry.key: entry.value,
    };
    emit(
      state.copyWith(
        chat: chat,
        messages: messages,
        runs: runs,
        live: live,
        approvals: _hub.broker.pendingApprovals(chatId),
        questions: _hub.broker.pendingQuestions(chatId),
        isRunning: _session?.isRunning ?? false,
        contextLimit: chat?.contextLength ?? state.contextLimit,
      ),
    );
  }

  List<String> _queueTexts() => [
    for (final item in _session?.queue ?? const <QueuedPrompt>[]) item.text,
  ];
}

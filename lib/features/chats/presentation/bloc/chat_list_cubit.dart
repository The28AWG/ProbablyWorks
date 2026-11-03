import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/interaction/interaction_broker.dart';
import 'package:probably_works/agent/loop/agent_event.dart';
import 'package:probably_works/agent/loop/agent_hub.dart';
import 'package:probably_works/core/data/chat_draft_store.dart';
import 'package:probably_works/core/domain/host.dart';

class ChatListState extends Equatable {
  const ChatListState({
    this.chats = const [],
    this.selectedId,
    this.hosts = const [],
    this.runningIds = const {},
    this.waitingIds = const {},
  });

  final List<Chat> chats;
  final String? selectedId;
  final List<Host> hosts;

  /// Чаты с идущим ходом агента.
  final Set<String> runningIds;

  /// Чаты, где агент ждёт approve или ответа пользователя.
  final Set<String> waitingIds;

  ChatListState copyWith({
    List<Chat>? chats,
    String? selectedId,
    bool clearSelection = false,
    List<Host>? hosts,
    Set<String>? runningIds,
    Set<String>? waitingIds,
  }) => ChatListState(
    chats: chats ?? this.chats,
    selectedId: clearSelection ? null : (selectedId ?? this.selectedId),
    hosts: hosts ?? this.hosts,
    runningIds: runningIds ?? this.runningIds,
    waitingIds: waitingIds ?? this.waitingIds,
  );

  @override
  List<Object?> get props => [chats, selectedId, hosts, runningIds, waitingIds];
}

class ChatListCubit extends Cubit<ChatListState> {
  ChatListCubit(this._hub, this._drafts) : super(const ChatListState()) {
    _chatsSub = _hub.chats.watchChats().listen((chats) {
      emit(state.copyWith(chats: chats));
      _refreshActivity();
    });
    _hostsSub = _hub.hosts.watchAll().listen(
      (hosts) => emit(state.copyWith(hosts: hosts)),
    );
    // Текстовые дельты приходят на каждый токен: на них активность не меняется, пересчёт не нужен.
    _activitySub = _hub.allEvents
        .where(
          (event) =>
              event is AgentTurnStarted ||
              event is AgentTurnFinished ||
              event is AgentRunChanged,
        )
        .listen((_) => _refreshActivity());
    _approvalSub = _hub.broker.approvalRequests.listen(
      (_) => _refreshActivity(),
    );
    _questionSub = _hub.broker.questions.listen((_) => _refreshActivity());
    _refreshActivity();
  }

  final AgentHub _hub;
  final ChatDraftStore _drafts;
  late final StreamSubscription<List<Chat>> _chatsSub;
  late final StreamSubscription<List<Host>> _hostsSub;
  late final StreamSubscription<AgentEvent> _activitySub;
  late final StreamSubscription<ApprovalRequest> _approvalSub;
  late final StreamSubscription<UserQuestion> _questionSub;

  /// Выбор чата. `null` — стартовый экран нового чата: чат создастся при первой отправке.
  void select(String? chatId) =>
      emit(state.copyWith(selectedId: chatId, clearSelection: chatId == null));

  /// Пересчитывает бейджи: идёт ход или ждётся approve/ответ.
  void _refreshActivity() {
    if (isClosed) return;
    final waiting = {
      for (final chat in state.chats)
        if (_hub.broker.pendingApprovals(chat.id).isNotEmpty ||
            _hub.broker.pendingQuestions(chat.id).isNotEmpty)
          chat.id,
    };
    final running = _hub.runningChatIds;
    if (setEquals(running, state.runningIds) &&
        setEquals(waiting, state.waitingIds)) {
      return;
    }
    emit(state.copyWith(runningIds: running, waitingIds: waiting));
  }

  Future<void> rename(String chatId, String title) async {
    final chat = await _hub.chats.chat(chatId);
    final trimmed = title.trim();
    if (chat == null || trimmed.isEmpty) return;
    await _hub.chats.saveChat(
      chat.copyWith(title: trimmed, titleSource: ChatTitleSource.user),
    );
  }

  /// Удаление: сначала останавливаем активный ход, затем чистим БД и файлы логов чата.
  Future<void> delete(String chatId) async {
    final session = _hub.session(chatId);
    if (session.isRunning) await session.stop();
    await _hub.chats.deleteChat(chatId);
    _drafts.discard(chatId);
    await _hub.logs.deleteChat(chatId);
    if (state.selectedId == chatId) emit(state.copyWith(clearSelection: true));
  }

  @override
  Future<void> close() async {
    await _chatsSub.cancel();
    await _hostsSub.cancel();
    await _activitySub.cancel();
    await _approvalSub.cancel();
    await _questionSub.cancel();
    return super.close();
  }
}

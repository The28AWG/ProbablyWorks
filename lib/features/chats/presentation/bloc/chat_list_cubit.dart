import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/core/data/chat_draft_store.dart';
import 'package:pw_agent/core/domain/host.dart';

class ChatListState extends Equatable {
  const ChatListState({
    this.chats = const [],
    this.hosts = const [],
    this.runningIds = const {},
    this.waitingIds = const {},
  });

  final List<Chat> chats;
  final List<Host> hosts;

  /// Чаты с идущим ходом агента.
  final Set<String> runningIds;

  /// Чаты, где агент ждёт approve или ответа пользователя.
  final Set<String> waitingIds;

  ChatListState copyWith({
    List<Chat>? chats,
    List<Host>? hosts,
    Set<String>? runningIds,
    Set<String>? waitingIds,
  }) => ChatListState(
    chats: chats ?? this.chats,
    hosts: hosts ?? this.hosts,
    runningIds: runningIds ?? this.runningIds,
    waitingIds: waitingIds ?? this.waitingIds,
  );

  @override
  List<Object?> get props => [chats, hosts, runningIds, waitingIds];
}

/// Хосты, прочитанные при старте: список нового чата и композер получают их в первом кадре.
class StartupHosts {
  const StartupHosts(this.value);

  final List<Host> value;
}

class ChatListCubit extends Cubit<ChatListState> {
  ChatListCubit(this._api, this._drafts, {List<Host> initialHosts = const []})
    : super(ChatListState(hosts: initialHosts)) {
    _chatsSub = _api.watchChats().listen((chats) {
      emit(state.copyWith(chats: chats));
      _refreshActivity();
    }, onError: (Object _) => _clear());
    _hostsSub = _api.watchHosts().listen(
      (hosts) => emit(state.copyWith(hosts: hosts)),
      onError: (Object _) => _clear(),
    );
    // Текстовые дельты приходят на каждый токен: на них активность не меняется, пересчёт не нужен.
    _activitySub = _api.events
        .where(
          (event) =>
              event is AgentTurnStarted ||
              event is AgentTurnFinished ||
              event is AgentRunChanged,
        )
        .listen((_) => _refreshActivity());
    _approvalSub = _api.approvals.listen((_) => _refreshActivity());
    _questionSub = _api.questions.listen((_) => _refreshActivity());
    _statusSub = _api.statusChanges.listen((status) {
      // При потере сервера не показываем устаревший список как живой.
      if (status == AgentStatus.offline && !isClosed) {
        emit(const ChatListState());
      }
    });
    _refreshActivity();
  }

  final AgentApi _api;
  final ChatDraftStore _drafts;
  late final StreamSubscription<List<Chat>> _chatsSub;
  late final StreamSubscription<List<Host>> _hostsSub;
  late final StreamSubscription<AgentEvent> _activitySub;
  late final StreamSubscription<ApprovalRequest> _approvalSub;
  late final StreamSubscription<UserQuestion> _questionSub;
  late final StreamSubscription<AgentStatus> _statusSub;

  void _clear() {
    if (!isClosed) emit(const ChatListState());
  }

  /// Пересчитывает бейджи: идёт ход или ждётся approve/ответ.
  void _refreshActivity() {
    if (isClosed) return;
    final waiting = _api.waitingChatIds;
    final running = _api.runningChatIds;
    if (setEquals(running, state.runningIds) &&
        setEquals(waiting, state.waitingIds)) {
      return;
    }
    emit(state.copyWith(runningIds: running, waitingIds: waiting));
  }

  Future<void> rename(String chatId, String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    await _api.renameChat(chatId, trimmed);
  }

  /// Форк текущего чата. Файлы на Host не копируются и не откатываются.
  Future<Chat?> fork(String chatId, {String? title}) async {
    try {
      return await _api.forkChat(chatId, title: title);
    } on Object {
      return null;
    }
  }

  /// Удаление: сначала останавливаем активный ход, затем чистим БД и файлы логов чата.
  /// Если чат был последним в проекте, проект уходит в архив и живёт там неделю.
  Future<void> delete(String chatId) async {
    await _api.deleteChat(chatId);
    // Черновик живёт на клиенте и не удаляется вместе с серверным чатом.
    _drafts.discard(chatId);
  }

  @override
  Future<void> close() async {
    await _chatsSub.cancel();
    await _hostsSub.cancel();
    await _activitySub.cancel();
    await _approvalSub.cancel();
    await _questionSub.cancel();
    await _statusSub.cancel();
    return super.close();
  }
}

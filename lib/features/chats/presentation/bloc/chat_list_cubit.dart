import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/client_session_api.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/core/data/chat_draft_store.dart';
import 'package:pw_agent/core/domain/host.dart';

class ChatListState extends Equatable {
  const ChatListState({
    this.chats = const [],
    this.hosts = const [],
    this.sessions = const [],
    this.runningIds = const {},
    this.waitingIds = const {},
  });

  final List<Chat> chats;
  final List<Host> hosts;

  /// Клиентские сессии этого экземпляра агента, включая текущую.
  ///
  /// Список приходит с сервера: встроенный агент всегда отдаёт пустой, а
  /// подключённый демон — все окна и устройства, которые ещё живы.
  final List<ClientSessionView> sessions;

  /// Чаты с идущим ходом агента.
  final Set<String> runningIds;

  /// Чаты, где агент ждёт approve или ответа пользователя.
  final Set<String> waitingIds;

  /// Другие онлайн-экраны, у которых открыт [chatId].
  ///
  /// Текущая сессия не считается: значок в строке означает соседа, а не
  /// собственный экран. Сессии без открытого чата сюда не попадают.
  List<ClientSessionView> viewersOf(String chatId) => [
    for (final session in sessions)
      if (!session.current && session.online && session.activeChatId == chatId)
        session,
  ];

  /// Другие онлайн-экраны без текущего. Нужны для общего индикатора в панели.
  List<ClientSessionView> get otherOnlineSessions => [
    for (final session in sessions)
      if (!session.current && session.online) session,
  ];

  ChatListState copyWith({
    List<Chat>? chats,
    List<Host>? hosts,
    List<ClientSessionView>? sessions,
    Set<String>? runningIds,
    Set<String>? waitingIds,
  }) => ChatListState(
    chats: chats ?? this.chats,
    hosts: hosts ?? this.hosts,
    sessions: sessions ?? this.sessions,
    runningIds: runningIds ?? this.runningIds,
    waitingIds: waitingIds ?? this.waitingIds,
  );

  @override
  List<Object?> get props => [chats, hosts, sessions, runningIds, waitingIds];
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
              event is AgentTurnSnapshot ||
              event is AgentRunChanged,
        )
        .listen((_) => _refreshActivity());
    _approvalSub = _api.approvals.listen((_) => _refreshActivity());
    _questionSub = _api.questions.listen((_) => _refreshActivity());
    final Object api = _api;
    final interactions = api is InteractionEventsApi ? api : null;
    _resolutionSub = interactions?.resolutions.listen(
      (_) => _refreshActivity(),
    );
    final presence = api is ClientSessionApi ? api : null;
    _presenceSub = presence?.clientSessions.listen(_onSessions);
    if (presence != null) unawaited(_refreshSessions(presence));
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
  StreamSubscription<InteractionResolution>? _resolutionSub;
  late final StreamSubscription<AgentStatus> _statusSub;
  StreamSubscription<List<ClientSessionView>>? _presenceSub;

  void _clear() {
    if (!isClosed) emit(const ChatListState());
  }

  /// Снимок присутствия пришёл с сервера: обновляем значки в списке чатов
  /// и общий счётчик других экранов. Ошибка начального чтения не критична:
  /// следующее событие присутствия повторит попытку.
  void _onSessions(List<ClientSessionView> sessions) {
    if (!isClosed) emit(state.copyWith(sessions: sessions));
  }

  Future<void> _refreshSessions(ClientSessionApi presence) async {
    try {
      await presence.refreshClientSessions();
    } on Object {
      // Присутствие не мешает работать с чатами.
    }
  }

  /// Убирает зависшее подключение другого экрана по fingerprint.
  ///
  /// Возвращает `false`, если API не умеет управлять сессиями или запрос не
  /// прошёл: диалог покажет ошибку и оставит список открытым.
  Future<bool> disconnectClientSession(String id) async {
    final Object api = _api;
    if (api is! ClientSessionApi) return false;
    try {
      await api.closeClientSession(id);
      return true;
    } on Object {
      return false;
    }
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

  /// Ручное «прочитать всё»: двигает общий курсор до последнего сообщения.
  ///
  /// Список обновится сам: локальный агент пишет в БД, удалённый присылает
  /// `chatReadChanged` и перечитывает снимок.
  Future<Chat> markRead(Chat chat) =>
      _api.markChatRead(chat.id, seq: chat.lastMessageSeq);

  /// Сколько отложенных задач чата ещё не сработало.
  ///
  /// null — прочитать не удалось. Тогда вопрос задать нельзя, и вызывающая
  /// сторона выбирает безопасный вариант сама.
  Future<int?> pendingScheduledTasks(String chatId) async {
    try {
      return await _api.pendingScheduledTasks(chatId);
    } on Object {
      return null;
    }
  }

  /// Форк текущего чата. Файлы на Host не копируются и не откатываются.
  /// [copyPendingTasks] — выбор пользователя, сделанный в диалоге переноса.
  Future<Chat?> fork(
    String chatId, {
    String? title,
    bool copyPendingTasks = false,
  }) async {
    try {
      return await _api.forkChat(
        chatId,
        title: title,
        copyPendingTasks: copyPendingTasks,
      );
    } on Object {
      return null;
    }
  }

  /// Удаление: сначала останавливаем активный ход, затем чистим БД и файлы логов чата.
  /// Если чат был последним в проекте, проект уходит в архив и живёт там неделю.
  ///
  /// Каскад удаляет и скрытых субагентов, поэтому сервер возвращает их id:
  /// черновики живут на клиенте и убираются для всех удалённых чатов.
  Future<void> delete(String chatId) async {
    final deleted = await _api.deleteChat(chatId);
    for (final id in deleted) {
      _drafts.discard(id);
    }
    _drafts.discard(chatId);
  }

  @override
  Future<void> close() async {
    await _chatsSub.cancel();
    await _hostsSub.cancel();
    await _activitySub.cancel();
    await _approvalSub.cancel();
    await _questionSub.cancel();
    await _resolutionSub?.cancel();
    await _statusSub.cancel();
    await _presenceSub?.cancel();
    return super.close();
  }
}

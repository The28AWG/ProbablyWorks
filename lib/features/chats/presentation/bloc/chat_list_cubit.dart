import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/attention_api.dart';
import 'package:pw_agent/agent/api/attention_digest_api.dart';
import 'package:pw_agent/agent/api/chat_api.dart';
import 'package:pw_agent/agent/api/client_session_api.dart';
import 'package:pw_agent/agent/domain/attention_digest.dart';
import 'package:pw_agent/agent/domain/chat_attention.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
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
    this.attention = AttentionSnapshot.empty,
    this.attentionLoading = false,
    this.attentionError,
    this.attentionSupported = true,
    this.digest,
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

  /// Входящие: решения, проблемы хода и непрочитанное.
  final AttentionSnapshot attention;

  /// Входящие читаются впервые. Нужно экрану, чтобы не показывать пустоту
  /// до первого ответа.
  final bool attentionLoading;

  /// Текст ошибки чтения входящих. Список чатов продолжает работать: новый
  /// сервер может не поддерживать маршрут, и это не повод ломать навигацию.
  final String? attentionError;

  /// Поддерживает ли подключённый агент входящие. false — старый сервер без
  /// `GET /attention`; экран показывает пояснение вместо пустого списка.
  final bool attentionSupported;

  /// Дайджест «пока вас не было». Null — сводка ещё не запрошена или сервер
  /// её не поддерживает; пустой объект скрывает карточку.
  final AttentionDigest? digest;

  /// Сколько решений ждёт пользователя. Бейдж навигации считает их, а не
  /// непрочитанные сообщения.
  int get actionableCount => attention.actionableCount;

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
    AttentionSnapshot? attention,
    bool? attentionLoading,
    String? attentionError,
    bool clearAttentionError = false,
    bool? attentionSupported,
    AttentionDigest? digest,
    bool clearDigest = false,
  }) => ChatListState(
    chats: chats ?? this.chats,
    hosts: hosts ?? this.hosts,
    sessions: sessions ?? this.sessions,
    runningIds: runningIds ?? this.runningIds,
    waitingIds: waitingIds ?? this.waitingIds,
    attention: attention ?? this.attention,
    attentionLoading: attentionLoading ?? this.attentionLoading,
    attentionError: clearAttentionError
        ? null
        : (attentionError ?? this.attentionError),
    attentionSupported: attentionSupported ?? this.attentionSupported,
    digest: clearDigest ? null : (digest ?? this.digest),
  );

  @override
  List<Object?> get props => [
    chats,
    hosts,
    sessions,
    runningIds,
    waitingIds,
    attention,
    attentionLoading,
    attentionError,
    attentionSupported,
    digest,
  ];
}

/// Хосты, прочитанные при старте: список нового чата и композер получают их в первом кадре.
class StartupHosts {
  const StartupHosts(this.value);

  final List<Host> value;
}

class ChatListCubit extends Cubit<ChatListState> {
  ChatListCubit(
    this._api,
    this._drafts, {
    List<Host> initialHosts = const [],
    this.chatApi,
  }) : super(ChatListState(hosts: initialHosts)) {
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
    _attentionApi = api is AttentionApi ? api : null;
    _digestApi = api is AttentionDigestApi ? api : null;
    if (_attentionApi == null) {
      emit(state.copyWith(attentionSupported: false));
    }
    _attentionSub = _attentionApi?.attentionChanges.listen(_onAttention);
    // После обрыва SSE часть событий внимания потеряна. Снимок небольшой,
    // поэтому перечитываем его при восстановлении, а не строим replay.
    final reconnect = api is ChatReconnectApi ? api : null;
    _reconnectSub = reconnect?.reconnects.listen((_) {
      // После перезапуска сервера ревизия начинается заново: явное
      // перечитывание должно принять снимок, даже если номер меньше.
      unawaited(refreshAttention(force: true));
    });
    _statusSub = _api.statusChanges.listen((status) {
      // При потере сервера не показываем устаревший список как живой.
      if (status == AgentStatus.offline && !isClosed) {
        emit(ChatListState(attentionSupported: state.attentionSupported));
      } else if (status == AgentStatus.online) {
        unawaited(refreshAttention(force: true));
      }
    });
    _refreshActivity();
    if (_attentionApi != null) unawaited(refreshAttention(force: true));
  }

  final AgentApi _api;
  final ChatDraftStore _drafts;

  /// API чата нужен только для продолжения хода из входящих. Может быть null
  /// в тестовой раскладке, где список чатов собирается без экрана чата.
  final ChatApi? chatApi;
  AttentionApi? _attentionApi;
  AttentionDigestApi? _digestApi;
  Future<void>? _digestInFlight;

  /// Поколение карточки: растёт при каждом скрытии. Ответ на запрос, начатый
  /// до скрытия, не должен вернуть уже убранную карточку.
  var _digestGeneration = 0;

  /// Поколение, для которого сейчас выполняется [_digestInFlight].
  var _digestRequestGeneration = 0;

  /// События входящих пришли, пока запрос дайджеста был в полёте.
  var _digestDirty = false;

  late final StreamSubscription<List<Chat>> _chatsSub;
  late final StreamSubscription<List<Host>> _hostsSub;
  late final StreamSubscription<AgentEvent> _activitySub;
  late final StreamSubscription<ApprovalRequest> _approvalSub;
  late final StreamSubscription<UserQuestion> _questionSub;
  StreamSubscription<InteractionResolution>? _resolutionSub;
  late final StreamSubscription<AgentStatus> _statusSub;
  StreamSubscription<List<ClientSessionView>>? _presenceSub;
  StreamSubscription<AttentionSnapshot>? _attentionSub;
  StreamSubscription<void>? _reconnectSub;

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

  /// Событие входящих с сервера. Более старая ревизия не должна вернуть уже
  /// закрытую карточку, если ответ HTTP пришёл позже SSE.
  void _onAttention(AttentionSnapshot snapshot, {bool force = false}) {
    if (isClosed) return;
    if (!force && snapshot.revision < state.attention.revision) return;
    emit(
      state.copyWith(
        attention: snapshot,
        attentionLoading: false,
        // Снимок пришёл — сервер точно поддерживает входящие. Это важно после
        // обновления демона, которое случилось при открытом приложении.
        attentionSupported: true,
        clearAttentionError: true,
      ),
    );
    // Пока карточка дайджеста видна, её счётчики должны успевать за
    // закрытием карточек и прочтением. Новых запросов без показанной карточки
    // не делаем: сводка нужна только после возврата.
    final digest = state.digest;
    if (digest != null && !digest.isEmpty) unawaited(loadDigest());
  }

  /// Перечитывает входящие. Ошибка остаётся в состоянии, но не трогает
  /// список чатов: на старом сервере новый экран просто покажет пояснение.
  Future<void> refreshAttention({bool force = false}) async {
    final api = _attentionApi;
    if (api == null || isClosed) return;
    if (state.attention.revision == 0) {
      emit(state.copyWith(attentionLoading: true, clearAttentionError: true));
    }
    try {
      final snapshot = await api.attention();
      if (isClosed) return;
      _onAttention(snapshot, force: force);
    } on AgentApiException catch (error) {
      if (isClosed) return;
      // Старый демон не знает маршрут (`404`) или отвечает, что API нет
      // (`501 not_supported`). Это не временный сбой: экран должен показать
      // пояснение вместо кнопки повтора, которая никогда не сработает.
      if (error.status == 404 || error.code == 'not_supported') {
        emit(
          state.copyWith(
            attention: AttentionSnapshot.empty,
            attentionLoading: false,
            attentionSupported: false,
            clearAttentionError: true,
          ),
        );
        return;
      }
      emit(state.copyWith(attentionLoading: false, attentionError: '$error'));
    } on Object catch (error) {
      if (isClosed) return;
      emit(state.copyWith(attentionLoading: false, attentionError: '$error'));
    }
  }

  /// Запрашивает дайджест «пока вас не было».
  ///
  /// Ошибка намеренно не попадает в состояние: дайджест — подсказка, а старый
  /// сервер без маршрута не должен показывать ошибку поверх списка чатов.
  /// События входящих приходят пачками: пока один запрос в полёте, следующий
  /// не нужен — после ответа хватит одного перечитывания.
  Future<void> loadDigest() {
    final api = _digestApi;
    if (api == null || isClosed) return Future<void>.value();
    final inFlight = _digestInFlight;
    if (inFlight != null && _digestRequestGeneration == _digestGeneration) {
      _digestDirty = true;
      return inFlight;
    }
    final generation = _digestGeneration;
    _digestRequestGeneration = generation;
    _digestDirty = false;
    final future = _loadDigest(api, generation);
    _digestInFlight = future;
    return future.whenComplete(() {
      if (identical(_digestInFlight, future)) _digestInFlight = null;
      if (_digestDirty && !isClosed && generation == _digestGeneration) {
        unawaited(loadDigest());
      }
    });
  }

  Future<void> _loadDigest(AttentionDigestApi api, int generation) async {
    try {
      final digest = await api.attentionDigest();
      // Пока шёл запрос, карточку могли убрать: такой ответ уже не нужен.
      if (isClosed || generation != _digestGeneration) return;
      emit(state.copyWith(digest: digest));
    } on Object {
      // Дайджест необязателен: список чатов и входящие продолжают работать.
    }
  }

  /// Скрывает карточку дайджеста до следующего возврата.
  ///
  /// Ответ на запрос, начатый до скрытия, не должен вернуть карточку: для
  /// этого растёт поколение.
  void dismissDigest() {
    if (isClosed || state.digest == null) return;
    _digestGeneration++;
    _digestDirty = false;
    emit(state.copyWith(clearDigest: true));
  }

  /// Подтверждение карточки прямо из входящих. Сервер проверяет, что она
  /// ещё актуальна: закрытая в другом окне карточка не выполнится повторно.
  Future<bool> approve(String requestId) => _attentionAction(
    () => _api.resolveApproval(requestId, ApprovalAction.allowOnce),
  );

  Future<bool> deny(String requestId, {String? reason}) => _attentionAction(
    () => _api.resolveApproval(requestId, ApprovalAction.deny, reason: reason),
  );

  Future<bool> answer(String questionId, String? text) =>
      _attentionAction(() => _api.answerQuestion(questionId, text));

  Future<bool> resolveEditChanges(
    String requestId,
    EditFileChangesChoice choice,
  ) => _attentionAction(() => _api.resolveEditFileChanges(requestId, choice));

  /// Продолжает ход после лимита шагов, бюджета или застоя.
  Future<bool> continueTurn(String chatId) {
    final api = chatApi;
    if (api == null) return Future.value(false);
    return _attentionAction(api.session(chatId).continueAfterStepLimit);
  }

  Future<bool> dismissAttention(String chatId) {
    final api = _attentionApi;
    if (api == null) return Future.value(false);
    return _attentionAction(() => api.dismissAttention(chatId));
  }

  /// Выполняет действие из входящих и оставляет ошибку в состоянии.
  ///
  /// Возвращает `false`, если действие не прошло: экран не должен очищать
  /// введённый текст или делать вид, что карточка закрыта.
  Future<bool> _attentionAction(Future<void> Function() action) async {
    try {
      await action();
      return true;
    } on Object catch (error) {
      if (!isClosed) {
        emit(state.copyWith(attentionError: '$error'));
      }
      return false;
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

  /// Отмечает прочитанным чат из входящих. Снимок входящих обновится по
  /// событию курсора: отдельно перечитывать список не нужно.
  ///
  /// Ошибка возвращается через [ChatListState.attentionError], как у остальных
  /// действий из входящих: экран не должен терять её в необработанном future.
  Future<bool> markAttentionRead(ChatAttention item) =>
      _attentionAction(() async {
        await _api.markChatRead(item.chatId, seq: item.lastMessageSeq);
      });

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
    await _attentionSub?.cancel();
    await _reconnectSub?.cancel();
    return super.close();
  }
}

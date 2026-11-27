import 'dart:async';

import 'package:logging/logging.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/domain/attention_digest.dart';
import 'package:pw_agent/agent/domain/chat_attention.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/chat_snooze.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/core/data/chat_repository.dart';
import 'package:pw_agent/core/notify/app_notifier.dart';

/// Единый агрегат «что требует внимания пользователя».
///
/// Сводка собирается из трёх источников, которые уже существуют: снимок
/// списка чатов с курсором прочтения, карточки [InteractionBroker] и
/// состояние ходов. Собственной таблицы «входящих» нет — иначе список,
/// бейджи и уведомления расходились бы при каждом новом пути изменения.
///
/// Проблемное завершение хода хранится в базе, потому что оно должно
/// переживать перезапуск. Обычное завершение во «входящие» не попадает:
/// о нём говорит непрочитанное сообщение.
///
/// Сервис же владеет отложенными напоминаниями: чат со сроком в будущем не
/// попадает в сводку, а по наступлении срока возвращается и напоминает о себе.
/// Поэтому snooze живёт на агенте, а не в настройках окна: срок должен быть
/// один на все устройства.
final class ChatAttentionService {
  ChatAttentionService(
    this._chats,
    this._broker, {
    this.notifier,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _chatsSub = _chats.watchChats().listen((chats) {
      _chatsSnapshot = chats;
      _recompute();
    }, onError: _logSubscriptionError);
    _statesSub = _chats.watchAttentionStates().listen((states) {
      _statesSnapshot = states;
      // Поток уже отдаёт записанное состояние: локальная поправка после хода
      // больше не нужна и не должна пережить следующий снимок базы.
      _finishedTurns.clear();
      _recompute();
    }, onError: _logSubscriptionError);
    _snoozesSub = _chats.watchAttentionSnoozes().listen((snoozes) {
      _snoozesSnapshot = snoozes;
      _recompute();
    }, onError: _logSubscriptionError);
    _approvalSub = _broker.approvalRequests.listen((_) => _recompute());
    _questionSub = _broker.questions.listen((_) => _recompute());
    _editFilesSub = _broker.editFileChangesRequests.listen((_) => _recompute());
    _resolutionSub = _broker.resolutions.listen((_) => _recompute());
  }

  final ChatRepository _chats;
  final InteractionBroker _broker;

  /// Уведомление о наступившем напоминании. Может быть null в узких тестах,
  /// где сервис строится без настройки уведомлений.
  final AppNotifier? notifier;

  /// Текущее время. Подменяется в тестах: срок напоминания иначе пришлось бы
  /// ждать настоящими часами.
  final DateTime Function() _now;
  final _log = Logger('ChatAttentionService');
  final _changes = StreamController<AttentionSnapshot>.broadcast();
  final _due = StreamController<String>.broadcast();

  late final StreamSubscription<List<Chat>> _chatsSub;
  late final StreamSubscription<List<ChatAttentionRecord>> _statesSub;
  late final StreamSubscription<List<ChatSnooze>> _snoozesSub;
  late final StreamSubscription<ApprovalRequest> _approvalSub;
  late final StreamSubscription<UserQuestion> _questionSub;
  late final StreamSubscription<EditFileChangesRequest> _editFilesSub;
  late final StreamSubscription<InteractionResolution> _resolutionSub;

  /// Чаты и сохранённые состояния приходят разными потоками. Пока не пришёл
  /// хотя бы один, сводка не строится: пустой снимок выглядел бы как «ничего
  /// не требует внимания» и мигал бы при каждом запуске.
  List<Chat>? _chatsSnapshot;
  List<ChatAttentionRecord>? _statesSnapshot;
  List<ChatSnooze>? _snoozesSnapshot;

  /// Таймер ближайшего срока. Один на сервис: входящих мало, а будить окна
  /// нужно только когда срок действительно наступил.
  Timer? _snoozeTimer;

  /// Итог только что записанного хода, пока поток базы не прислал строку.
  ///
  /// Между записью в базу и обновлением [watchAttentionStates] снимок иначе
  /// успевал бы показать старую проблему: `_running` уже снят, а кэш строк
  /// ещё прежний. Значение `null` означает, что проблема снята.
  final Map<String, ChatAttentionRecord?> _finishedTurns = {};

  final Set<String> _running = {};
  List<ChatAttention> _items = const [];
  List<ChatSnooze> _snoozed = const [];
  var _revision = 0;
  var _disposed = false;

  AttentionSnapshot get snapshot =>
      AttentionSnapshot(revision: _revision, items: _items, snoozed: _snoozed);

  /// Материализует ленивый сервис: подписки и таймер сроков начинают работать
  /// до первого запроса входящих.
  ///
  /// Без этого демон без подключённых окон не узнал бы о сроке, который истёк,
  /// пока приложение было выключено, и напоминание не ушло бы вовсе.
  AttentionSnapshot start() => snapshot;

  /// Новый снимок при любом значимом изменении. Поток широковещательный:
  /// окно и SSE-подписчики получают одно и то же состояние.
  Stream<AttentionSnapshot> get changes => _changes.stream;

  /// Сроки напоминаний, которые только что наступили.
  ///
  /// Снимок входящих уже вернул чат, но отдельное событие объясняет, почему он
  /// здесь снова, и позволяет показать системное напоминание. Чат, у которого
  /// к моменту срока нечего решать, не попадает в поток: напоминать не о чем.
  Stream<String> get due => _due.stream;

  /// Отложен ли чат прямо сейчас.
  ///
  /// Используется уведомлениями: пока действует срок, чат намеренно молчит.
  bool isSnoozed(String chatId) => _activeSnooze(chatId, _now()) != null;

  /// Откладывает чат до [until]. Повторный вызов сдвигает срок.
  ///
  /// Срок в прошлом — ошибка, а не мгновенное срабатывание: иначе опечатка в
  /// клиенте превращалась бы в «напоминание, которое уже прошло».
  Future<void> snooze(String chatId, DateTime until) async {
    if (!until.isAfter(_now())) {
      throw const AgentApiException(
        400,
        'snooze_in_past',
        'snooze deadline must be in the future',
      );
    }
    if (await _chats.chat(chatId) == null) {
      throw AgentApiException(404, 'chat_not_found', 'chat $chatId not found');
    }
    await _chats.snoozeAttention(chatId, until);
    // Уже показанные уведомления этого чата больше не должны звать к нему:
    // срок заменил их одним напоминанием.
    await _cancelChatNotices(chatId);
  }

  /// Снимает напоминание: чат сразу возвращается во входящие.
  Future<void> unsnooze(String chatId) => _chats.clearAttentionSnooze(chatId);

  /// Ход начался: старая проблема больше не показывается, пока идёт работа.
  ///
  /// Запись в базе не удаляем здесь: очистка асинхронна, а быстрый ход мог бы
  /// завершиться раньше и записать новую проблему, которую затем стёрла бы
  /// запоздавшая очистка. Итог хода решает [turnFinished].
  void turnStarted(String chatId) {
    _running.add(chatId);
    _recompute();
  }

  /// Ход закончился. Проблемный конец запоминаем до следующего хода, обычный
  /// снимает прошлую проблему и оставляет только непрочитанное сообщение.
  Future<void> turnFinished(String chatId, TurnEnd end) async {
    final turn = _turnOf(end);
    final occurredAt = DateTime.now();
    try {
      if (turn == null) {
        await _chats.clearAttention(chatId);
      } else {
        await _chats.recordAttention(chatId, turn, occurredAt: occurredAt);
      }
      // Строка уже записана. До следующего события потока снимок строим по
      // этому итогу, чтобы не показать старую проблему.
      _finishedTurns[chatId] = turn == null
          ? null
          : ChatAttentionRecord(
              chatId: chatId,
              turn: turn,
              occurredAt: occurredAt,
              // Ревизия строки нужна только базе; на снимок она не влияет.
              revision: 0,
            );
    } on Object catch (error, stack) {
      _log.warning('failed to update attention for $chatId', error, stack);
    } finally {
      _running.remove(chatId);
      _recompute();
    }
  }

  /// Пользователь разобрал проблему, не начиная новый ход.
  Future<void> dismiss(String chatId) => _chats.clearAttention(chatId);

  /// Дайджест «пока вас не было» по общему read-курсору.
  ///
  /// Сводка строится из тех же чатов, карточек и проблем, что и входящие, а
  /// завершённые ходы считает репозиторий: в снимке входящих их нет, потому
  /// что обычное завершение не является поводом для решения. Если потоки
  /// базы ещё не успели прислать первый снимок (например, дайджест
  /// запрашивают сразу после запуска), читаем их первое значение.
  ///
  /// Отложенные чаты в сводку не входят: пользователь попросил не напоминать
  /// до срока. Когда срок наступит, чат вернётся сюда при следующем запросе.
  Future<AttentionDigest> digest() async {
    final chats = _chatsSnapshot ?? await _chats.watchChats().first;
    final states = _statesSnapshot ?? await _chats.watchAttentionStates().first;
    final snoozes =
        _snoozesSnapshot ?? await _chats.watchAttentionSnoozes().first;
    final items = _buildItems(chats, states, snoozes);
    final turns = await _chats.unreadFinishedTurns();
    return AttentionDigest(
      items: [
        for (final item in items)
          AttentionDigestItem(
            chatId: item.chatId,
            hostId: item.hostId,
            projectId: item.projectId,
            title: item.title,
            unreadMessages: item.unreadCount,
            finishedTurns: turns[item.chatId] ?? 0,
            approvals: item.approvals.length,
            questions: item.questions.length,
            editFileChanges: item.editFileChanges.length,
            problems: item.hasProblem ? 1 : 0,
          ),
      ],
    );
  }

  /// Собирает снимок заново. Дешёвая операция: чатов в списке немного, а
  /// карточки уже лежат в брокере.
  void _recompute() {
    final chats = _chatsSnapshot;
    final states = _statesSnapshot;
    final snoozes = _snoozesSnapshot;
    if (chats == null || states == null || snoozes == null || _disposed) {
      return;
    }

    final now = _now();
    final items = _buildItems(chats, states, snoozes);
    final activeSnoozes = [
      for (final snooze in snoozes)
        if (snooze.isActiveAt(now)) snooze,
    ];
    _scheduleSnoozeTimer(activeSnoozes, now);
    if (activeSnoozes.length < snoozes.length) {
      // Срок мог пройти, пока приложение было выключено: таймера ещё не было,
      // и строки остались в базе. Убираем их и напоминаем о чатах, как будто
      // срок только что наступил.
      unawaited(_expireSnoozes());
    }
    if (_sameItems(_items, items) && _sameSnoozes(_snoozed, activeSnoozes)) {
      return;
    }
    _items = List.unmodifiable(items);
    _snoozed = List.unmodifiable(activeSnoozes);
    _revision++;
    if (!_changes.isClosed) {
      _changes.add(
        AttentionSnapshot(
          revision: _revision,
          items: _items,
          snoozed: _snoozed,
        ),
      );
    }
  }

  /// Ставит таймер на ближайший срок и снимает предыдущий.
  ///
  /// Таймер один: при изменении списка сроков проще пересоздать его, чем
  /// держать много таймеров, которые надо не забыть отменить.
  void _scheduleSnoozeTimer(List<ChatSnooze> snoozes, DateTime now) {
    _snoozeTimer?.cancel();
    _snoozeTimer = null;
    if (snoozes.isEmpty || _disposed) return;
    var next = snoozes.first.until;
    for (final snooze in snoozes.skip(1)) {
      if (snooze.until.isBefore(next)) next = snooze.until;
    }
    final delay = next.difference(now);
    _snoozeTimer = Timer(
      delay.isNegative ? Duration.zero : delay,
      () => unawaited(_expireSnoozes()),
    );
  }

  /// Срок наступил: убирает просроченные записи, возвращает чаты во входящие
  /// и напоминает о тех, где есть что решать.
  Future<void> _expireSnoozes() async {
    _snoozeTimer = null;
    if (_disposed) return;
    final List<String> expired;
    try {
      expired = await _chats.clearExpiredAttentionSnoozes(_now());
    } on Object catch (error, stack) {
      _log.warning('failed to clear expired snoozes', error, stack);
      // Таймер уже снят: пересчёт поступит следующим снимком базы.
      return;
    }
    if (_disposed || expired.isEmpty) return;
    // Не ждём поток базы: снимок должен вернуть чат сразу, иначе окно
    // продолжит показывать его отложенным ещё несколько кадров.
    final current = _snoozesSnapshot;
    if (current != null) {
      _snoozesSnapshot = [
        for (final snooze in current)
          if (!expired.contains(snooze.chatId)) snooze,
      ];
    }
    _recompute();
    for (final chatId in expired) {
      // Чат мог разобраться, пока был отложен: напоминать не о чем.
      if (!_items.any((item) => item.chatId == chatId)) continue;
      if (!_due.isClosed) _due.add(chatId);
      unawaited(_notifyDue(chatId));
    }
  }

  /// Системное напоминание о вернувшемся чате.
  ///
  /// Идёт через общий notifier агента: у демона это push-relay, у встроенного
  /// агента — системные уведомления окна. Ошибка доставки не должна ломать
  /// возвращение чата во входящие.
  Future<void> _notifyDue(String chatId) async {
    final sink = notifier;
    if (sink == null) return;
    try {
      final chat = await _chats.chat(chatId);
      if (chat == null) return;
      await sink.notify(
        kind: AgentNoticeKind.snoozeDue,
        chatTitle: chat.title,
        chatId: chatId,
        noticeId: agentNoticeId(
          kind: AgentNoticeKind.snoozeDue,
          chatId: chatId,
        ),
      );
    } on Object catch (error, stack) {
      _log.warning('snooze reminder failed for $chatId', error, stack);
    }
  }

  /// Убирает уведомления чата, показанные до его откладывания.
  ///
  /// Список типов тот же, что у `ChatSession`: карточки и события хода, плюс
  /// напоминание о наступившем сроке. Ошибка отмены не мешает сроку —
  /// уведомление просто останется до следующего действия с карточкой.
  Future<void> _cancelChatNotices(String chatId) async {
    final sink = notifier;
    if (sink == null) return;
    final ids = <String>[
      for (final request in _broker.allPendingApprovals)
        if (request.chatId == chatId)
          agentNoticeId(
            kind: AgentNoticeKind.approvalNeeded,
            chatId: chatId,
            approvalId: request.id,
          ),
      for (final question in _broker.allPendingQuestions)
        if (question.chatId == chatId)
          agentNoticeId(
            kind: AgentNoticeKind.questionAsked,
            chatId: chatId,
            questionId: question.id,
          ),
      for (final kind in const [
        AgentNoticeKind.turnFinished,
        AgentNoticeKind.turnFailed,
        AgentNoticeKind.stepLimitReached,
        AgentNoticeKind.turnBudgetReached,
        AgentNoticeKind.progressStalled,
        // Старое напоминание о наступившем сроке больше неактуально: чат
        // снова отложен, а срок заменил его.
        AgentNoticeKind.snoozeDue,
      ])
        agentNoticeId(kind: kind, chatId: chatId),
    ];
    for (final id in ids) {
      try {
        await sink.cancel(id);
      } on Object catch (error, stack) {
        _log.fine('notice cancel failed for $id', error, stack);
      }
    }
  }

  /// Действующее напоминание о чате в момент [now].
  ChatSnooze? _activeSnooze(String chatId, DateTime now) {
    final snoozes = _snoozesSnapshot;
    if (snoozes == null) return null;
    for (final snooze in snoozes) {
      if (snooze.chatId == chatId && snooze.isActiveAt(now)) return snooze;
    }
    return null;
  }

  /// Строит отсортированный список чатов, которые требуют внимания.
  List<ChatAttention> _buildItems(
    List<Chat> chats,
    List<ChatAttentionRecord> states,
    List<ChatSnooze> snoozes,
  ) {
    final approvals = <String, List<ApprovalRequest>>{};
    for (final request in _broker.allPendingApprovals) {
      approvals.putIfAbsent(request.chatId, () => []).add(request);
    }
    final questions = <String, List<UserQuestion>>{};
    for (final question in _broker.allPendingQuestions) {
      questions.putIfAbsent(question.chatId, () => []).add(question);
    }
    final edits = <String, List<EditFileChangesRequest>>{};
    for (final request in _broker.allPendingEditFileChanges) {
      edits.putIfAbsent(request.chatId, () => []).add(request);
    }
    final records = {for (final record in states) record.chatId: record};
    final now = _now();
    final active = <String, ChatSnooze>{};
    for (final snooze in snoozes) {
      if (snooze.isActiveAt(now)) active[snooze.chatId] = snooze;
    }

    final items = <ChatAttention>[];
    for (final chat in chats) {
      if (chat.kind == ChatKind.subagent) continue;
      // Отложенный чат остаётся в списке и открывается как обычно, но не
      // требует внимания до срока — иначе «напомнить позже» ничего не меняет.
      if (active.containsKey(chat.id)) continue;
      final chatApprovals = approvals[chat.id] ?? const <ApprovalRequest>[];
      final chatQuestions = questions[chat.id] ?? const <UserQuestion>[];
      final chatEdits = edits[chat.id] ?? const <EditFileChangesRequest>[];
      final running = _running.contains(chat.id);
      // Пока идёт новый ход, старая проблема уже не ждёт решения. Итог
      // текущего хода заменит её или снимет. Пока поток базы не прислал
      // строку, берём локальный итог только что завершённого хода.
      final record = running
          ? null
          : _finishedTurns.containsKey(chat.id)
          ? _finishedTurns[chat.id]
          : records[chat.id];
      final reasons = <ChatAttentionReason>{
        if (chatApprovals.isNotEmpty) ChatAttentionReason.approval,
        if (chatQuestions.isNotEmpty) ChatAttentionReason.question,
        if (chatEdits.isNotEmpty) ChatAttentionReason.editFiles,
        if (record != null) record.turn.reason,
        if (chat.unreadCount > 0) ChatAttentionReason.unread,
      };
      if (reasons.isEmpty) continue;
      items.add(
        ChatAttention(
          chatId: chat.id,
          hostId: chat.hostId,
          projectId: chat.projectId,
          title: chat.title,
          reasons: reasons,
          approvals: List.unmodifiable(chatApprovals),
          questions: List.unmodifiable(chatQuestions),
          editFileChanges: List.unmodifiable(chatEdits),
          unreadCount: chat.unreadCount,
          lastReadSeq: chat.lastReadSeq,
          lastMessageSeq: chat.lastMessageSeq,
          running: running,
          turnAt: record?.occurredAt,
          updatedAt: chat.updatedAt,
        ),
      );
    }
    // Срочность важнее времени: решение по карточке не должно уезжать вниз
    // из-за того, что в другом чате только что пришло новое сообщение.
    items.sort((a, b) {
      final byPriority = a.priority.compareTo(b.priority);
      if (byPriority != 0) return byPriority;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return items;
  }

  static ChatAttentionTurn? _turnOf(TurnEnd end) => switch (end) {
    TurnEnd.failed => ChatAttentionTurn.failed,
    TurnEnd.stepLimit => ChatAttentionTurn.stepLimit,
    TurnEnd.budget => ChatAttentionTurn.budget,
    TurnEnd.stalled => ChatAttentionTurn.stalled,
    TurnEnd.completed || TurnEnd.stopped => null,
  };

  static bool _sameItems(List<ChatAttention> a, List<ChatAttention> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (_signature(a[i]) != _signature(b[i])) return false;
    }
    return true;
  }

  /// Сроки сравниваются по значению: порядок строк из базы стабилен, но
  /// полагаться на него не нужно.
  static bool _sameSnoozes(List<ChatSnooze> a, List<ChatSnooze> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].chatId != b[i].chatId ||
          a[i].until != b[i].until ||
          a[i].revision != b[i].revision) {
        return false;
      }
    }
    return true;
  }

  /// Сравнивает значимые поля, а не объекты: `Set` причин и списки карточек
  /// каждый раз новые, поэтому обычное равенство всегда давало бы «изменение»
  /// и рассылало бы снимок на каждое сохранение черновика.
  static String _signature(ChatAttention item) => [
    item.chatId,
    item.hostId,
    item.projectId ?? '',
    item.title,
    item.running,
    item.unreadCount,
    item.lastReadSeq,
    item.lastMessageSeq,
    item.turnAt?.toUtc().toIso8601String() ?? '',
    item.updatedAt.toUtc().toIso8601String(),
    (item.reasons.map((reason) => reason.name).toList()..sort()).join(','),
    item.approvals.map((approval) => approval.id).join(','),
    item.questions.map((question) => question.id).join(','),
    item.editFileChanges.map((request) => request.id).join(','),
  ].join('\u001f');

  void _logSubscriptionError(Object error, StackTrace stack) {
    _log.warning('attention source failed', error, stack);
  }

  Future<void> dispose() async {
    _disposed = true;
    _snoozeTimer?.cancel();
    _snoozeTimer = null;
    await _chatsSub.cancel();
    await _statesSub.cancel();
    await _snoozesSub.cancel();
    await _approvalSub.cancel();
    await _questionSub.cancel();
    await _editFilesSub.cancel();
    await _resolutionSub.cancel();
    await _changes.close();
    await _due.close();
  }
}

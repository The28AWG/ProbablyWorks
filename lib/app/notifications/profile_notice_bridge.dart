import 'dart:async';

import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/attention_api.dart';
import 'package:pw_agent/agent/api/attention_pause_api.dart';
import 'package:pw_agent/agent/api/attention_snooze_api.dart';
import 'package:pw_agent/agent/api/chat_api.dart';
import 'package:pw_agent/agent/domain/attention_digest.dart';
import 'package:pw_agent/agent/domain/chat_attention.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/core/logging/app_log.dart';
import 'package:pw_agent/core/notify/app_notifier.dart';

/// Проверяет, видит ли пользователь чат на другом активном экране.
///
/// Возвращает true, если чат открыт в сессии с фокусом: тогда системное
/// уведомление на этом устройстве только отвлечёт пользователя. Ошибку
/// проверки вызывающий код трактует как «не видит»: лучше лишнее уведомление,
/// чем пропущенный запрос подтверждения.
typedef ChatVisibleProbe = Future<bool> Function(String chatId);

/// Проверяет, отложен ли чат на сервере.
///
/// Пока действует срок «напомнить позже», уведомления о чате молчат: срок —
/// это и есть просьба не напоминать. Ошибку проверки вызывающий код трактует
/// как «не отложен»: пропустить запрос подтверждения хуже, чем показать
/// уведомление о чате, который сейчас отложен.
typedef ChatSnoozedProbe = Future<bool> Function(String chatId);

/// Проверяет, выключены ли уведомления общей паузой прямо сейчас.
///
/// Ошибку проверки вызывающий код трактует как «не на паузе»: лучше лишнее
/// уведомление, чем пропущенный запрос подтверждения.
typedef NotificationsPausedProbe = Future<bool> Function();

/// Проверяет, должно ли текущее устройство показывать уведомление.
///
/// Сервер выбирает одно активное устройство, чтобы событие не всплыло сразу на
/// всех экранах. Ошибку проверки вызывающий код трактует как «показывать»:
/// пропустить запрос подтверждения хуже, чем показать лишнее уведомление.
typedef NotificationTargetProbe = Future<bool> Function();

/// Переводит события удалённого агента в системные уведомления профиля.
///
/// Сервер не умеет показывать системные уведомления GUI, поэтому клиент
/// повторяет их по SSE и потокам карточек. Уведомления строятся по устойчивому
/// id из [agentNoticeId]: повторный показ обновляет запись в трее, а событие
/// закрытия карточки её отменяет. После обрыва связи карточки, закрытые без
/// события, находятся сверкой с сервером. Перед показом проверяется presence:
/// если чат уже открыт в активной сессии на другом устройстве, уведомление
/// не нужно.
///
/// [listen] возвращает подписки, чтобы владелец профиля мог снять их вместе с
/// SSE-соединением. Повторных подписок на те же потоки класс не создаёт:
/// подписка живёт столько же, сколько API профиля.
///
/// Уведомления отложенного чата не показываются и снимаются при откладывании,
/// а наступивший срок приходит отдельным событием `attentionDue`.
///
/// Карточка, скрытая из-за того, что чат уже виден на другом активном
/// устройстве или внимание сейчас на нём, не теряется: при следующем изменении
/// присутствия мост проверяет её снова. Так подтверждение, пришедшее, пока
/// пользователь был у компьютера, появляется на телефоне, как только он его
/// взял, — без таймеров и без дубля на обоих экранах.
final class ProfileNoticeBridge {
  ProfileNoticeBridge({
    required this.api,
    required this.notifier,
    required this.profileId,
    this.isVisible,
    this.isSnoozed,
    this.isPaused,
    this.isNotificationTarget,
    this.presenceChanges,
  });

  final AgentApi api;
  final AppNotifier notifier;
  final String profileId;
  final ChatVisibleProbe? isVisible;
  final ChatSnoozedProbe? isSnoozed;
  final NotificationsPausedProbe? isPaused;
  final NotificationTargetProbe? isNotificationTarget;

  /// Изменения присутствия: повод пересмотреть отложенные карточки.
  ///
  /// Значение события не важно; мост ждёт сам факт изменения снимка.
  final Stream<Object?>? presenceChanges;

  /// Карточки, для которых уведомление показано или ещё показывается.
  ///
  /// Показ асинхронный: он ждёт проверку presence и название чата. За это время
  /// карточку могут закрыть в другом окне. Без такой карты `notify` успел бы
  /// показать уже отменённое уведомление после `cancel`. Она же нужна, чтобы
  /// после обрыва связи сверить уведомления с карточками на сервере.
  final _cards = <String, _CardNotice>{};

  /// Карточки, скрытые из-за видимости чата на другом устройстве или потому,
  /// что внимание сейчас не здесь.
  ///
  /// Это не потерянные уведомления, а очередь на эскалацию: когда присутствие
  /// меняется и внимание переходит на этот экран, карточка показывается. Так
  /// approval не дублируется на обоих устройствах и не пропадает, если
  /// пользователь взял телефон.
  final _deferred = <String, _CardNotice>{};

  /// Идёт проверка отложенных карточек: параллельные события присутствия не
  /// должны запускать несколько одинаковых запросов и показов.
  var _evaluatingDeferred = false;

  /// Событие присутствия пришло во время проверки. После текущего прохода
  /// очередь пересматривается ещё раз, иначе свежая смена внимания потеряется
  /// до следующего изменения.
  var _deferredRecheck = false;

  /// Чаты, отложенные по последнему снимку входящих. Хранится, чтобы
  /// заметить именно новое откладывание и снять уведомления его карточек.
  final _snoozedChats = <String>{};

  /// Действует ли общая пауза по последнему снимку. Уведомления, пришедшие
  /// до первого снимка, проверяет [isPaused].
  var _paused = false;

  /// Подписывает уведомления на события этого профиля.
  List<StreamSubscription<Object?>> listen() {
    final subscriptions = <StreamSubscription<Object?>>[
      api.events.listen(_onEvent),
      api.approvals.listen((request) {
        final noticeId = agentNoticeId(
          kind: AgentNoticeKind.approvalNeeded,
          scope: profileId,
          approvalId: request.id,
        );
        _cards[noticeId] = _CardNotice(
          chatId: request.chatId,
          kind: AgentNoticeKind.approvalNeeded,
          cardId: request.id,
        );
        unawaited(
          _notify(
            request.chatId,
            AgentNoticeKind.approvalNeeded,
            noticeId: noticeId,
            approvalId: request.id,
          ),
        );
      }),
      api.questions.listen((question) {
        final noticeId = agentNoticeId(
          kind: AgentNoticeKind.questionAsked,
          scope: profileId,
          questionId: question.id,
        );
        _cards[noticeId] = _CardNotice(
          chatId: question.chatId,
          kind: AgentNoticeKind.questionAsked,
          cardId: question.id,
        );
        unawaited(
          _notify(
            question.chatId,
            AgentNoticeKind.questionAsked,
            noticeId: noticeId,
            questionId: question.id,
          ),
        );
      }),
    ];
    final Object source = api;
    if (source case final InteractionEventsApi interactions) {
      subscriptions.add(interactions.resolutions.listen(_onResolution));
    }
    if (source case final AttentionApi attention) {
      subscriptions.add(attention.attentionChanges.listen(_onAttention));
    }
    if (source case final AttentionPauseApi pause) {
      // Пауза закончилась: одно уведомление вместо накопившихся карточек.
      subscriptions.add(pause.pauseDigestDue.listen(_onPauseDigest));
    }
    if (source case final AttentionSnoozeApi snooze) {
      // Наступил срок «напомнить позже»: сервер уже вернул чат во входящие, а
      // уведомление объясняет, почему и о чём напомнить.
      subscriptions.add(
        snooze.attentionDue.listen(
          (chatId) => unawaited(
            _notify(
              chatId,
              AgentNoticeKind.snoozeDue,
              noticeId: _dueNoticeId(chatId),
            ),
          ),
        ),
      );
    }
    // Событие закрытия могло потеряться в обрыве связи: после восстановления
    // сверяем показанные уведомления с карточками на сервере.
    if (source case final ChatReconnectApi reconnect) {
      subscriptions.add(
        reconnect.reconnects.listen((_) => unawaited(_reconcileCards())),
      );
    }
    final presence = presenceChanges;
    if (presence != null) {
      subscriptions.add(
        presence.listen((_) => unawaited(_showDeferredIfTarget())),
      );
    }
    return subscriptions;
  }

  /// Чат отложили на любом устройстве — уведомления его карточек в трее
  /// больше неактуальны: решение всё равно можно принять, но срок напомнит о
  /// нём позже. Снимаем только уведомления, которые появились до откладывания.
  void _onAttention(AttentionSnapshot snapshot) {
    final paused = snapshot.notificationsPaused;
    if (paused && !_paused) {
      // Паузу включили на другом устройстве: уже показанные карточки и
      // дайджест прошлой паузы больше не должны отвлекать. Записи в _cards
      // оставляем, чтобы отследить закрытие карточек и не показать их повторно.
      _cancelShownCards();
      _cancelPauseDigest();
    }
    _paused = paused;
    final snoozed = {for (final item in snapshot.snoozed) item.chatId};
    for (final chatId in snoozed.difference(_snoozedChats)) {
      _cancelChatCards(chatId);
      // Старое напоминание о наступившем сроке тоже больше неактуально:
      // пользователь снова попросил не напоминать до нового срока.
      _cancelSnoozeDue(chatId);
    }
    _snoozedChats
      ..clear()
      ..addAll(snoozed);
  }

  /// Пауза закончилась: показываем одну сводку.
  ///
  /// Событие приходит уже после снятия паузы, поэтому отдельная проверка не
  /// нужна. Пустой дайджест сервер не присылает; повторный показ с тем же
  /// [agentNoticeId] обновит строку в трее, а не добавит вторую.
  Future<void> _onPauseDigest(AttentionDigest digest) async {
    if (digest.isEmpty) return;
    try {
      await notifier.notify(
        kind: AgentNoticeKind.attentionDigest,
        chatTitle: '',
        profileId: profileId,
        noticeId: agentNoticeId(
          kind: AgentNoticeKind.attentionDigest,
          scope: profileId,
        ),
      );
    } on Object catch (error) {
      AppLog.root.warning('pause digest notice failed', error);
    }
  }

  /// Снимает показанные уведомления карточек, не забывая их сами.
  void _cancelShownCards() {
    for (final noticeId in _cards.keys) {
      unawaited(_cancel(noticeId));
    }
  }

  /// Убирает дайджест прошлой паузы: новая пауза начинается заново.
  void _cancelPauseDigest() {
    unawaited(
      _cancel(
        agentNoticeId(kind: AgentNoticeKind.attentionDigest, scope: profileId),
      ),
    );
  }

  /// Устойчивый ключ напоминания: одно на чат, поэтому повторное срабатывание
  /// обновляет уведомление, а не копит строки в трее.
  String _dueNoticeId(String chatId) => agentNoticeId(
    kind: AgentNoticeKind.snoozeDue,
    scope: profileId,
    chatId: chatId,
  );

  void _onEvent(AgentEvent event) {
    if (event is AgentChatDeleted) {
      // Вместе с чатом исчезают и его карточки: отдельного события закрытия
      // для каждой может не прийти.
      _cancelChatCards(event.chatId);
      _cancelSnoozeDue(event.chatId);
      return;
    }
    final kind = switch (event) {
      AgentTurnFinished(end: TurnEnd.completed) => AgentNoticeKind.turnFinished,
      AgentTurnFinished(end: TurnEnd.stepLimit) =>
        AgentNoticeKind.stepLimitReached,
      AgentTurnFinished(end: TurnEnd.budget) =>
        AgentNoticeKind.turnBudgetReached,
      AgentTurnFinished(end: TurnEnd.stalled) =>
        AgentNoticeKind.progressStalled,
      AgentTurnFinished(end: TurnEnd.failed) => AgentNoticeKind.turnFailed,
      _ => null,
    };
    if (kind != null) unawaited(_notify(event.chatId, kind));
  }

  /// Убирает уведомления всех карточек удалённого чата.
  void _cancelChatCards(String chatId) {
    final noticeIds = {
      for (final entry in _cards.entries)
        if (entry.value.chatId == chatId) entry.key,
      for (final entry in _deferred.entries)
        if (entry.value.chatId == chatId) entry.key,
    };
    for (final noticeId in noticeIds) {
      _cards.remove(noticeId);
      _deferred.remove(noticeId);
      unawaited(_cancel(noticeId));
    }
  }

  /// Убирает напоминание о наступившем сроке, если оно ещё висит в трее.
  void _cancelSnoozeDue(String chatId) {
    unawaited(_cancel(_dueNoticeId(chatId)));
  }

  /// Закрытая карточка больше не ждёт решения: уведомление с её id нужно убрать.
  /// Событие приходит и когда решение приняли в этом окне, и когда его прислал
  /// другой клиент.
  void _onResolution(InteractionResolution resolution) {
    final noticeId = switch (resolution) {
      ApprovalResolved(:final requestId) => agentNoticeId(
        kind: AgentNoticeKind.approvalNeeded,
        scope: profileId,
        approvalId: requestId,
      ),
      QuestionResolved(:final questionId) => agentNoticeId(
        kind: AgentNoticeKind.questionAsked,
        scope: profileId,
        questionId: questionId,
      ),
      // Для выбора отката файлов системного уведомления нет.
      EditFileChangesResolved() => null,
    };
    if (noticeId == null) return;
    _cards.remove(noticeId);
    _deferred.remove(noticeId);
    unawaited(_cancel(noticeId));
  }

  /// Сверяет показанные карточки с сервером после обрыва связи.
  ///
  /// `approvalResolved`/`questionResolved` могли потеряться, пока SSE не
  /// работал. Список карточек по чату перечитывается с сервера, поэтому
  /// уведомление, которого там уже нет, убираем: иначе кнопка в трее ведёт
  /// к неактуальному действию. Ошибка чтения оставляет уведомление: убрать
  /// актуальное хуже, чем показать лишнее.
  Future<void> _reconcileCards() async {
    if (_cards.isEmpty && _deferred.isEmpty) return;
    final byChat = <String, List<String>>{};
    for (final entry in [..._cards.entries, ..._deferred.entries]) {
      byChat.putIfAbsent(entry.value.chatId, () => []).add(entry.key);
    }
    for (final entry in byChat.entries) {
      final Set<String> approvals;
      final Set<String> questions;
      try {
        approvals = {
          for (final request in await api.pendingApprovals(entry.key))
            request.id,
        };
        questions = {
          for (final question in await api.pendingQuestions(entry.key))
            question.id,
        };
      } on Object catch (error) {
        AppLog.root.fine('notice reconcile skipped: $error');
        continue;
      }
      for (final noticeId in entry.value) {
        // Карточка могла быть скрыта, но ещё ждать очереди на эскалацию.
        final card = _cards[noticeId] ?? _deferred[noticeId];
        if (card == null) continue;
        final pending = switch (card.kind) {
          AgentNoticeKind.approvalNeeded => approvals.contains(card.cardId),
          AgentNoticeKind.questionAsked => questions.contains(card.cardId),
          _ => true,
        };
        if (pending) continue;
        _cards.remove(noticeId);
        _deferred.remove(noticeId);
        await _cancel(noticeId);
      }
    }
  }

  Future<void> _notify(
    String chatId,
    AgentNoticeKind kind, {
    String? noticeId,
    String? approvalId,
    String? questionId,
  }) async {
    final resolvedNoticeId =
        noticeId ??
        agentNoticeId(
          kind: kind,
          scope: profileId,
          chatId: chatId,
          approvalId: approvalId,
          questionId: questionId,
        );
    final card = _cardOf(chatId, kind, approvalId, questionId);
    if (_paused || await _pausedElsewhere()) {
      // Карточку не убираем из _cards: решение по ней всё ещё может прийти,
      // а после паузы о накопленном расскажет один дайджест.
      return;
    }
    if (await _visibleElsewhere(chatId)) {
      _cards.remove(resolvedNoticeId);
      if (card != null) _deferred[resolvedNoticeId] = card;
      return;
    }
    // Отложенный чат намеренно молчит до срока. Напоминание о наступившем
    // сроке сюда не попадает: к этому моменту чат уже не отложен.
    if (kind != AgentNoticeKind.snoozeDue && await _snoozedElsewhere(chatId)) {
      _cards.remove(resolvedNoticeId);
      _deferred.remove(resolvedNoticeId);
      return;
    }
    // Внимание сейчас на другом устройстве. Карточку не показываем, но
    // оставляем в очереди: когда пользователь возьмёт этот экран, присутствие
    // изменится и `_showDeferredIfTarget` покажет её здесь.
    if (!await _targetHere()) {
      _cards.remove(resolvedNoticeId);
      if (card != null) _deferred[resolvedNoticeId] = card;
      return;
    }
    var title = '';
    try {
      title = (await api.chat(chatId))?.title ?? '';
    } on Object {
      // Название не критично: уведомление покажет только действие.
    }
    // Карточку могли закрыть, пока читались presence и название.
    if (card != null &&
        !_cards.containsKey(resolvedNoticeId) &&
        !_deferred.containsKey(resolvedNoticeId)) {
      return;
    }
    if (card != null) {
      _cards[resolvedNoticeId] = card;
      _deferred.remove(resolvedNoticeId);
    }
    try {
      await notifier.notify(
        kind: kind,
        chatTitle: title,
        profileId: profileId,
        chatId: chatId,
        approvalId: approvalId,
        noticeId: resolvedNoticeId,
      );
      // Карточку могли закрыть, пока показывалось уведомление: отмена успела
      // пройти раньше платформенного показа, поэтому убираем его повторно.
      if (card != null && !_cards.containsKey(resolvedNoticeId)) {
        await _cancel(resolvedNoticeId);
      }
    } on Object catch (error) {
      AppLog.root.warning('profile notice failed', error);
    }
  }

  /// Показывает отложенные карточки, если внимание перешло на этот экран.
  ///
  /// Вызывается на каждое изменение присутствия. Если активным стал телефон,
  /// подтверждение, пришедшее на забытый десктоп, появится здесь. Повторный
  /// вызов для уже показанной карточки обновляет её по тому же `noticeId`, а не
  /// создаёт вторую. Событие, пришедшее во время проверки, не теряется: после
  /// текущего прохода очередь пересматривается ещё раз.
  Future<void> _showDeferredIfTarget() async {
    if (_deferred.isEmpty) return;
    if (_evaluatingDeferred) {
      _deferredRecheck = true;
      return;
    }
    _evaluatingDeferred = true;
    try {
      do {
        _deferredRecheck = false;
        if (_deferred.isEmpty) break;
        if (!await _targetHere()) {
          // Пока читали присутствие, внимание могло перейти сюда. Новое
          // событие уже отмечено флагом — повторяем с более свежим снимком.
          if (_deferredRecheck) continue;
          break;
        }
        // Решение могли принять на другом устройстве, а событие закрытия —
        // потеряться в обрыве связи. Перед показом сверяем очередь с сервером.
        await _reconcileCards();
        if (_deferred.isEmpty) break;
        for (final entry in [..._deferred.entries]) {
          final card = _deferred[entry.key];
          if (card == null) continue;
          await _notify(
            card.chatId,
            card.kind,
            noticeId: entry.key,
            approvalId: card.kind == AgentNoticeKind.approvalNeeded
                ? card.cardId
                : null,
            questionId: card.kind == AgentNoticeKind.questionAsked
                ? card.cardId
                : null,
          );
        }
      } while (_deferredRecheck && _deferred.isNotEmpty);
    } finally {
      _evaluatingDeferred = false;
    }
  }

  /// Описание карточки для отложенной очереди; null — событие не карточка.
  static _CardNotice? _cardOf(
    String chatId,
    AgentNoticeKind kind,
    String? approvalId,
    String? questionId,
  ) {
    final cardId = switch (kind) {
      AgentNoticeKind.approvalNeeded => approvalId,
      AgentNoticeKind.questionAsked => questionId,
      _ => null,
    };
    if (cardId == null || cardId.isEmpty) return null;
    return _CardNotice(chatId: chatId, kind: kind, cardId: cardId);
  }

  Future<bool> _visibleElsewhere(String chatId) async {
    final probe = isVisible;
    if (probe == null) return false;
    try {
      return await probe(chatId);
    } on Object catch (error) {
      AppLog.root.fine('presence check before notice failed: $error');
      return false;
    }
  }

  Future<bool> _snoozedElsewhere(String chatId) async {
    final probe = isSnoozed;
    if (probe == null) return false;
    try {
      return await probe(chatId);
    } on Object catch (error) {
      AppLog.root.fine('snooze check before notice failed: $error');
      return false;
    }
  }

  Future<bool> _pausedElsewhere() async {
    final probe = isPaused;
    if (probe == null) return false;
    try {
      return await probe();
    } on Object catch (error) {
      AppLog.root.fine('pause check before notice failed: $error');
      return false;
    }
  }

  /// Проверяет, выбрано ли это устройство для уведомлений.
  ///
  /// Без проверки или при ошибке возвращает `true`: лучше лишнее уведомление,
  /// чем пропущенный запрос подтверждения.
  Future<bool> _targetHere() async {
    final probe = isNotificationTarget;
    if (probe == null) return true;
    try {
      return await probe();
    } on Object catch (error) {
      AppLog.root.fine('notification target check failed: $error');
      return true;
    }
  }

  Future<void> _cancel(String noticeId) async {
    try {
      await notifier.cancel(noticeId);
    } on Object catch (error) {
      AppLog.root.fine('profile notice cancel failed: $error');
    }
  }
}

/// Карточка, для которой мост показал или ещё показывает уведомление.
///
/// Хранит чат и id карточки, чтобы после обрыва связи спросить сервер, ждёт ли
/// она решения, и убрать устаревшее уведомление.
final class _CardNotice {
  const _CardNotice({
    required this.chatId,
    required this.kind,
    required this.cardId,
  });

  final String chatId;
  final AgentNoticeKind kind;
  final String cardId;
}

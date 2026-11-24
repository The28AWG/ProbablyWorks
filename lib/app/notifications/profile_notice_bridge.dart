import 'dart:async';

import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/chat_api.dart';
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
final class ProfileNoticeBridge {
  ProfileNoticeBridge({
    required this.api,
    required this.notifier,
    required this.profileId,
    this.isVisible,
  });

  final AgentApi api;
  final AppNotifier notifier;
  final String profileId;
  final ChatVisibleProbe? isVisible;

  /// Карточки, для которых уведомление показано или ещё показывается.
  ///
  /// Показ асинхронный: он ждёт проверку presence и название чата. За это время
  /// карточку могут закрыть в другом окне. Без такой карты `notify` успел бы
  /// показать уже отменённое уведомление после `cancel`. Она же нужна, чтобы
  /// после обрыва связи сверить уведомления с карточками на сервере.
  final _cards = <String, _CardNotice>{};

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
    // Событие закрытия могло потеряться в обрыве связи: после восстановления
    // сверяем показанные уведомления с карточками на сервере.
    if (source case final ChatReconnectApi reconnect) {
      subscriptions.add(
        reconnect.reconnects.listen((_) => unawaited(_reconcileCards())),
      );
    }
    return subscriptions;
  }

  void _onEvent(AgentEvent event) {
    if (event is AgentChatDeleted) {
      // Вместе с чатом исчезают и его карточки: отдельного события закрытия
      // для каждой может не прийти.
      _cancelChatCards(event.chatId);
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
    final noticeIds = [
      for (final entry in _cards.entries)
        if (entry.value.chatId == chatId) entry.key,
    ];
    for (final noticeId in noticeIds) {
      _cards.remove(noticeId);
      unawaited(_cancel(noticeId));
    }
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
    if (_cards.isEmpty) return;
    final byChat = <String, List<String>>{};
    for (final entry in _cards.entries) {
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
        final card = _cards[noticeId];
        if (card == null) continue;
        final pending = switch (card.kind) {
          AgentNoticeKind.approvalNeeded => approvals.contains(card.cardId),
          AgentNoticeKind.questionAsked => questions.contains(card.cardId),
          _ => true,
        };
        if (pending) continue;
        _cards.remove(noticeId);
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
    if (await _visibleElsewhere(chatId)) {
      _cards.remove(resolvedNoticeId);
      return;
    }
    var title = '';
    try {
      title = (await api.chat(chatId))?.title ?? '';
    } on Object {
      // Название не критично: уведомление покажет только действие.
    }
    // Карточку могли закрыть, пока читались presence и название.
    if (_isCard(kind) && !_cards.containsKey(resolvedNoticeId)) return;
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
      if (_isCard(kind) && !_cards.containsKey(resolvedNoticeId)) {
        await _cancel(resolvedNoticeId);
      }
    } on Object catch (error) {
      AppLog.root.warning('profile notice failed', error);
    }
  }

  static bool _isCard(AgentNoticeKind kind) =>
      kind == AgentNoticeKind.approvalNeeded ||
      kind == AgentNoticeKind.questionAsked;

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

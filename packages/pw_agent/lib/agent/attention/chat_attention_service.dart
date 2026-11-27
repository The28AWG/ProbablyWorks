import 'dart:async';

import 'package:logging/logging.dart';
import 'package:pw_agent/agent/domain/attention_digest.dart';
import 'package:pw_agent/agent/domain/chat_attention.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/core/data/chat_repository.dart';

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
final class ChatAttentionService {
  ChatAttentionService(this._chats, this._broker) {
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
    _approvalSub = _broker.approvalRequests.listen((_) => _recompute());
    _questionSub = _broker.questions.listen((_) => _recompute());
    _editFilesSub = _broker.editFileChangesRequests.listen((_) => _recompute());
    _resolutionSub = _broker.resolutions.listen((_) => _recompute());
  }

  final ChatRepository _chats;
  final InteractionBroker _broker;
  final _log = Logger('ChatAttentionService');
  final _changes = StreamController<AttentionSnapshot>.broadcast();

  late final StreamSubscription<List<Chat>> _chatsSub;
  late final StreamSubscription<List<ChatAttentionRecord>> _statesSub;
  late final StreamSubscription<ApprovalRequest> _approvalSub;
  late final StreamSubscription<UserQuestion> _questionSub;
  late final StreamSubscription<EditFileChangesRequest> _editFilesSub;
  late final StreamSubscription<InteractionResolution> _resolutionSub;

  /// Чаты и сохранённые состояния приходят разными потоками. Пока не пришёл
  /// хотя бы один, сводка не строится: пустой снимок выглядел бы как «ничего
  /// не требует внимания» и мигал бы при каждом запуске.
  List<Chat>? _chatsSnapshot;
  List<ChatAttentionRecord>? _statesSnapshot;

  /// Итог только что записанного хода, пока поток базы не прислал строку.
  ///
  /// Между записью в базу и обновлением [watchAttentionStates] снимок иначе
  /// успевал бы показать старую проблему: `_running` уже снят, а кэш строк
  /// ещё прежний. Значение `null` означает, что проблема снята.
  final Map<String, ChatAttentionRecord?> _finishedTurns = {};

  final Set<String> _running = {};
  List<ChatAttention> _items = const [];
  var _revision = 0;
  var _disposed = false;

  AttentionSnapshot get snapshot =>
      AttentionSnapshot(revision: _revision, items: _items);

  /// Новый снимок при любом значимом изменении. Поток широковещательный:
  /// окно и SSE-подписчики получают одно и то же состояние.
  Stream<AttentionSnapshot> get changes => _changes.stream;

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
  Future<AttentionDigest> digest() async {
    final chats = _chatsSnapshot ?? await _chats.watchChats().first;
    final states = _statesSnapshot ?? await _chats.watchAttentionStates().first;
    final items = _buildItems(chats, states);
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
    if (chats == null || states == null || _disposed) return;

    final items = _buildItems(chats, states);
    if (_sameItems(_items, items)) return;
    _items = List.unmodifiable(items);
    _revision++;
    if (!_changes.isClosed) {
      _changes.add(AttentionSnapshot(revision: _revision, items: _items));
    }
  }

  /// Строит отсортированный список чатов, которые требуют внимания.
  List<ChatAttention> _buildItems(
    List<Chat> chats,
    List<ChatAttentionRecord> states,
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

    final items = <ChatAttention>[];
    for (final chat in chats) {
      if (chat.kind == ChatKind.subagent) continue;
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
    await _chatsSub.cancel();
    await _statesSub.cancel();
    await _approvalSub.cancel();
    await _questionSub.cancel();
    await _editFilesSub.cancel();
    await _resolutionSub.cancel();
    await _changes.close();
  }
}

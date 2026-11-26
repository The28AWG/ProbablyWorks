import 'package:equatable/equatable.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';

/// Почему чат попал во входящие.
///
/// Причины живут отдельно от статуса сессии: один чат может одновременно
/// ждать решения по двум карточкам и иметь непрочитанный ответ. Порядок
/// [priority] задаёт срочность, а не время: решение по карточке важнее
/// упавшего хода, а он — важнее простого непрочитанного сообщения.
enum ChatAttentionReason {
  approval(priority: 0, decision: true),
  question(priority: 0, decision: true),
  editFiles(priority: 0, decision: true),
  failed(priority: 1, problem: true),
  stepLimit(priority: 2, problem: true),
  budget(priority: 2, problem: true),
  stalled(priority: 2, problem: true),
  unread(priority: 3);

  const ChatAttentionReason({
    required this.priority,
    this.decision = false,
    this.problem = false,
  });

  /// Меньше — срочнее.
  final int priority;

  /// Причина требует решения пользователя прямо сейчас.
  final bool decision;

  /// Ход завершился не штатно: ошибка, лимит шагов, бюджет или застой.
  final bool problem;
}

/// Последнее завершение хода, которое остаётся заметным до следующего хода.
///
/// Хранится в базе, потому что баннер лимита шагов или ошибки не должен
/// исчезать после перезапуска приложения. Курсор прочтения его не снимает:
/// пользователь мог прочитать сообщение, но не продолжить работу.
enum ChatAttentionTurn {
  failed,
  stepLimit,
  budget,
  stalled;

  /// Строка из базы. Неизвестное значение — null: новая версия не должна
  /// ломать старую запись.
  static ChatAttentionTurn? fromStorage(String value) {
    for (final turn in values) {
      if (turn.name == value) return turn;
    }
    return null;
  }

  ChatAttentionReason get reason => switch (this) {
    ChatAttentionTurn.failed => ChatAttentionReason.failed,
    ChatAttentionTurn.stepLimit => ChatAttentionReason.stepLimit,
    ChatAttentionTurn.budget => ChatAttentionReason.budget,
    ChatAttentionTurn.stalled => ChatAttentionReason.stalled,
  };
}

/// Сохранённое состояние «ход закончился и ждёт пользователя».
///
/// Запись одна на чат: новый проблемный ход заменяет предыдущий, а обычный
/// ход удаляет её. Отдельная таблица, как у курсора прочтения, не даёт
/// полному сохранению чата стирать это состояние.
final class ChatAttentionRecord extends Equatable {
  const ChatAttentionRecord({
    required this.chatId,
    required this.turn,
    required this.occurredAt,
    required this.revision,
  });

  final String chatId;
  final ChatAttentionTurn turn;
  final DateTime occurredAt;
  final int revision;

  @override
  List<Object?> get props => [chatId, turn, occurredAt, revision];
}

/// Один чат во входящих: всё, что требует внимания, и готовые карточки.
///
/// Карточки лежат здесь, а не только счётчиками: входящие принимают решение
/// на месте, не открывая чат. Данные — снимок на момент события; действия
/// по-прежнему идут через сервер и проверяют актуальность.
final class ChatAttention extends Equatable {
  const ChatAttention({
    required this.chatId,
    required this.hostId,
    required this.title,
    required this.reasons,
    required this.approvals,
    required this.questions,
    required this.editFileChanges,
    required this.unreadCount,
    required this.lastReadSeq,
    required this.lastMessageSeq,
    required this.running,
    required this.updatedAt,
    this.projectId,
    this.turnAt,
  });

  final String chatId;
  final String hostId;
  final String? projectId;
  final String title;
  final Set<ChatAttentionReason> reasons;
  final List<ApprovalRequest> approvals;
  final List<UserQuestion> questions;
  final List<EditFileChangesRequest> editFileChanges;
  final int unreadCount;
  final int lastReadSeq;
  final int lastMessageSeq;

  /// Идёт ли ход прямо сейчас. Само по себе это не повод для входящих:
  /// поле нужно подписи и будущему пульту, а не счётчику входящих.
  final bool running;

  /// Когда закончился проблемный ход. Null, если проблемного хода нет.
  final DateTime? turnAt;
  final DateTime updatedAt;

  bool get hasDecisions => reasons.any((reason) => reason.decision);

  bool get hasProblem => reasons.any((reason) => reason.problem);

  /// Сколько действий пользователь должен разобрать в этом чате.
  ///
  /// Непрочитанное не входит: это не решение, а сообщение. Карточки считаются
  /// поштучно, проблема — одна на чат, потому что это состояние одного хода.
  int get actionableCount =>
      approvals.length +
      questions.length +
      editFileChanges.length +
      (hasProblem ? 1 : 0);

  /// Меньше — срочнее. Нужна для сортировки и заголовков групп.
  int get priority => reasons.isEmpty
      ? ChatAttentionReason.unread.priority
      : reasons.map((reason) => reason.priority).reduce(_min);

  static int _min(int a, int b) => a < b ? a : b;

  @override
  List<Object?> get props => [
    chatId,
    hostId,
    projectId,
    title,
    reasons,
    approvals,
    questions,
    editFileChanges,
    unreadCount,
    lastReadSeq,
    lastMessageSeq,
    running,
    turnAt,
    updatedAt,
  ];
}

/// Полный снимок входящих с монотонной ревизией.
///
/// Снимок, а не дельта: входящих мало, а окно после обрыва SSE не должно
/// собирать состояние из пропущенных частей. Ревизия отсекает запоздавший
/// ответ HTTP, пришедший после более свежего события.
final class AttentionSnapshot extends Equatable {
  const AttentionSnapshot({required this.revision, required this.items});

  static const empty = AttentionSnapshot(revision: 0, items: []);

  final int revision;
  final List<ChatAttention> items;

  /// Сколько решений ждёт пользователя во всех чатах. Это число показывает
  /// бейдж навигации; непрочитанное в него не входит.
  int get actionableCount =>
      items.fold(0, (sum, item) => sum + item.actionableCount);

  int get unreadCount => items.fold(0, (sum, item) => sum + item.unreadCount);

  @override
  List<Object?> get props => [revision, items];
}

import 'package:equatable/equatable.dart';

/// Один чат в дайджесте «пока вас не было».
///
/// Счётчики уже посчитаны агентом по общему курсору прочтения, поэтому
/// устройство не пересчитывает их по своей копии списка. Это важно для
/// нескольких экранов: прочитанное на телефоне не должно снова появляться в
/// дайджесте на десктопе.
final class AttentionDigestItem extends Equatable {
  const AttentionDigestItem({
    required this.chatId,
    required this.hostId,
    required this.title,
    this.projectId,
    this.unreadMessages = 0,
    this.finishedTurns = 0,
    this.approvals = 0,
    this.questions = 0,
    this.editFileChanges = 0,
    this.problems = 0,
  });

  final String chatId;
  final String hostId;
  final String? projectId;
  final String title;

  /// Непрочитанные сообщения агента и служебные строки после курсора.
  final int unreadMessages;

  /// Завершённые ходы после курсора: видимые ответы без вызовов инструментов.
  final int finishedTurns;

  /// Карточки, которые ждут решения пользователя.
  final int approvals;
  final int questions;
  final int editFileChanges;

  /// Проблемные завершения хода: ошибка, лимит шагов, бюджет или застой.
  final int problems;

  /// Сколько решений ждёт пользователя в этом чате.
  int get decisions => approvals + questions + editFileChanges;

  bool get isEmpty =>
      unreadMessages == 0 &&
      finishedTurns == 0 &&
      decisions == 0 &&
      problems == 0;

  @override
  List<Object?> get props => [
    chatId,
    hostId,
    projectId,
    title,
    unreadMessages,
    finishedTurns,
    approvals,
    questions,
    editFileChanges,
    problems,
  ];
}

/// Сводка того, что накопилось с последнего прочитанного сообщения.
///
/// Дайджест строится по общему read-курсору, а не по времени отсутствия
/// конкретного устройства. Так телефон и десктоп видят один и тот же ответ на
/// вопрос «что я пропустил», а не два разных.
final class AttentionDigest extends Equatable {
  const AttentionDigest({required this.items});

  static const empty = AttentionDigest(items: []);

  final List<AttentionDigestItem> items;

  int get newMessages =>
      items.fold(0, (sum, item) => sum + item.unreadMessages);

  int get finishedTurns =>
      items.fold(0, (sum, item) => sum + item.finishedTurns);

  int get approvals => items.fold(0, (sum, item) => sum + item.approvals);

  int get questions => items.fold(0, (sum, item) => sum + item.questions);

  int get editFileChanges =>
      items.fold(0, (sum, item) => sum + item.editFileChanges);

  int get problems => items.fold(0, (sum, item) => sum + item.problems);

  /// Сколько решений ждёт пользователя во всех чатах.
  int get decisions => approvals + questions + editFileChanges;

  bool get isEmpty => items.isEmpty;

  @override
  List<Object?> get props => [items];
}

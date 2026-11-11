/// Состояние отложенной задачи.
///
/// `dispatched` — сообщение уже передано сессии; дальнейшая судьба видна в журнале чата.
enum ScheduledTaskStatus { pending, dispatched, failed, cancelled }

/// Отложенный запуск агента в конкретном чате.
final class ScheduledTask {
  const ScheduledTask({
    required this.id,
    required this.chatId,
    required this.prompt,
    required this.dueAt,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.error,
  });

  final String id;
  final String chatId;
  final String prompt;
  final DateTime dueAt;
  final ScheduledTaskStatus status;
  final String? error;
  final DateTime createdAt;
  final DateTime updatedAt;
}

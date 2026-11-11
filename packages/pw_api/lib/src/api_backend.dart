import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/schedule/scheduled_task.dart';
import 'package:pw_agent/core/domain/host.dart';

/// Ошибка API с HTTP-статусом. Сервер превращает её в JSON без стека.
final class ApiError implements Exception {
  const ApiError(this.status, this.code, this.message);

  final int status;
  final String code;
  final String message;

  @override
  String toString() => 'ApiError($status, $code): $message';
}

/// То, что HTTP-слою нужно от агента. Позволяет тестировать API без AgentHub.
abstract interface class ApiBackend {
  Future<List<Host>> hosts();
  Future<List<Chat>> chats();
  Future<Chat?> chat(String id);
  Future<Chat> createChat(String hostId);
  Future<List<ChatMessage>> messages(String id);
  Future<List<ToolRun>> runs(String id);

  /// Регистрирует карточки чата и, если нужно, продолжает ход.
  Future<void> openChat(String id);

  Future<void> send(String chatId, String text, {bool sendNow = false});
  Future<void> stop(String chatId);

  Future<void> resolveApproval(
    String id,
    ApprovalAction action, {
    String? reason,
  });
  Future<void> answerQuestion(String id, String? text);
  Future<void> resolveEditFileChanges(String id, EditFileChangesChoice choice);

  List<ApprovalRequest> pendingApprovals(String chatId);
  List<UserQuestion> pendingQuestions(String chatId);
  List<EditFileChangesRequest> pendingEditFileChanges(String chatId);

  Future<List<ScheduledTask>> schedules();
  Future<ScheduledTask?> scheduledTask(String id);
  Future<ScheduledTask> schedule({
    required String chatId,
    required String prompt,
    required DateTime dueAt,
  });
  Future<void> cancelSchedule(String id);

  /// Поток событий агента и карточек (`AgentEvent`, `ApprovalRequest`,
  /// `UserQuestion`, `EditFileChangesRequest`).
  Stream<Object> events();
}

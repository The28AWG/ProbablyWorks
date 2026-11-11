import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/agent/schedule/scheduled_task.dart';
import 'package:pw_agent/core/domain/host.dart';

/// Состояние соединения с агентом.
enum AgentStatus { online, offline, connecting }

/// Ошибка единого клиентского API.
///
/// Локальный адаптер берёт [status] из доменной ошибки или ставит 500,
/// удалённый — из HTTP-ответа. UI обрабатывает один тип.
final class AgentApiException implements Exception {
  const AgentApiException(this.status, this.code, this.message);

  final int status;
  final String code;
  final String message;

  @override
  String toString() => 'AgentApiException($status, $code): $message';
}

/// Единый типизированный API агента для клиента.
///
/// Локальная реализация вызывает [AgentHub] напрямую, без HTTP и JSON.
/// Удалённая реализация ходит в `pw_server` по HTTP/SSE, но возвращает те же
/// доменные модели и бросает тот же [AgentApiException].
abstract interface class AgentApi {
  /// Текущее состояние соединения. Локальный агент всегда online.
  AgentStatus get status;

  /// Поток изменений состояния соединения.
  Stream<AgentStatus> get statusChanges;

  /// Явная проверка доступности. Нужна при первом подключении и после
  /// разрыва; в обычной работе статус обновляют запросы и SSE.
  Future<bool> checkConnection();

  /// Журнал хода: сообщения, запуски, очередь.
  Stream<AgentEvent> get events;

  /// Карточки подтверждения и вопросы.
  Stream<ApprovalRequest> get approvals;
  Stream<UserQuestion> get questions;
  Stream<EditFileChangesRequest> get editChanges;

  /// Чаты с идущим ходом агента. Нужно для бейджей и фонового режима.
  Set<String> get runningChatIds;

  /// Чаты с неотвеченными карточками.
  Set<String> get waitingChatIds;

  Future<List<Host>> hosts();
  Future<List<Chat>> chats();

  /// Список чатов и хостов с обновлениями. Локально — поток БД,
  /// удалённо — периодическое обновление и события.
  Stream<List<Chat>> watchChats();
  Stream<List<Host>> watchHosts();
  Future<Chat?> chat(String id);
  Future<Chat> createChat(String hostId);

  /// Сохраняет чат целиком. Для удалённого агента это upsert по id.
  Future<void> saveChat(Chat chat);
  Future<void> renameChat(String chatId, String title);
  Future<void> updateChat(
    String chatId, {
    String? title,
    String? model,
    PolicyMode? policyMode,
    String? workspace,
    bool workspaceSpecified = false,
  });
  Future<Chat?> forkChat(String chatId, {String? title});
  Future<void> deleteChat(String chatId);

  Future<List<ChatMessage>> messages(String chatId);
  Future<List<ToolRun>> runs(String chatId);

  /// Регистрирует карточки чата и продолжает ход, если нужно.
  Future<void> openChat(String chatId);

  Future<void> send(String chatId, String text, {bool sendNow = false});
  Future<void> stop(String chatId, {String? reason});

  /// Продолжает незавершённые шаги после локального перезапуска.
  Future<void> resumeAfterRestart();

  Future<void> resolveApproval(
    String id,
    ApprovalAction action, {
    String? reason,
  });
  Future<void> answerQuestion(String id, String? text);
  Future<void> resolveEditFileChanges(String id, EditFileChangesChoice choice);

  Future<List<ApprovalRequest>> pendingApprovals(String chatId);
  Future<List<UserQuestion>> pendingQuestions(String chatId);
  Future<List<EditFileChangesRequest>> pendingEditFileChanges(String chatId);

  Future<List<ScheduledTask>> schedules();
  Future<ScheduledTask?> scheduledTask(String id);
  Future<ScheduledTask> schedule({
    required String chatId,
    required String prompt,
    required DateTime dueAt,
  });
  Future<void> cancelSchedule(String id);
}

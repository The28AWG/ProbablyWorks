import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/search.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/providers/ai/reasoning.dart';

/// Состояние соединения с агентом.
enum AgentStatus { online, offline, connecting }

/// Ошибка единого клиентского API.
///
/// Локальный адаптер берёт [status] из доменной ошибки или ставит 500,
/// удалённый — из HTTP-ответа. UI обрабатывает один тип.
final class AgentApiException implements Exception {
  const AgentApiException(
    this.status,
    this.code,
    this.message, {
    this.requestId,
  });

  final int status;
  final String code;
  final String message;

  /// Идентификатор HTTP-запроса для сопоставления с журналом доступа сервера.
  final String? requestId;

  /// Текст для пользователя: к ошибке добавляется request id, если он есть.
  String get userMessage =>
      requestId == null ? message : '$message (request id: $requestId)';

  @override
  String toString() => userMessage;
}

/// Единый типизированный API агента для клиента.
///
/// Локальная реализация вызывает [AgentHub] напрямую, без HTTP и JSON.
/// Удалённая реализация ходит в `pw_server` по HTTP/SSE, но возвращает те же
/// доменные модели и бросает тот же [AgentApiException].
/// Дополнительный поток для клиентов, которым нужно знать о закрытии
/// карточек. Не входит в [AgentApi], чтобы не расширять все тестовые
/// реализации: поток нужен только удалённому транспорту и списку чатов.
abstract interface class InteractionEventsApi {
  /// Закрытые подтверждения, вопросы и выбор откатов.
  Stream<InteractionResolution> get resolutions;
}

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
    ReasoningPreference? reasoning,
    PolicyMode? policyMode,
    String? workspace,
    bool workspaceSpecified = false,
  });

  /// Сдвигает общий курсор прочтения чата до [seq] включительно.
  ///
  /// Курсор монотонен и ограничен последним сообщением сервера. Возвращает
  /// обновлённый чат с `lastReadSeq`, `lastMessageSeq` и `unreadCount`.
  Future<Chat> markChatRead(
    String chatId, {
    required int seq,
    int? expectedRevision,
  });

  /// Дубликат чата. [untilMessageId] обрывает историю на указанном ответе:
  /// всё, что ниже линии, в копию не идёт, включая задачи этих сообщений.
  ///
  /// [copyPendingTasks] переносит и не сработавшие задачи выше линии:
  /// пользователь выбирает это сам, потому что перенос может задвоить
  /// напоминание, а отказ теряет его после удаления исходного чата.
  Future<Chat?> forkChat(
    String chatId, {
    String? title,
    String? untilMessageId,
    bool copyPendingTasks = false,
  });

  /// Сколько отложенных задач чата ещё не сработало. Нужно перед форком:
  /// спрашивать имеет смысл только когда есть что переносить.
  ///
  /// [untilMessageId] ограничивает счёт задачами выше линии форка: ниже линии
  /// они в копию не попадут, и обещать их перенос нельзя.
  Future<int> pendingScheduledTasks(String chatId, {String? untilMessageId});

  /// Удаляет чат и его скрытых субагентов.
  ///
  /// Возвращает id всех удалённых чатов: каскад затрагивает подчаты, и
  /// клиенту нужно очистить их черновики. Локальный backend отдаёт полный
  /// список, удалённый получает его из ответа сервера.
  Future<List<String>> deleteChat(String chatId);

  Future<List<ChatMessage>> messages(String chatId);
  Future<List<ToolRun>> runs(String chatId);

  /// Поиск по названиям чатов и сообщениям. Выполняется на стороне агента,
  /// поэтому клиент не читает всю историю ради палитры.
  Future<List<SearchHit>> search(SearchQuery query);

  /// Регистрирует карточки чата и продолжает ход, если нужно.
  Future<void> openChat(String chatId);

  /// Отправляет сообщение в чат.
  ///
  /// [clientMessageId] делает повтор идемпотентным: тот же id после таймаута
  /// не создаёт дубль и не запускает второй ход.
  Future<void> send(
    String chatId,
    String text, {
    bool sendNow = false,
    List<AttachmentRef> attachments = const [],
    List<MentionRef> mentions = const [],
    String? clientMessageId,
  });
  Future<void> stop(String chatId, {String? reason});

  /// Продолжает незавершённые шаги после локального перезапуска.
  Future<void> resumeAfterRestart();

  Future<void> resolveApproval(
    String id,
    ApprovalAction action, {
    String? reason,
  });

  /// Отвечает на вопрос агента.
  ///
  /// [answerId] — ключ идемпотентности для действия из системного
  /// уведомления: платформа может доставить одно и то же нажатие дважды, а
  /// вопрос уже закрыт первым ответом. Сервер не создаёт второй ответ и не
  /// продолжает ход повторно. Обычный ответ из карточки передаёт `null`.
  Future<void> answerQuestion(String id, String? text, {String? answerId});
  Future<void> resolveEditFileChanges(String id, EditFileChangesChoice choice);

  Future<List<ApprovalRequest>> pendingApprovals(String chatId);
  Future<List<UserQuestion>> pendingQuestions(String chatId);
  Future<List<EditFileChangesRequest>> pendingEditFileChanges(String chatId);
}

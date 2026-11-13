import 'package:pw_agent/agent/api/draft_persistence.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/project.dart';
import 'package:pw_agent/agent/domain/steps_display.dart';
import 'package:pw_agent/agent/exec/active_exec_registry.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/agent/loop/prompt_queue.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/core/domain/chat_usage.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';

/// API, который нужен экрану одного чата.
///
/// Это не HTTP-контракт: локальный адаптер реализует его поверх `AgentHub`,
/// а удалённый сможет реализовать через те же endpoint'ы. `ChatBloc` больше
/// не импортирует `AgentHub`/`ChatSession` напрямую.
abstract interface class ChatApi {
  ChatStore get chatStore;
  SettingsStore get settings;
  ProjectStore get projectStore;
  ProjectsStore get projects;
  ModelStore get models;
  HostStore get hostStore;
  ExecStore get registry;
  InteractionsStore get broker;

  ChatSessionApi session(String chatId);
  Future<AppLimits> limits();
  Future<Chat?> forkChat(
    String chatId, {
    String? title,
    String? untilMessageId,
  });
  Chat draftChat({required String hostId, Host? host});
}

abstract interface class ChatStore implements DraftPersistence {
  @override
  Future<Chat?> chat(String id);
  Future<List<ChatMessage>> messages(String id);
  Future<List<ToolRun>> toolRunsForChat(String id);

  /// Сохраняет новый чат с id, который уже сгенерировал клиент.
  ///
  /// Локальный backend делает upsert, удалённый — создаёт запись. Обычный
  /// [saveChat] меняет существующий чат и не должен создавать новый.
  Future<void> createChat(Chat chat);

  Future<void> saveChat(Chat chat);

  /// Изменения черновиков, сделанные другим клиентом.
  Stream<String> watchDraftChanges();
}

abstract interface class SettingsStore {
  Stream<String?> watch(String key);
  Future<String?> read(String key);
  Future<List<String>> readPinnedModels();
  Future<void> savePinnedModels(List<String> ids);
  Future<StepsDisplay> readStepsDisplay();
  Future<ChatDailyUsage> readDailyUsage(String chatId);
  Future<double?> readDailyBudget(String chatId);
  Future<void> saveDailyBudget(String chatId, double? value);
  Future<ChatCompactionInfo?> readCompactionInfo(String chatId);
  Future<void> setTrusted(
    String hostId,
    String workspace, {
    required bool trusted,
  });
  AppLimits cachedLimits();
  List<String> cachedPinnedModels();
  StepsDisplay cachedStepsDisplay();
  String? cached(String key);
}

abstract interface class ProjectStore {
  Future<Project?> forChat(String chatId);
  Future<Project?> byId(String id);
}

abstract interface class ProjectsStore {
  Future<Chat> attach(Chat chat);
  String? configuredWorkspace(Host host);
  Future<Chat> relocate(
    Chat chat, {
    String? hostId,
    String? workspace,
    bool workspaceSpecified = false,
  });
  Future<void> trustWorkspace(String projectId);
}

abstract interface class ModelStore implements ModelCatalogSource {
  Future<void> remember(List<String> ids);
}

abstract interface class HostStore {
  Future<List<Host>> all();
  Stream<List<Host>> watchAll();
}

abstract interface class ExecStore {
  ActiveExec? find(String runId);
  Future<void> stop(ActiveExec exec, {required bool force});
}

abstract interface class InteractionsStore {
  Stream<ApprovalRequest> get approvalRequests;
  Stream<UserQuestion> get questions;
  Stream<EditFileChangesRequest> get editFileChangesRequests;
  List<ApprovalRequest> pendingApprovals(String chatId);
  List<UserQuestion> pendingQuestions(String chatId);
  List<EditFileChangesRequest> pendingEditFileChanges(String chatId);
  void resolveApproval(String requestId, ApprovalDecision decision);
  void answer(String questionId, String? text);
  void resolveEditFileChanges(String requestId, EditFileChangesChoice choice);
}

abstract interface class ChatSessionApi {
  bool get isRunning;
  List<QueuedPrompt> get queue;
  Stream<AgentEvent> get events;

  Future<void> submit(
    String text, {
    List<AttachmentRef> attachments = const [],
    bool sendNow = false,
  });
  Future<void> stop({String? reason});
  Future<void> continueAfterStepLimit();
  Future<bool> regenerateLast();
  void promoteQueued(int index);
  QueuedPrompt? takeQueued(int index);
  Future<bool> editUserMessage(
    String messageId,
    String newText, {
    List<AttachmentRef>? attachments,
  });
  Future<void> deleteAfter(String messageId);
  Future<void> restoreUnanswered();
  Future<void> compactNow({bool force = false});
}

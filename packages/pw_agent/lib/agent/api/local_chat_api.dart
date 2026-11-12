import 'dart:async';

import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/chat_api.dart';
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
import 'package:pw_agent/src/agent/loop/agent_hub.dart';

/// Локальный [AgentApi]: прямые вызовы [AgentHub], брокера и планировщика.
///
/// Никакого транспорта, сериализации и токенов. Используется встроенным
/// агентом клиента и HTTP-сервером демона.
@lazySingleton
class LocalChatApi implements ChatApi {
  LocalChatApi(AgentHub hub) : _hub = hub;

  final AgentHub _hub;

  @override
  late final ChatStore chatStore = _LocalChatStore(_hub.chats);

  @override
  late final SettingsStore settings = _LocalSettings(_hub.settings);

  @override
  late final ProjectStore projectStore = _LocalProjectStore(_hub.projectStore);

  @override
  late final ProjectsStore projects = _LocalProjects(_hub.projects);

  @override
  late final ModelStore models = _LocalModels(_hub.models);

  @override
  late final HostStore hostStore = _LocalHosts(_hub.hosts);

  @override
  late final ExecStore registry = _LocalExec(_hub.registry);

  @override
  late final InteractionsStore broker = _LocalInteractions(_hub.broker);

  @override
  ChatSessionApi session(String chatId) =>
      _LocalChatSession(_hub.session(chatId));

  @override
  Future<AppLimits> limits() => _hub.limits();

  @override
  Chat draftChat({required String hostId, Host? host}) =>
      _hub.draftChat(hostId: hostId, host: host);

  Stream<AgentEvent> get events => _hub.allEvents;

  Stream<ApprovalRequest> get approvals => _hub.broker.approvalRequests;

  Stream<UserQuestion> get questions => _hub.broker.questions;

  Stream<EditFileChangesRequest> get editChanges =>
      _hub.broker.editFileChangesRequests;

  Set<String> get runningChatIds => _hub.runningChatIds;

  Set<String> get waitingChatIds => _hub.waitingChatIds;

  Future<List<Host>> hosts() => _hub.hosts.all();

  Stream<List<Chat>> watchChats() => _hub.chats.watchChats();

  Stream<List<Host>> watchHosts() => _hub.hosts.watchAll();

  Future<List<Chat>> chats() async {
    final all = await _hub.chats.allChats();
    return [
      for (final chat in all)
        if (!chat.isSubagent) chat,
    ];
  }

  Future<Chat?> chat(String id) => _hub.chats.chat(id);

  Future<Chat> createChat(String hostId) async {
    if (await _hub.hosts.byId(hostId) == null) {
      throw AgentApiException(404, 'host_not_found', 'host $hostId not found');
    }
    return _hub.newChat(hostId: hostId);
  }

  Future<void> saveChat(Chat chat) => _hub.chats.saveChat(chat);

  Future<void> renameChat(String chatId, String title) =>
      updateChat(chatId, title: title);

  Future<void> updateChat(
    String chatId, {
    String? title,
    String? model,
    PolicyMode? policyMode,
    String? workspace,
    bool workspaceSpecified = false,
  }) async {
    final chat = await _hub.chats.chat(chatId);
    if (chat == null) {
      throw AgentApiException(404, 'chat_not_found', 'chat $chatId not found');
    }
    final trimmed = title?.trim();
    await _hub.chats.saveChat(
      chat.copyWith(
        title: trimmed == null || trimmed.isEmpty ? null : trimmed,
        titleSource: trimmed == null || trimmed.isEmpty
            ? null
            : ChatTitleSource.user,
        model: model,
        policyMode: policyMode,
        workspace: workspaceSpecified ? workspace : null,
        clearWorkspace: workspaceSpecified && workspace == null,
      ),
    );
  }

  @override
  Future<Chat?> forkChat(
    String chatId, {
    String? title,
    String? untilMessageId,
  }) async {
    try {
      return await _hub.forkChat(
        chatId,
        title: title,
        untilMessageId: untilMessageId,
      );
    } on Object {
      return null;
    }
  }

  Future<void> deleteChat(String chatId) async {
    final session = _hub.session(chatId);
    if (session.isRunning) await session.stop();
    final project = await _hub.projects.projectForChat(chatId);
    await _hub.chats.deleteChat(chatId);
    await _hub.settings.deleteChatData(chatId);
    _hub.broker.clearChatGrants(chatId);
    await _hub.logs.deleteChat(chatId);
    await _hub.turnChangesets.store.deleteChat(chatId);
    await _hub.projects.releaseIfEmpty(project?.id);
  }

  Future<List<ChatMessage>> messages(String chatId) async {
    await requireChat(chatId);
    return _hub.chats.messages(chatId);
  }

  Future<List<ToolRun>> runs(String chatId) async {
    await requireChat(chatId);
    return _hub.chats.toolRunsForChat(chatId);
  }

  Future<void> openChat(String chatId) async {
    await requireChat(chatId);
    await _hub.session(chatId).restoreUnanswered();
  }

  Future<void> send(
    String chatId,
    String text, {
    bool sendNow = false,
    List<AttachmentRef> attachments = const [],
  }) async {
    await requireChat(chatId);
    if (text.trim().isEmpty && attachments.isEmpty) {
      throw const AgentApiException(400, 'empty_message', 'message is empty');
    }
    await _hub
        .session(chatId)
        .submit(text, attachments: attachments, sendNow: sendNow);
  }

  Future<void> stop(String chatId, {String? reason}) async {
    await requireChat(chatId);
    await _hub.session(chatId).stop(reason: reason);
  }

  Future<void> resolveApproval(
    String id,
    ApprovalAction action, {
    String? reason,
  }) {
    final decision = switch (action) {
      ApprovalAction.deny => ApprovalDecision.deny(reason: reason),
      ApprovalAction.allowOnce => const ApprovalDecision.allowOnce(),
      ApprovalAction.allowTurn => const ApprovalDecision.allowTurn(),
      ApprovalAction.allowChat => const ApprovalDecision.allowChat(),
    };
    _hub.broker.resolveApproval(id, decision);
    return Future<void>.value();
  }

  Future<void> answerQuestion(String id, String? text) {
    _hub.broker.answer(id, text);
    return Future<void>.value();
  }

  Future<void> resolveEditFileChanges(String id, EditFileChangesChoice choice) {
    _hub.broker.resolveEditFileChanges(id, choice);
    return Future<void>.value();
  }

  Future<List<ApprovalRequest>> pendingApprovals(String chatId) async =>
      _hub.broker.pendingApprovals(chatId);

  Future<List<UserQuestion>> pendingQuestions(String chatId) async =>
      _hub.broker.pendingQuestions(chatId);

  Future<List<EditFileChangesRequest>> pendingEditFileChanges(
    String chatId,
  ) async => _hub.broker.pendingEditFileChanges(chatId);

  Future<void> resumeAfterRestart() => _hub.resumeAfterRestart();

  Future<void> requireChat(String id) async {
    if (await _hub.chats.chat(id) == null) {
      throw AgentApiException(404, 'chat_not_found', 'chat $id not found');
    }
  }
}

final class _LocalChatStore implements ChatStore {
  _LocalChatStore(this._chats);

  final dynamic _chats;

  @override
  Future<Chat?> chat(String id) => _chats.chat(id);

  @override
  Future<List<ChatMessage>> messages(String id) => _chats.messages(id);

  @override
  Future<List<ToolRun>> toolRunsForChat(String id) =>
      _chats.toolRunsForChat(id);

  @override
  Future<void> saveChat(Chat chat) => _chats.saveChat(chat);

  @override
  Stream<String> watchDraftChanges() => const Stream.empty();

  @override
  Future<int> saveDraft(
    String chatId,
    ChatDraft draft, {
    int? expectedRevision,
  }) => _chats.saveDraft(chatId, draft, expectedRevision: expectedRevision);

  @override
  Future<int> saveMessageEdits(
    String chatId,
    Map<String, ChatDraft> edits, {
    int? expectedRevision,
  }) => _chats.saveMessageEdits(
    chatId,
    edits,
    expectedRevision: expectedRevision,
  );
}

final class _LocalSettings implements SettingsStore {
  _LocalSettings(this._settings);

  final dynamic _settings;

  @override
  Stream<String?> watch(String key) => _settings.watch(key);

  @override
  Future<String?> read(String key) => _settings.read(key);

  @override
  Future<List<String>> readPinnedModels() => _settings.readPinnedModels();

  @override
  Future<void> savePinnedModels(List<String> ids) =>
      _settings.savePinnedModels(ids);

  @override
  Future<StepsDisplay> readStepsDisplay() => _settings.readStepsDisplay();

  @override
  Future<ChatDailyUsage> readDailyUsage(String chatId) =>
      _settings.readDailyUsage(chatId);

  @override
  Future<double?> readDailyBudget(String chatId) =>
      _settings.readDailyBudget(chatId);

  @override
  Future<void> saveDailyBudget(String chatId, double? value) =>
      _settings.saveDailyBudget(chatId, value);

  @override
  Future<ChatCompactionInfo?> readCompactionInfo(String chatId) =>
      _settings.readCompactionInfo(chatId);

  @override
  Future<void> setTrusted(
    String hostId,
    String workspace, {
    required bool trusted,
  }) => _settings.setTrusted(hostId, workspace, trusted: trusted);

  @override
  AppLimits cachedLimits() => _settings.cachedLimits();

  @override
  List<String> cachedPinnedModels() => _settings.cachedPinnedModels();

  @override
  StepsDisplay cachedStepsDisplay() => _settings.cachedStepsDisplay();

  @override
  String? cached(String key) => _settings.cached(key);
}

final class _LocalProjectStore implements ProjectStore {
  _LocalProjectStore(this._projects);

  final dynamic _projects;

  @override
  Future<Project?> forChat(String chatId) => _projects.forChat(chatId);

  @override
  Future<Project?> byId(String id) => _projects.byId(id);
}

final class _LocalProjects implements ProjectsStore {
  _LocalProjects(this._projects);

  final dynamic _projects;

  @override
  Future<Chat> attach(Chat chat) => _projects.attach(chat);

  @override
  String? configuredWorkspace(Host host) => _projects.configuredWorkspace(host);

  @override
  Future<Chat> relocate(
    Chat chat, {
    String? hostId,
    String? workspace,
    bool workspaceSpecified = false,
  }) => _projects.relocate(
    chat,
    hostId: hostId,
    workspace: workspace,
    workspaceSpecified: workspaceSpecified,
  );

  @override
  Future<void> trustWorkspace(String projectId) =>
      _projects.trustWorkspace(projectId);
}

final class _LocalModels implements ModelStore {
  _LocalModels(this._models);

  final dynamic _models;

  @override
  ModelCatalogState get state => _models.state;

  @override
  Stream<ModelCatalogState> watch() => _models.watch();

  @override
  Future<void> refresh() => _models.refresh();

  @override
  Future<void> remember(List<String> ids) => _models.remember(ids);
}

final class _LocalHosts implements HostStore {
  _LocalHosts(this._hosts);

  final dynamic _hosts;

  @override
  Future<List<Host>> all() => _hosts.all();

  @override
  Stream<List<Host>> watchAll() => _hosts.watchAll();
}

final class _LocalExec implements ExecStore {
  _LocalExec(this._registry);

  final dynamic _registry;

  @override
  ActiveExec? find(String runId) => _registry.find(runId);

  @override
  Future<void> stop(ActiveExec exec, {required bool force}) =>
      _registry.stop(exec, force: force);
}

final class _LocalInteractions implements InteractionsStore {
  _LocalInteractions(this._broker);

  final InteractionBroker _broker;

  @override
  Stream<ApprovalRequest> get approvalRequests => _broker.approvalRequests;

  @override
  Stream<UserQuestion> get questions => _broker.questions;

  @override
  Stream<EditFileChangesRequest> get editFileChangesRequests =>
      _broker.editFileChangesRequests;

  @override
  List<ApprovalRequest> pendingApprovals(String chatId) =>
      _broker.pendingApprovals(chatId);

  @override
  List<UserQuestion> pendingQuestions(String chatId) =>
      _broker.pendingQuestions(chatId);

  @override
  List<EditFileChangesRequest> pendingEditFileChanges(String chatId) =>
      _broker.pendingEditFileChanges(chatId);

  @override
  void resolveApproval(String requestId, ApprovalDecision decision) =>
      _broker.resolveApproval(requestId, decision);

  @override
  void answer(String questionId, String? text) =>
      _broker.answer(questionId, text);

  @override
  void resolveEditFileChanges(String requestId, EditFileChangesChoice choice) =>
      _broker.resolveEditFileChanges(requestId, choice);
}

final class _LocalChatSession implements ChatSessionApi {
  _LocalChatSession(this._session);

  final dynamic _session;

  @override
  bool get isRunning => _session.isRunning;

  @override
  List<QueuedPrompt> get queue => _session.queue;

  @override
  Stream<AgentEvent> get events => _session.events;

  @override
  Future<void> submit(
    String text, {
    List<AttachmentRef> attachments = const [],
    bool sendNow = false,
  }) => _session.submit(text, attachments: attachments, sendNow: sendNow);

  @override
  Future<void> stop({String? reason}) => _session.stop(reason: reason);

  @override
  Future<void> continueAfterStepLimit() => _session.continueAfterStepLimit();

  @override
  Future<bool> regenerateLast() => _session.regenerateLast();

  @override
  void promoteQueued(int index) => _session.promoteQueued(index);

  @override
  QueuedPrompt? takeQueued(int index) => _session.takeQueued(index);

  @override
  Future<bool> editUserMessage(
    String messageId,
    String newText, {
    List<AttachmentRef>? attachments,
  }) => _session.editUserMessage(messageId, newText, attachments: attachments);

  @override
  Future<void> deleteAfter(String messageId) => _session.deleteAfter(messageId);

  @override
  Future<void> restoreUnanswered() => _session.restoreUnanswered();

  @override
  Future<void> compactNow({bool force = false}) =>
      _session.compactNow(force: force);
}

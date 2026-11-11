import 'dart:async';

import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/agent/loop/agent_hub.dart';
import 'package:pw_agent/agent/schedule/scheduled_task.dart';
import 'package:pw_agent/agent/schedule/scheduled_task_repository.dart';
import 'package:pw_agent/agent/schedule/task_scheduler.dart';
import 'package:pw_agent/core/domain/host.dart';

/// Локальный [AgentApi]: прямые вызовы [AgentHub], брокера и планировщика.
///
/// Никакого транспорта, сериализации и токенов. Используется встроенным
/// агентом клиента и HTTP-сервером демона.
@LazySingleton(as: AgentApi)
final class LocalAgentApi implements AgentApi {
  LocalAgentApi(this._hub, this._tasks, this._scheduler);

  final AgentHub _hub;
  final ScheduledTaskRepository _tasks;
  final TaskScheduler _scheduler;

  @override
  Stream<AgentEvent> get events => _hub.allEvents;

  @override
  Stream<ApprovalRequest> get approvals => _hub.broker.approvalRequests;

  @override
  Stream<UserQuestion> get questions => _hub.broker.questions;

  @override
  Stream<EditFileChangesRequest> get editChanges =>
      _hub.broker.editFileChangesRequests;

  @override
  Set<String> get runningChatIds => _hub.runningChatIds;

  @override
  Future<List<Host>> hosts() => _hub.hosts.all();

  @override
  Future<List<Chat>> chats() async {
    final all = await _hub.chats.allChats();
    return [
      for (final chat in all)
        if (!chat.isSubagent) chat,
    ];
  }

  @override
  Future<Chat?> chat(String id) => _hub.chats.chat(id);

  @override
  Future<Chat> createChat(String hostId) async {
    if (await _hub.hosts.byId(hostId) == null) {
      throw AgentApiException(404, 'host_not_found', 'host $hostId not found');
    }
    return _hub.newChat(hostId: hostId);
  }

  @override
  Future<List<ChatMessage>> messages(String chatId) async {
    await _requireChat(chatId);
    return _hub.chats.messages(chatId);
  }

  @override
  Future<List<ToolRun>> runs(String chatId) async {
    await _requireChat(chatId);
    return _hub.chats.toolRunsForChat(chatId);
  }

  @override
  Future<void> openChat(String chatId) async {
    await _requireChat(chatId);
    await _hub.session(chatId).restoreUnanswered();
  }

  @override
  Future<void> send(String chatId, String text, {bool sendNow = false}) async {
    await _requireChat(chatId);
    if (text.trim().isEmpty) {
      throw const AgentApiException(400, 'empty_message', 'message is empty');
    }
    await _hub.session(chatId).submit(text, sendNow: sendNow);
  }

  @override
  Future<void> stop(String chatId, {String? reason}) async {
    await _requireChat(chatId);
    await _hub.session(chatId).stop(reason: reason);
  }

  @override
  Future<void> resolveApproval(
    String id,
    ApprovalAction action, {
    String? reason,
  }) async {
    final decision = switch (action) {
      ApprovalAction.deny => ApprovalDecision.deny(reason: reason),
      ApprovalAction.allowOnce => const ApprovalDecision.allowOnce(),
      ApprovalAction.allowTurn => const ApprovalDecision.allowTurn(),
      ApprovalAction.allowChat => const ApprovalDecision.allowChat(),
    };
    _hub.broker.resolveApproval(id, decision);
  }

  @override
  Future<void> answerQuestion(String id, String? text) async {
    _hub.broker.answer(id, text);
  }

  @override
  Future<void> resolveEditFileChanges(
    String id,
    EditFileChangesChoice choice,
  ) async {
    _hub.broker.resolveEditFileChanges(id, choice);
  }

  @override
  Future<List<ApprovalRequest>> pendingApprovals(String chatId) async =>
      _hub.broker.pendingApprovals(chatId);

  @override
  Future<List<UserQuestion>> pendingQuestions(String chatId) async =>
      _hub.broker.pendingQuestions(chatId);

  @override
  Future<List<EditFileChangesRequest>> pendingEditFileChanges(
    String chatId,
  ) async => _hub.broker.pendingEditFileChanges(chatId);

  @override
  Future<List<ScheduledTask>> schedules() => _tasks.all();

  @override
  Future<ScheduledTask?> scheduledTask(String id) => _tasks.byId(id);

  @override
  Future<ScheduledTask> schedule({
    required String chatId,
    required String prompt,
    required DateTime dueAt,
  }) async {
    await _requireChat(chatId);
    if (prompt.trim().isEmpty) {
      throw const AgentApiException(400, 'empty_prompt', 'prompt is empty');
    }
    final task = await _tasks.create(
      chatId: chatId,
      prompt: prompt,
      dueAt: dueAt,
    );
    unawaited(_scheduler.tick());
    return task;
  }

  @override
  Future<void> cancelSchedule(String id) => _tasks.cancel(id);

  Future<void> _requireChat(String id) async {
    if (await _hub.chats.chat(id) == null) {
      throw AgentApiException(404, 'chat_not_found', 'chat $id not found');
    }
  }
}

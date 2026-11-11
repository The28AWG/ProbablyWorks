import 'dart:async';

import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_hub.dart';
import 'package:pw_agent/agent/schedule/scheduled_task.dart';
import 'package:pw_agent/agent/schedule/scheduled_task_repository.dart';
import 'package:pw_agent/agent/schedule/task_scheduler.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_api/src/api_backend.dart';

/// Реализация [ApiBackend] поверх живого [AgentHub].
final class AgentApiBackend implements ApiBackend {
  AgentApiBackend(this._hub, this._tasks, this._scheduler);

  final AgentHub _hub;
  final ScheduledTaskRepository _tasks;
  final TaskScheduler _scheduler;

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
  Future<Chat> createChat(String hostId) => _hub.newChat(hostId: hostId);

  @override
  Future<List<ChatMessage>> messages(String id) => _hub.chats.messages(id);

  @override
  Future<List<ToolRun>> runs(String id) => _hub.chats.toolRunsForChat(id);

  @override
  Future<void> openChat(String id) async {
    await _requireChat(id);
    await _hub.session(id).restoreUnanswered();
  }

  @override
  Future<void> send(String chatId, String text, {bool sendNow = false}) async {
    await _requireChat(chatId);
    if (text.trim().isEmpty) {
      throw const ApiError(400, 'empty_message', 'message text is empty');
    }
    await _hub.session(chatId).submit(text, sendNow: sendNow);
  }

  @override
  Future<void> stop(String chatId) async {
    await _requireChat(chatId);
    await _hub.session(chatId).stop();
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
  List<ApprovalRequest> pendingApprovals(String chatId) =>
      _hub.broker.pendingApprovals(chatId);

  @override
  List<UserQuestion> pendingQuestions(String chatId) =>
      _hub.broker.pendingQuestions(chatId);

  @override
  List<EditFileChangesRequest> pendingEditFileChanges(String chatId) =>
      _hub.broker.pendingEditFileChanges(chatId);

  @override
  Future<List<ScheduledTask>> schedules() => _tasks.all();

  @override
  Future<ScheduledTask> schedule({
    required String chatId,
    required String prompt,
    required DateTime dueAt,
  }) async {
    await _requireChat(chatId);
    if (prompt.trim().isEmpty) {
      throw const ApiError(400, 'empty_prompt', 'prompt is empty');
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

  @override
  Stream<Object> events() {
    final controller = StreamController<Object>();
    final subscriptions = <StreamSubscription<dynamic>>[
      _hub.allEvents.listen(controller.add),
      _hub.broker.approvalRequests.listen(controller.add),
      _hub.broker.questions.listen(controller.add),
      _hub.broker.editFileChangesRequests.listen(controller.add),
    ];
    controller.onCancel = () async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    };
    return controller.stream;
  }

  Future<void> _requireChat(String id) async {
    if (await _hub.chats.chat(id) == null) {
      throw ApiError(404, 'chat_not_found', 'chat $id not found');
    }
  }
}

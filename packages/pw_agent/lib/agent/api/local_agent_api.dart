import 'dart:async';

import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/local_chat_api.dart';
import 'package:pw_agent/agent/schedule/scheduled_task.dart';
import 'package:pw_agent/agent/schedule/scheduled_task_repository.dart';
import 'package:pw_agent/agent/schedule/task_scheduler.dart';

/// Локальный [AgentApi] с расписаниями. Для экрана чата достаточно [LocalChatApi].
@lazySingleton
final class LocalAgentApi extends LocalChatApi implements AgentApi {
  LocalAgentApi(super.hub, this._tasks, this._scheduler);

  final ScheduledTaskRepository _tasks;
  final TaskScheduler _scheduler;

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
    await requireChat(chatId);
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

  @override
  AgentStatus get status => AgentStatus.online;

  @override
  Stream<AgentStatus> get statusChanges => const Stream<AgentStatus>.empty();

  @override
  Future<bool> checkConnection() async => true;
}

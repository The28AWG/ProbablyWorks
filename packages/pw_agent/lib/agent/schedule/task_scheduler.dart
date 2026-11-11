import 'dart:async';

import 'package:injectable/injectable.dart';
import 'package:logging/logging.dart';
import 'package:pw_agent/agent/loop/agent_hub.dart';
import 'package:pw_agent/agent/schedule/scheduled_task_repository.dart';

/// Отправляет созревшие отложенные задачи в их чаты.
///
/// Задача считается выполненной в момент передачи в сессию (`dispatched`):
/// результат хода живёт в журнале чата, а не в очереди расписания.
@lazySingleton
class TaskScheduler {
  TaskScheduler(this._hub, this._tasks);

  final AgentHub _hub;
  final ScheduledTaskRepository _tasks;
  final _log = Logger('TaskScheduler');

  Timer? _timer;
  var _ticking = false;

  /// Проверяет очередь сразу и затем раз в [interval].
  void start({Duration interval = const Duration(seconds: 15)}) {
    _timer?.cancel();
    unawaited(tick());
    _timer = Timer.periodic(interval, (_) => unawaited(tick()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Один проход по очереди. Публичный для тестов и ручного запуска.
  Future<void> tick() async {
    if (_ticking) return;
    _ticking = true;
    try {
      final due = await _tasks.due(DateTime.now());
      for (final task in due) {
        await _tasks.markDispatched(task.id);
        try {
          await _hub.session(task.chatId).submit(task.prompt);
        } on Object catch (error, stack) {
          _log.warning(
            'scheduled task ${task.id} failed: $error',
            error,
            stack,
          );
          await _tasks.markFailed(task.id, '$error');
        }
      }
    } on Object catch (error, stack) {
      _log.warning('scheduler tick failed: $error', error, stack);
    } finally {
      _ticking = false;
    }
  }
}

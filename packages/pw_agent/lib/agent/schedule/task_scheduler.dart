import 'dart:async';

import 'package:injectable/injectable.dart';
import 'package:logging/logging.dart';
import 'package:pw_agent/agent/schedule/scheduled_task.dart';
import 'package:pw_agent/agent/schedule/scheduled_task_repository.dart';
import 'package:pw_agent/core/util/elapsed_format.dart';
import 'package:pw_agent/core/util/short_time.dart';
import 'package:pw_agent/src/agent/loop/agent_hub.dart';

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

  /// С какого опоздания сообщать о нём отдельной заметкой.
  ///
  /// Обычная задержка тика и фонового запуска сюда не попадает: иначе заметка
  /// появлялась бы почти всегда и только мешала. Час — это уже не «через
  /// секунду», напоминание пришло заметно позже, и модель должна это знать,
  /// чтобы не говорить «сегодня», когда речь о прошлой неделе.
  static const lateNoteAfter = Duration(hours: 1);

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

  /// Выключает обновление памяти проекта после ходов этого прогона.
  ///
  /// Нужно фоновому запускателю: он закрывает базу сразу после хода, а
  /// обновление памяти требует сети и времени. Память обновится в следующем
  /// обычном ходе.
  void disableProjectMemoryUpdates() => _hub.memoryUpdatesEnabled = false;

  /// Один проход по очереди. Публичный для тестов и ручного запуска.
  ///
  /// [awaitTurns] — дождаться конца хода. Нужен платформенному запускателю:
  /// в фоновом изоляте управление нельзя возвращать, пока агент не ответил,
  /// иначе систему выгрузит изолят вместе с незавершённым ходом. Демону и
  /// приложению ждать не нужно: они живут дальше.
  Future<void> tick({bool awaitTurns = false}) async {
    if (_ticking) return;
    _ticking = true;
    try {
      final now = DateTime.now();
      final due = await _tasks.due(now);
      for (final task in due) {
        await _tasks.markDispatched(task.id);
        try {
          final session = _hub.session(task.chatId);
          await session.submit(task.prompt, note: _lateNote(task, now));
          if (awaitTurns) await session.whenIdle;
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

  /// Заметка о пропущенном сроке или null, если опоздание обычное.
  ///
  /// Время в заметке — местное и короткое (см. [formatShortTime]): рядом с
  /// длительностью опоздания этого достаточно. Текст английский, как у прочих
  /// событий журнала: он технический и не переводится.
  String? _lateNote(ScheduledTask task, DateTime now) {
    final late = now.difference(task.dueAt);
    if (late <= lateNoteAfter) return null;
    final due = formatShortTime(task.dueAt, now: now);
    return '$scheduledTaskLateNotePrefix'
        '$due, started ${formatElapsed(late)} late';
  }
}

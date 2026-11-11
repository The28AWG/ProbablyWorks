import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/schedule/scheduled_task.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:uuid/uuid.dart';

/// Хранение отложенных задач. Очередь переживает перезапуск демона.
@lazySingleton
class ScheduledTaskRepository {
  ScheduledTaskRepository(this._db);

  final AppDatabase _db;

  static const _uuid = Uuid();

  $ScheduledTasksTable get _table => _db.scheduledTasks;

  Future<List<ScheduledTask>> all() async {
    final rows = await (_db.select(
      _table,
    )..orderBy([(t) => OrderingTerm.asc(t.dueAt)])).get();
    return rows.map(_task).toList();
  }

  /// Задачи, которые пора отправить. Только `pending`: `dispatched` не повторяется.
  Future<List<ScheduledTask>> due(DateTime now) async {
    final rows =
        await (_db.select(_table)
              ..where(
                (t) =>
                    t.status.equals(ScheduledTaskStatus.pending.name) &
                    t.dueAt.isSmallerOrEqualValue(now),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.dueAt)]))
            .get();
    return rows.map(_task).toList();
  }

  Future<ScheduledTask> create({
    required String chatId,
    required String prompt,
    required DateTime dueAt,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    final task = ScheduledTask(
      id: _uuid.v4(),
      chatId: chatId,
      prompt: prompt,
      dueAt: dueAt,
      status: ScheduledTaskStatus.pending,
      createdAt: timestamp,
      updatedAt: timestamp,
    );
    await _db
        .into(_table)
        .insert(
          ScheduledTasksCompanion.insert(
            id: task.id,
            chatId: chatId,
            prompt: prompt,
            dueAt: dueAt,
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
        );
    return task;
  }

  Future<void> markDispatched(String id) =>
      _status(id, ScheduledTaskStatus.dispatched);

  Future<void> markFailed(String id, String error) =>
      _status(id, ScheduledTaskStatus.failed, error: error);

  Future<void> cancel(String id) => _status(id, ScheduledTaskStatus.cancelled);

  Future<void> _status(
    String id,
    ScheduledTaskStatus status, {
    String? error,
  }) => (_db.update(_table)..where((t) => t.id.equals(id))).write(
    ScheduledTasksCompanion(
      status: Value(status.name),
      error: Value(error),
      updatedAt: Value(DateTime.now()),
    ),
  );

  ScheduledTask _task(ScheduledTaskRow row) => ScheduledTask(
    id: row.id,
    chatId: row.chatId,
    prompt: row.prompt,
    dueAt: row.dueAt,
    status: ScheduledTaskStatus.values.byName(row.status),
    error: row.error,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );
}

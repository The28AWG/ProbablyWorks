import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/schedule/scheduled_task.dart';
import 'package:pw_agent/agent/tools/tool_catalog.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:uuid/uuid.dart';

/// Хранение отложенных задач. Очередь переживает перезапуск демона.
@lazySingleton
class ScheduledTaskRepository {
  ScheduledTaskRepository(this._db);

  final AppDatabase _db;

  static const _uuid = Uuid();

  $ScheduledTasksTable get _table => _db.scheduledTasks;

  Future<ScheduledTask?> byId(String id) async {
    final row = await (_db.select(
      _table,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _task(row);
  }

  Future<List<ScheduledTask>> all() async {
    final rows = await (_db.select(
      _table,
    )..orderBy([(t) => OrderingTerm.asc(t.dueAt)])).get();
    return rows.map(_task).toList();
  }

  /// Задачи одного чата по возрастанию времени. Нужны инструменту списка.
  Future<List<ScheduledTask>> forChat(String chatId) async {
    final rows =
        await (_db.select(_table)
              ..where((t) => t.chatId.equals(chatId))
              ..orderBy([(t) => OrderingTerm.asc(t.dueAt)]))
            .get();
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

  /// id задачи, которую поставил шаг журнала, или null.
  ///
  /// Задача принадлежит своему шагу `schedule_task`: обработчик расписания
  /// отвечает строкой `scheduled task <id> at …`, поэтому связь читается из
  /// вывода без отдельной колонки. Удалённый шаг уносит задачу, форк копирует
  /// их вместе.
  static String? taskIdOfRun(ToolRun run) {
    if (run.toolName != ToolNames.scheduleTask) return null;
    return _taskIdInOutput.firstMatch(run.outputText ?? '')?.group(1);
  }

  static final _taskIdInOutput = RegExp(r'scheduled task ([0-9a-fA-F-]+)');

  /// Удаляет задачи, чьи шаги исчезли. Лишний id не ошибка.
  Future<void> deleteByIds(Iterable<String> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    await (_db.delete(_table)..where((t) => t.id.isIn(list))).go();
  }

  /// Копия задачи в другом чате под новым id.
  ///
  /// Время запуска, статус и время создания сохраняются: копия — это перенос,
  /// а не новый отсчёт. По `createdAt` определяется положение задачи без шага
  /// при следующем форке или правке истории.
  Future<ScheduledTask> copyTo(String chatId, ScheduledTask source) async {
    final now = DateTime.now();
    final copy = ScheduledTask(
      id: _uuid.v4(),
      chatId: chatId,
      prompt: source.prompt,
      dueAt: source.dueAt,
      status: source.status,
      error: source.error,
      createdAt: source.createdAt,
      updatedAt: now,
    );
    await _db
        .into(_table)
        .insert(
          ScheduledTasksCompanion.insert(
            id: copy.id,
            chatId: chatId,
            prompt: copy.prompt,
            dueAt: copy.dueAt,
            status: Value(copy.status.name),
            error: Value(copy.error),
            createdAt: copy.createdAt,
            updatedAt: now,
          ),
        );
    return copy;
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

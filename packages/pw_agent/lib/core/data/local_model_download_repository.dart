/// Хранилище активных скачиваний локальных моделей.
///
/// Запись переживает перезапуск процесса: сервис читает её при старте и
/// возобновляет загрузку. Прогресс здесь не хранится — байты уже лежат в
/// `.part` или в задаче платформенного загрузчика.
library;

import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/providers/ai/local_models.dart';

/// Читает и пишет задания на скачивание.
@lazySingleton
class LocalModelDownloadRepository {
  LocalModelDownloadRepository(this._db);

  final AppDatabase _db;

  $LocalModelDownloadsTable get _table => _db.localModelDownloads;

  /// Все незавершённые задания в порядке создания.
  Future<List<LocalModelDownloadJob>> all() async {
    final rows = await (_db.select(
      _table,
    )..orderBy([(table) => OrderingTerm(expression: table.createdAt)])).get();
    return [for (final row in rows) _map(row)];
  }

  /// Создаёт или обновляет задание.
  Future<void> upsert(LocalModelDownloadJob job) => _db
      .into(_table)
      .insertOnConflictUpdate(
        LocalModelDownloadsCompanion.insert(
          id: job.id,
          source: job.source,
          name: job.name,
          sha256: Value(job.sha256),
          createdAt: job.createdAt,
          updatedAt: DateTime.now().toUtc(),
        ),
      );

  /// Удаляет задание после завершения, отмены или ошибки.
  Future<void> delete(String id) =>
      (_db.delete(_table)..where((table) => table.id.equals(id))).go();

  /// Удаляет все задания (очистка кэша).
  Future<void> deleteAll() => _db.delete(_table).go();

  LocalModelDownloadJob _map(LocalModelDownloadRow row) =>
      LocalModelDownloadJob(
        id: row.id,
        source: row.source,
        name: row.name,
        sha256: row.sha256,
        createdAt: row.createdAt,
      );
}

import 'package:drift/drift.dart';
import 'package:probably_works/core/db/tables.dart';

part 'app_database.g.dart';

/// Единая SQLite-база приложения (drift). Миграции — через [schemaVersion].
@DriftDatabase(
  tables: [Hosts, Chats, Messages, ToolRuns, SessionRevisions, KvSettings],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  static const currentSchemaVersion = 2;

  @override
  int get schemaVersion => currentSchemaVersion;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
    onCreate: (m) async {
      await m.createAll();
      await _createSearchIndex();
    },
    onUpgrade: (m, from, to) async {
      // v2: таймаут подключения и результат последней проверки Host.
      if (from < 2) {
        await m.addColumn(hosts, hosts.connectTimeoutSeconds);
        await m.addColumn(hosts, hosts.lastCheckAt);
        await m.addColumn(hosts, hosts.lastLatencyMs);
        await m.addColumn(hosts, hosts.lastCheckError);
      }
    },
  );

  /// FTS5-индекс для chat_history_search. Тело сообщения пишется вручную
  /// в той же транзакции, что и само сообщение.
  Future<void> _createSearchIndex() => customStatement(
    'CREATE VIRTUAL TABLE IF NOT EXISTS message_search USING fts5('
    'message_id UNINDEXED, chat_id UNINDEXED, body)',
  );
}

import 'package:drift/drift.dart';
import 'package:probably_works/core/db/tables.dart';

part 'app_database.g.dart';

/// Единая SQLite-база приложения (drift). Миграции — через [schemaVersion].
@DriftDatabase(
  tables: [
    Hosts,
    Chats,
    Messages,
    ToolRuns,
    SessionRevisions,
    KvSettings,
    SavedModels,
    VirtualFsNodes,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  static const currentSchemaVersion = 9;

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
      // v3 создавал кеш всего каталога моделей; v4 его убирает и хранит только выбранные модели.
      if (from < 4) {
        await customStatement('DROP TABLE IF EXISTS llm_models');
        await m.createTable(savedModels);
      }
      // v5: черновик поля ввода хранится в записи чата.
      if (from < 5) {
        await m.addColumn(chats, chats.draft);
        await m.addColumn(chats, chats.draftAttachments);
      }
      // v6: входные модальности выбранных моделей (вложения-файлы). Таблица из v2–v3 создаётся сразу с колонкой.
      if (from >= 4 && from < 6) {
        await m.addColumn(savedModels, savedModels.inputModalities);
      }
      // Версия 7: файлы виртуального Host. Индекс по родителю создаётся отдельно: createTable его не делает.
      if (from < 7) {
        await m.createTable(virtualFsNodes);
        await m.createIndex(virtualFsNodesParent);
      }
      // Версия 8: /tmp больше не хранится. Диапазон по ключу, как листинг: «/tmp/» … «/tmp0».
      if (from < 8) {
        await customStatement(
          "DELETE FROM virtual_fs_nodes WHERE path = '/tmp' "
          "OR (path >= '/tmp/' AND path < '/tmp0')",
        );
      }
      // Версия 9: связь запуска с вызовом модели и текст карточки подтверждения.
      // Без них после перезапуска нельзя снова показать ту же карточку.
      if (from < 9) {
        await m.addColumn(toolRuns, toolRuns.toolCallId);
        await m.addColumn(toolRuns, toolRuns.pendingCard);
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

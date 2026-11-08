import 'package:drift/drift.dart';
import 'package:probably_works/core/db/tables.dart';
import 'package:probably_works/core/util/workspace_path.dart';
import 'package:uuid/uuid.dart';

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
    Projects,
    ProjectSkills,
    ProjectFacts,
    PolicyProfiles,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  static const currentSchemaVersion = 10;

  static const _uuid = Uuid();

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
      // Версия 10: проекты. Чат всегда принадлежит проекту; у проекта свои факты, skills и профиль политики.
      if (from < 10) {
        await m.createTable(policyProfiles);
        await m.createTable(projects);
        await m.createTable(projectSkills);
        await m.createTable(projectFacts);
        await m.addColumn(chats, chats.projectId);
        await m.createIndex(projectsHostKey);
        await m.createIndex(projectFactsProject);
        await m.createIndex(chatsProject);
        await _backfillProjects();
      }
    },
  );

  /// Создаёт проекты для чатов, которые появились до v10, и проставляет им `project_id`.
  ///
  /// Пути приводятся к лексической форме: `~` на удалённом хосте раскрывается при первом
  /// подключении, а до него остаётся стабильным ключом. Доверие к папке из kv-настроек
  /// переносится в `projects.trust_agents_md`.
  Future<void> _backfillProjects() async {
    // В очень старых тестовых базах таблицы hosts может не быть: тогда папка хоста
    // по умолчанию неизвестна и берётся `~`. В рабочей базе hosts есть всегда.
    final hasHosts = (await customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'hosts'",
    ).get()).isNotEmpty;
    final rows = await customSelect(
      hasHosts
          ? 'SELECT c.id AS chat_id, c.host_id AS host_id, c.workspace AS workspace, '
                'h.default_workspace AS default_workspace, h.os_family AS os_family '
                'FROM chats c LEFT JOIN hosts h ON h.id = c.host_id'
          : 'SELECT id AS chat_id, host_id, workspace, '
                'NULL AS default_workspace, NULL AS os_family FROM chats',
    ).get();
    final ids = <String, String>{};
    final now = DateTime.now();
    for (final row in rows) {
      final hostId = row.read<String>('host_id');
      final workspace =
          row.read<String?>('workspace') ??
          row.read<String?>('default_workspace') ??
          '~';
      final windows = row.read<String?>('os_family') == 'windows';
      final key = normalizeWorkspacePath(workspace, windows: windows);
      final mapKey = '$hostId\u0000$key';
      var projectId = ids[mapKey];
      if (projectId == null) {
        projectId = _uuid.v4();
        ids[mapKey] = projectId;
        await customStatement(
          'INSERT INTO projects (id, host_id, name, workspace, workspace_key, '
          'trust_agents_md, skills_initialized, created_at, updated_at) '
          'VALUES (?, ?, ?, ?, ?, 0, 0, ?, ?)',
          [
            projectId,
            hostId,
            projectNameFor(workspace),
            workspace,
            key,
            now.millisecondsSinceEpoch ~/ 1000,
            now.millisecondsSinceEpoch ~/ 1000,
          ],
        );
      }
      await customStatement(
        'UPDATE chats SET project_id = ?, workspace = ? WHERE id = ?',
        [projectId, workspace, row.read<String>('chat_id')],
      );
    }
    // Старое доверие к папке относилось к AGENTS.md: skills в проекте получают его отдельно.
    final hasSettings = (await customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name = 'kv_settings'",
    ).get()).isNotEmpty;
    if (!hasSettings) return;
    final trusts = await customSelect(
      "SELECT key FROM kv_settings WHERE key LIKE 'trust:%'",
    ).get();
    for (final row in trusts) {
      final raw = row.read<String>('key').replaceFirst('trust:', '');
      final split = raw.indexOf(':');
      if (split <= 0) continue;
      final segments = raw.split(':');
      if (segments.length < 2) continue;
      final hostId = segments.first;
      final workspace = segments.sublist(1).join(':');
      await customStatement(
        'UPDATE projects SET trust_agents_md = 1 '
        'WHERE host_id = ? AND workspace = ?',
        [hostId, workspace],
      );
    }
  }

  /// FTS5-индекс для chat_history_search. Тело сообщения пишется вручную
  /// в той же транзакции, что и само сообщение.
  Future<void> _createSearchIndex() => customStatement(
    'CREATE VIRTUAL TABLE IF NOT EXISTS message_search USING fts5('
    'message_id UNINDEXED, chat_id UNINDEXED, body)',
  );
}

import 'package:drift/drift.dart';
import 'package:pw_agent/core/db/tables.dart';
import 'package:pw_agent/core/util/home_path.dart';
import 'package:pw_agent/core/util/workspace_path.dart';
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
    McpServers,
    ScheduledTasks,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  static const currentSchemaVersion = 15;

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
      await _createScheduledTasksIndex();
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
      // Версия 11: чаты без явной папки больше не делят домашний проект.
      // Факты такого проекта остаются в архиве до обычной недели удаления.
      if (from < 11) await _detachImplicitHomeProjects();
      // Версия 12: неотправленная правка сообщения хранится рядом с черновиком поля ввода.
      if (from < 12) await m.addColumn(chats, chats.messageEdits);
      // Версия 13: настройки подключения MCP-серверов.
      if (from < 13) await m.createTable(mcpServers);
      // Версия 14: скрытые чаты субагентов и их связь с root-чатом.
      if (from < 14) {
        await m.addColumn(chats, chats.kind);
        await m.addColumn(chats, chats.parentChatId);
        await m.addColumn(chats, chats.rootChatId);
        await m.addColumn(chats, chats.depth);
      }
      // Версия 15: отложенные задачи демона.
      if (from < 15) {
        await m.createTable(scheduledTasks);
        await _createScheduledTasksIndex();
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

  /// Отвязывает чаты, которым папку подставил неявный дом.
  ///
  /// Папка хоста по умолчанию остаётся проектом: её задал пользователь. `~` и
  /// домашний каталог этой машины — нет, если хост свою папку не задаёт. Чат,
  /// который сознательно работает в доме, выбирает эту папку снова или ставит
  /// её папкой хоста: архивный проект с фактами ещё неделю можно открыть.
  Future<void> _detachImplicitHomeProjects() async {
    final hasHosts = (await customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'hosts'",
    ).get()).isNotEmpty;
    final home = expandHomePath('~');
    final rows = await customSelect(
      hasHosts
          ? 'SELECT c.id AS chat_id, c.project_id AS project_id, '
                'c.workspace AS workspace, h.default_workspace AS default_workspace '
                'FROM chats c LEFT JOIN hosts h ON h.id = c.host_id'
          : 'SELECT id AS chat_id, project_id, workspace, '
                'NULL AS default_workspace FROM chats',
    ).get();
    final touched = <String>{};
    for (final row in rows) {
      final configured = row.read<String?>('default_workspace')?.trim();
      if (configured != null && configured.isNotEmpty) continue;
      if (!_implicitHomeWorkspace(row.read<String?>('workspace'), home)) {
        continue;
      }
      final projectId = row.read<String?>('project_id');
      if (projectId != null) touched.add(projectId);
      await (update(
        chats,
      )..where((table) => table.id.equals(row.read<String>('chat_id')))).write(
        const ChatsCompanion(projectId: Value(null), workspace: Value(null)),
      );
    }
    final now = DateTime.now();
    for (final projectId in touched) {
      final count = chats.id.count();
      final row =
          await (selectOnly(chats)
                ..addColumns([count])
                ..where(chats.projectId.equals(projectId)))
              .getSingle();
      if ((row.read(count) ?? 0) > 0) continue;
      final project = await (select(
        projects,
      )..where((table) => table.id.equals(projectId))).getSingleOrNull();
      if (project == null || project.archivedAt != null) continue;
      await (update(projects)..where((table) => table.id.equals(projectId)))
          .write(ProjectsCompanion(archivedAt: Value(now)));
    }
  }

  /// Пустая папка, `~` и раскрытый дом этой машины. Хвостовой разделитель не считается другой папкой.
  bool _implicitHomeWorkspace(String? workspace, String home) {
    final value = _trimTrailingSlash(workspace);
    if (value == null || value == '~') return true;
    final expanded = _trimTrailingSlash(home);
    return expanded != null && expanded != '~' && value == expanded;
  }

  String? _trimTrailingSlash(String? path) {
    final value = path?.trim();
    if (value == null || value.isEmpty) return null;
    if (value.length > 1 && (value.endsWith('/') || value.endsWith(r'\'))) {
      return value.replaceFirst(RegExp(r'[/\\]$'), '');
    }
    return value;
  }

  /// FTS5-индекс для chat_history_search. Тело сообщения пишется вручную
  /// в той же транзакции, что и само сообщение.
  Future<void> _createScheduledTasksIndex() => customStatement(
    'CREATE INDEX IF NOT EXISTS scheduled_tasks_due '
    'ON scheduled_tasks(status, due_at)',
  );

  Future<void> _createSearchIndex() => customStatement(
    'CREATE VIRTUAL TABLE IF NOT EXISTS message_search USING fts5('
    'message_id UNINDEXED, chat_id UNINDEXED, body)',
  );
}

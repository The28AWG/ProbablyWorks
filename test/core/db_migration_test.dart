import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/db/app_database.dart';

/// Таблица chats в форме схемы v4: её есть в каждой базе старше v5.
const _chatsV4 =
    'CREATE TABLE chats ('
    'id TEXT NOT NULL PRIMARY KEY, host_id TEXT NOT NULL, '
    "title TEXT NOT NULL, title_source TEXT NOT NULL DEFAULT 'none', "
    'model TEXT, policy_mode TEXT NOT NULL DEFAULT \'ask\', workspace TEXT, '
    'last_prompt_tokens INTEGER, last_completion_tokens INTEGER, '
    'context_length INTEGER, compaction_summary TEXT, '
    'compacted_until_seq INTEGER NOT NULL DEFAULT 0, '
    'current_revision_id TEXT, created_at INTEGER NOT NULL, '
    'updated_at INTEGER NOT NULL)';

/// Таблица файлов виртуального Host в форме схемы v7, без внешнего ключа: в этом тесте нет таблицы hosts.
const _virtualFsV7 =
    'CREATE TABLE virtual_fs_nodes ('
    'host_id TEXT NOT NULL, path TEXT NOT NULL, parent_path TEXT NOT NULL, '
    'kind TEXT NOT NULL, mode INTEGER NOT NULL, mtime INTEGER NOT NULL, '
    'size INTEGER NOT NULL, target TEXT, content BLOB, '
    'PRIMARY KEY (host_id, path))';

/// Таблица tool_runs до версии 9: без связи с вызовом модели и без текста карточки.
const _toolRunsBeforeV9 =
    'CREATE TABLE tool_runs ('
    'id TEXT NOT NULL PRIMARY KEY, chat_id TEXT NOT NULL, '
    'message_id TEXT NOT NULL, tool_name TEXT NOT NULL, args_json TEXT NOT NULL, '
    'command TEXT, background INTEGER NOT NULL DEFAULT 0, pid INTEGER, '
    'status TEXT NOT NULL, exit_code INTEGER, timed_out INTEGER NOT NULL DEFAULT 0, '
    'log_path TEXT, output_text TEXT, output_truncated INTEGER NOT NULL DEFAULT 0, '
    'result_preview TEXT, started_at INTEGER NOT NULL, finished_at INTEGER)';

/// Таблица saved_models в форме схемы v4 (без входных модальностей).
const _savedModelsV4 =
    'CREATE TABLE saved_models ('
    'id TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL, '
    'context_length INTEGER, supports_tools INTEGER NOT NULL DEFAULT 0)';

/// Открывает базу, созданную предыдущей версией схемы, и даёт миграции поработать.
AppDatabase _openAtVersion(
  int version, {
  bool withLlmModels = false,
  bool withVirtualFs = false,
}) => AppDatabase(
  NativeDatabase.memory(
    setup: (raw) {
      if (withLlmModels) {
        raw.execute(
          'CREATE TABLE llm_models ('
          'id TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL, '
          'context_length INTEGER, supports_tools INTEGER NOT NULL DEFAULT 0, '
          'prompt_price TEXT, completion_price TEXT, created INTEGER, '
          'available INTEGER NOT NULL DEFAULT 1, synced_at INTEGER NOT NULL)',
        );
      }
      raw
        ..execute(_chatsV4)
        ..execute(_toolRunsBeforeV9)
        ..execute('PRAGMA user_version = $version');
      if (version >= 4) raw.execute(_savedModelsV4);
      if (withVirtualFs) {
        raw
          ..execute(_virtualFsV7)
          ..execute(
            'INSERT INTO virtual_fs_nodes ('
            'host_id, path, parent_path, kind, mode, mtime, size) VALUES '
            "('h', '/tmp', '/', 'dir', 1023, 0, 0), "
            "('h', '/tmp/a', '/tmp', 'file', 420, 0, 4), "
            "('h', '/home/agent/n', '/home/agent', 'file', 420, 0, 1)",
          );
      }
    },
  ),
);

/// База v9 с хостами, чатами и старым ключом доверия к папке.
AppDatabase _openProjectsV9() => AppDatabase(
  NativeDatabase.memory(
    setup: (raw) {
      raw
        ..execute(
          'CREATE TABLE hosts ('
          'id TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL, '
          'address TEXT, port INTEGER NOT NULL DEFAULT 22, username TEXT, '
          "auth_type TEXT NOT NULL DEFAULT 'key', key_path TEXT, "
          'host_key_fingerprint TEXT, os_family TEXT NOT NULL DEFAULT '
          "'posix', default_workspace TEXT, shell_override TEXT, notes TEXT, "
          'connect_timeout_seconds INTEGER, last_check_at INTEGER, '
          'last_latency_ms INTEGER, last_check_error TEXT, '
          'created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)',
        )
        ..execute(_chatsV4)
        ..execute(_toolRunsBeforeV9)
        ..execute(_savedModelsV4)
        ..execute(
          'CREATE TABLE kv_settings (key TEXT NOT NULL PRIMARY KEY, value TEXT)',
        )
        ..execute(
          'INSERT INTO hosts (id, name, kind, os_family, default_workspace, '
          'created_at, updated_at) VALUES '
          "('local', 'local', 'local', 'posix', '/home/user', 0, 0)",
        )
        ..execute(
          'INSERT INTO chats (id, host_id, title, created_at, updated_at) '
          "VALUES ('c1', 'local', 'one', 0, 0), "
          "('c2', 'local', 'two', 0, 0), "
          "('c3', 'local', 'three', 0, 0), "
          "('c4', 'local', 'four', 0, 0)",
        )
        ..execute(
          "UPDATE chats SET workspace = '~/repo' WHERE id IN ('c1', 'c2')",
        )
        ..execute("UPDATE chats SET workspace = '/srv/app/' WHERE id = 'c3'")
        ..execute(
          "INSERT INTO kv_settings (key, value) VALUES ('trust:local:~/repo', '1')",
        )
        ..execute('PRAGMA user_version = 9');
    },
  ),
);

void main() {
  test(
    'v3 → v4 drops the full catalog cache and creates saved models',
    () async {
      final db = _openAtVersion(3, withLlmModels: true);
      addTearDown(db.close);

      final tables = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name IN ('llm_models', 'saved_models')",
          )
          .map((row) => row.read<String>('name'))
          .get();
      expect(tables, ['saved_models']);

      final savedModels = db.savedModels;
      await db
          .into(savedModels)
          .insert(
            const SavedModelsCompanion(id: Value('a/x'), name: Value('Saved')),
          );
      expect((await db.select(savedModels).get()).single.name, 'Saved');
    },
  );

  test('v2 → v4 creates saved models without a catalog table', () async {
    final db = _openAtVersion(2);
    addTearDown(db.close);

    final savedModels = db.savedModels;
    final rows = await db.select(savedModels).get();
    expect(rows, isEmpty);
    expect(AppDatabase.currentSchemaVersion, 10);
  });

  test(
    'v4 → v5 adds the chat draft columns to an existing chats table',
    () async {
      final db = _openAtVersion(4);
      addTearDown(db.close);

      final columns = await db
          .customSelect(
            "SELECT name, dflt_value FROM pragma_table_info('chats') "
            "WHERE name IN ('draft', 'draft_attachments')",
          )
          .map((row) => row.read<String>('name'))
          .get();
      expect(columns, containsAll(['draft', 'draft_attachments']));
    },
  );

  test(
    'v6 → v7 creates virtual filesystem nodes with a parent index',
    () async {
      final db = _openAtVersion(6);
      addTearDown(db.close);

      final objects = await db
          .customSelect(
            'SELECT name FROM sqlite_master WHERE name IN '
            "('virtual_fs_nodes', 'virtual_fs_nodes_parent')",
          )
          .map((row) => row.read<String>('name'))
          .get();
      expect(
        objects,
        containsAll(['virtual_fs_nodes', 'virtual_fs_nodes_parent']),
      );
    },
  );

  test('v5 → v6 adds input modalities to saved models', () async {
    final db = _openAtVersion(5);
    addTearDown(db.close);

    final columns = await db
        .customSelect(
          "SELECT name FROM pragma_table_info('saved_models') "
          "WHERE name = 'input_modalities'",
        )
        .map((row) => row.read<String>('name'))
        .get();
    expect(columns, ['input_modalities']);
  });

  test('v7 → v8 removes persisted /tmp and keeps the home file', () async {
    final db = _openAtVersion(7, withVirtualFs: true);
    addTearDown(db.close);

    final paths = await db
        .customSelect('SELECT path FROM virtual_fs_nodes ORDER BY path')
        .map((row) => row.read<String>('path'))
        .get();
    expect(paths, ['/home/agent/n']);
  });

  test('v8 → v9 adds the tool call link and the pending card', () async {
    final db = _openAtVersion(8);
    addTearDown(db.close);

    final columns = await db
        .customSelect(
          "SELECT name FROM pragma_table_info('tool_runs') "
          "WHERE name IN ('tool_call_id', 'pending_card')",
        )
        .map((row) => row.read<String>('name'))
        .get();
    expect(columns, containsAll(['tool_call_id', 'pending_card']));
  });

  test('v9 → v10 creates one project per host and workspace', () async {
    final db = _openProjectsV9();
    addTearDown(db.close);

    final projects = await db
        .customSelect(
          'SELECT id, host_id, workspace, workspace_key, trust_agents_md '
          'FROM projects',
        )
        .get();
    // `~/repo` и `/srv/app/` нормализуются, а чат без папки получает папку хоста.
    final byKey = {
      for (final row in projects) row.read<String>('workspace_key'): row,
    };
    expect(byKey.keys, containsAll(['~/repo', '/srv/app', '/home/user']));
    expect(byKey, hasLength(3));
    expect(byKey['~/repo']!.read<int>('trust_agents_md'), 1);
    expect(byKey['/srv/app']!.read<int>('trust_agents_md'), 0);

    final chatProjects = await db
        .customSelect('SELECT id, project_id, workspace FROM chats ORDER BY id')
        .get();
    expect(chatProjects, hasLength(4));
    expect({
      for (final row in chatProjects) row.read<String?>('project_id'),
    }, hasLength(3));
    expect(chatProjects.first.read<String?>('project_id'), isNot(null));
    expect(chatProjects.last.read<String?>('project_id'), isNot(null));
    expect(
      chatProjects.last.read<String?>('workspace'),
      '/home/user',
      reason: 'чат без папки получает папку хоста по умолчанию',
    );
  });
}

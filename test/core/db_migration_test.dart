import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/util/home_path.dart';
import 'package:pw_agent/core/util/workspace_path.dart';

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

/// База v16 с проектом и старыми фактами: проверяет сворачивание в саммари.
AppDatabase _openFactsV16() => AppDatabase(
  NativeDatabase.memory(
    setup: (raw) {
      raw
        ..execute(_chatsV4)
        ..execute(_toolRunsBeforeV9)
        ..execute(_savedModelsV4)
        ..execute(
          'CREATE TABLE projects ('
          'id TEXT NOT NULL PRIMARY KEY, host_id TEXT NOT NULL, '
          'name TEXT NOT NULL, workspace TEXT NOT NULL, '
          'workspace_key TEXT NOT NULL, policy_profile_id TEXT, '
          'trust_agents_md INTEGER NOT NULL DEFAULT 0, '
          'skills_initialized INTEGER NOT NULL DEFAULT 0, archived_at INTEGER, '
          'created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)',
        )
        ..execute(
          'CREATE TABLE project_facts ('
          'id TEXT NOT NULL PRIMARY KEY, project_id TEXT NOT NULL '
          'REFERENCES projects(id) ON DELETE CASCADE, '
          'content TEXT NOT NULL, created_at INTEGER NOT NULL)',
        )
        ..execute(
          'INSERT INTO projects (id, host_id, name, workspace, workspace_key, '
          "created_at, updated_at) VALUES ('p1', 'local', 'app', '/srv/app', "
          "'/srv/app', 0, 0)",
        )
        ..execute(
          'INSERT INTO project_facts (id, project_id, content, created_at) VALUES '
          "('f1', 'p1', 'собирается через pnpm', 0), "
          "('f2', 'p1', 'CI использует bash', 1)",
        )
        ..execute('PRAGMA user_version = 16');
    },
  ),
);

/// База v26 с общими редактируемыми сущностями без ревизий.
AppDatabase _openSharedV26() => AppDatabase(
  NativeDatabase.memory(
    setup: (raw) {
      raw
        ..execute(
          'CREATE TABLE hosts ('
          'id TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL, '
          "kind TEXT NOT NULL, auth_type TEXT NOT NULL DEFAULT 'key', "
          "os_family TEXT NOT NULL DEFAULT 'posix', "
          'created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)',
        )
        ..execute(
          'CREATE TABLE projects ('
          'id TEXT NOT NULL PRIMARY KEY, host_id TEXT NOT NULL, '
          'name TEXT NOT NULL, workspace TEXT NOT NULL, '
          'workspace_key TEXT NOT NULL, '
          'created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)',
        )
        ..execute(
          'CREATE TABLE mcp_servers ('
          'id TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL, '
          'transport TEXT NOT NULL, source TEXT NOT NULL, '
          'enabled INTEGER NOT NULL DEFAULT 1, config_json TEXT NOT NULL, '
          'created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)',
        )
        ..execute('PRAGMA user_version = 26');
    },
  ),
);

/// База v17 с сообщениями и (опционально) старым FTS-индексом.
AppDatabase _openSearchV17({bool withIndex = true}) => AppDatabase(
  NativeDatabase.memory(
    setup: (raw) {
      raw
        ..execute(
          'CREATE TABLE messages ('
          'id TEXT NOT NULL PRIMARY KEY, chat_id TEXT NOT NULL, '
          'seq INTEGER NOT NULL, role TEXT NOT NULL, payload TEXT NOT NULL, '
          'opened_revision_id TEXT, sealed_before_revision_id TEXT, '
          'created_at INTEGER NOT NULL)',
        )
        ..execute(
          'INSERT INTO messages '
          '(id, chat_id, seq, role, payload, created_at) VALUES '
          "('m1', 'c1', 1, 'user', '{\"text\":\"alpha solution\"}', 0), "
          "('m2', 'c1', 2, 'assistant', '{\"text\":\"\"}', 0)",
        )
        ..execute('PRAGMA user_version = 17');
      if (withIndex) {
        raw
          ..execute(
            'CREATE VIRTUAL TABLE message_search USING fts5('
            'message_id UNINDEXED, chat_id UNINDEXED, body)',
          )
          ..execute(
            'INSERT INTO message_search(message_id, chat_id, body) VALUES '
            "('gone', 'c-old', 'orphan')",
          );
      }
    },
  ),
);

/// Открывает базу, созданную предыдущей версией схемы, и даёт миграции поработать.
AppDatabase _openAtVersion(
  int version, {
  bool withLlmModels = false,
  bool withVirtualFs = false,
  bool withMessages = false,
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
      if (withMessages) {
        raw.execute(
          'CREATE TABLE messages ('
          'id TEXT NOT NULL PRIMARY KEY, '
          'chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE, '
          'seq INTEGER NOT NULL, role TEXT NOT NULL, payload TEXT NOT NULL, '
          'opened_revision_id TEXT, sealed_before_revision_id TEXT, '
          'created_at INTEGER NOT NULL, UNIQUE(chat_id, seq))',
        );
      }
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

/// База v21 с двумя старыми сбоями: у команды ненулевой код выхода,
/// у вызова кода нет. Миграция должна различить результат и сбой вызова.
AppDatabase _openToolRunsV21() => AppDatabase(
  NativeDatabase.memory(
    setup: (raw) {
      raw
        ..execute(_toolRunsBeforeV9)
        ..execute(
          'INSERT INTO tool_runs (id, chat_id, message_id, tool_name, '
          'args_json, status, exit_code, started_at) VALUES '
          "('command', 'c', 'm', 'run_command', '{}', 'failed', 2, 0), "
          "('dispatch', 'c', 'm', 'run_command', '{}', 'failed', NULL, 1)",
        )
        ..execute('PRAGMA user_version = 21');
    },
  ),
);

/// База v18 с чатом и сохранённой моделью: проверяет миграцию reasoning.
AppDatabase _openReasoningV18() => AppDatabase(
  NativeDatabase.memory(
    setup: (raw) {
      raw
        ..execute(_chatsV4)
        ..execute(_savedModelsV4)
        ..execute(
          'INSERT INTO chats (id, host_id, title, created_at, updated_at) '
          "VALUES ('c1', 'local', 'chat', 0, 0)",
        )
        ..execute(
          "INSERT INTO saved_models (id, name) VALUES ('openai/gpt-4o', 'GPT-4o')",
        )
        ..execute('PRAGMA user_version = 18');
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

/// База v9: чаты без папки, чат в `~` и чат в раскрытом доме на хосте без своей папки.
AppDatabase _openImplicitHomeV9() {
  final home = expandHomePath('~').replaceAll("'", "''");
  return AppDatabase(
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
            'INSERT INTO hosts (id, name, kind, os_family, created_at, updated_at) '
            "VALUES ('plain', 'plain', 'local', 'posix', 0, 0), "
            "('configured', 'configured', 'ssh', 'posix', 0, 0)",
          )
          ..execute(
            "UPDATE hosts SET default_workspace = '/opt/app' WHERE id = 'configured'",
          )
          ..execute(
            'INSERT INTO chats (id, host_id, title, created_at, updated_at) VALUES '
            "('tilde', 'plain', 'tilde', 0, 0), "
            "('expanded', 'plain', 'expanded', 0, 0), "
            "('kept', 'plain', 'kept', 0, 0), "
            "('explicit-tilde', 'configured', 'explicit', 0, 0), "
            "('opted', 'configured', 'opted', 0, 0)",
          )
          ..execute("UPDATE chats SET workspace = '~' WHERE id = 'tilde'")
          ..execute(
            "UPDATE chats SET workspace = '$home' WHERE id = 'expanded'",
          )
          ..execute(
            "UPDATE chats SET workspace = '/srv/keep' WHERE id = 'kept'",
          )
          ..execute(
            "UPDATE chats SET workspace = '~' WHERE id = 'explicit-tilde'",
          )
          ..execute('PRAGMA user_version = 9');
      },
    ),
  );
}

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

    final tables = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name IN ('llm_models', 'saved_models')",
        )
        .map((row) => row.read<String>('name'))
        .get();
    expect(tables, ['saved_models']);
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

  test('v11 → v12 adds message edits to an existing chats table', () async {
    final db = _openAtVersion(11);
    addTearDown(db.close);

    final columns = await db
        .customSelect(
          "SELECT name, dflt_value FROM pragma_table_info('chats') "
          "WHERE name = 'message_edits'",
        )
        .map((row) => row.read<String>('name'))
        .get();
    expect(columns, ['message_edits']);
  });

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

  test('v12 → v13 creates the MCP servers table', () async {
    final db = _openAtVersion(12);
    addTearDown(db.close);

    final columns = await db
        .customSelect('PRAGMA table_info(mcp_servers)')
        .get();
    expect(
      columns.map((row) => row.read<String>('name')),
      containsAll([
        'id',
        'name',
        'transport',
        'source',
        'external_key',
        'enabled',
        'config_json',
        'created_at',
        'updated_at',
      ]),
    );
  });

  test('v13 → v14 adds subagent chat metadata', () async {
    final db = _openAtVersion(13);
    addTearDown(db.close);

    final columns = await db.customSelect('PRAGMA table_info(chats)').get();
    expect(
      columns.map((row) => row.read<String>('name')),
      containsAll(['kind', 'parent_chat_id', 'root_chat_id', 'depth']),
    );
  });

  test('v16 → v17 folds facts into one project memory summary', () async {
    final db = _openFactsV16();
    addTearDown(db.close);

    final memory = await db
        .customSelect('SELECT project_id, summary FROM project_memories')
        .getSingle();
    expect(memory.read<String>('project_id'), 'p1');
    expect(memory.read<String>('summary'), contains('pnpm'));
    expect(memory.read<String>('summary'), contains('bash'));

    final tables = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name IN ('project_facts', 'project_memories')",
        )
        .map((row) => row.read<String>('name'))
        .get();
    expect(tables, ['project_memories']);
  });

  test('v17 → v18 rebuilds FTS and removes orphan rows', () async {
    final db = _openSearchV17();
    addTearDown(db.close);

    final rows = await db
        .customSelect(
          'SELECT message_id, chat_id, body FROM message_search '
          'ORDER BY message_id',
        )
        .get();

    expect(rows, hasLength(1));
    expect(rows.single.read<String>('message_id'), 'm1');
    expect(rows.single.read<String>('chat_id'), 'c1');
    expect(rows.single.read<String>('body'), 'alpha solution');
  });

  test('v17 → v18 creates FTS when the old database had no index', () async {
    final db = _openSearchV17(withIndex: false);
    addTearDown(db.close);

    final rows = await db
        .customSelect('SELECT message_id FROM message_search')
        .get();

    expect(rows.map((row) => row.read<String>('message_id')), ['m1']);
  });

  test('v18 → v19 adds reasoning to chats and saved models', () async {
    final db = _openReasoningV18();
    addTearDown(db.close);

    final chatColumns = await db
        .customSelect('PRAGMA table_info(chats)')
        .map((row) => row.read<String>('name'))
        .get();
    expect(chatColumns, contains('reasoning'));

    final chat = await db
        .customSelect("SELECT reasoning FROM chats WHERE id = 'c1'")
        .getSingle();
    expect(chat.read<String>('reasoning'), 'inherit');

    final savedColumns = await db
        .customSelect('PRAGMA table_info(saved_models)')
        .map((row) => row.read<String>('name'))
        .get();
    expect(savedColumns, contains('reasoning_json'));

    final saved = await db
        .customSelect(
          "SELECT reasoning_json FROM saved_models WHERE id = 'openai/gpt-4o'",
        )
        .getSingle();
    expect(saved.readNullable<String>('reasoning_json'), null);
  });

  test('v15 → v16 adds the draft revision column', () async {
    final db = _openAtVersion(15);
    addTearDown(db.close);

    final columns = await db
        .customSelect('PRAGMA table_info(chats)')
        .map((row) => row.read<String>('name'))
        .get();

    expect(columns, contains('draft_revision'));
  });

  test('v19 → v20 creates local model files and index', () async {
    final db = _openAtVersion(19);
    addTearDown(db.close);

    final columns = await db
        .customSelect('PRAGMA table_info(local_models)')
        .map((row) => row.read<String>('name'))
        .get();
    expect(
      columns,
      containsAll([
        'id',
        'name',
        'source',
        'source_kind',
        'cache_key',
        'size_bytes',
        'sha256',
        'settings_json',
        'created_at',
        'last_used_at',
      ]),
    );
    final indexes = await db
        .customSelect('PRAGMA index_list(local_models)')
        .map((row) => row.read<String>('name'))
        .get();
    expect(indexes, contains('local_models_source'));
  });

  test('v20 → v21 creates local model download jobs', () async {
    final db = _openAtVersion(20);
    addTearDown(db.close);

    final columns = await db
        .customSelect('PRAGMA table_info(local_model_downloads)')
        .map((row) => row.read<String>('name'))
        .get();
    expect(
      columns,
      containsAll([
        'id',
        'source',
        'name',
        'sha256',
        'created_at',
        'updated_at',
      ]),
    );
  });

  test('v14 → v15 creates scheduled tasks table and index', () async {
    final db = _openAtVersion(14);
    addTearDown(db.close);

    final columns = await db
        .customSelect('PRAGMA table_info(scheduled_tasks)')
        .get();
    expect(
      columns.map((row) => row.read<String>('name')),
      containsAll([
        'id',
        'chat_id',
        'prompt',
        'due_at',
        'status',
        'error',
        'created_at',
        'updated_at',
      ]),
    );
    final indexes = await db
        .customSelect('PRAGMA index_list(scheduled_tasks)')
        .get();
    expect(
      indexes.map((row) => row.read<String>('name')),
      contains('scheduled_tasks_due'),
    );
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

  test('v10 → v11 detaches chats that only had the implicit home', () async {
    final db = _openImplicitHomeV9();
    addTearDown(db.close);

    final chats = await db
        .customSelect('SELECT id, project_id, workspace FROM chats ORDER BY id')
        .get();
    final byId = {for (final row in chats) row.read<String>('id'): row};
    expect(byId['tilde']!.read<String?>('project_id'), null);
    expect(byId['tilde']!.read<String?>('workspace'), null);
    expect(byId['expanded']!.read<String?>('project_id'), null);
    expect(byId['expanded']!.read<String?>('workspace'), null);
    expect(byId['kept']!.read<String?>('project_id'), isNot(null));
    expect(byId['kept']!.read<String?>('workspace'), '/srv/keep');
    expect(byId['explicit-tilde']!.read<String?>('workspace'), '~');
    expect(byId['explicit-tilde']!.read<String?>('project_id'), isNot(null));
    expect(byId['opted']!.read<String?>('workspace'), '/opt/app');
    expect(byId['opted']!.read<String?>('project_id'), isNot(null));

    final homeKey = normalizeWorkspacePath(expandHomePath('~'), windows: false);
    final archived = await db
        .customSelect(
          'SELECT workspace_key, archived_at FROM projects '
          "WHERE host_id = 'plain' AND workspace_key IN ('~', ?)",
          variables: [Variable.withString(homeKey)],
        )
        .get();
    expect(archived, isNotEmpty);
    for (final row in archived) {
      expect(row.read<int?>('archived_at'), isNot(null));
    }
    final explicit = await db
        .customSelect(
          'SELECT archived_at FROM projects '
          "WHERE host_id = 'configured' AND workspace_key = '~'",
        )
        .getSingle();
    expect(explicit.read<int?>('archived_at'), null);
  });

  test('v22 → v23 adds mentions to the chat draft', () async {
    final db = _openAtVersion(22);
    addTearDown(db.close);

    final columns = await db
        .customSelect(
          "SELECT name, dflt_value FROM pragma_table_info('chats') "
          "WHERE name = 'draft_mentions'",
        )
        .get();
    expect(columns.single.read<String>('name'), 'draft_mentions');
    expect(columns.single.read<String>('dflt_value'), "'[]'");
  });

  test('v25 → v26 adds the client message id and its per-chat index', () async {
    final db = _openAtVersion(25, withMessages: true);
    addTearDown(db.close);

    final columns = await db
        .customSelect(
          "SELECT name FROM pragma_table_info('messages') "
          "WHERE name = 'client_message_id'",
        )
        .map((row) => row.read<String>('name'))
        .get();
    final indexes = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'index' "
          "AND name = 'messages_chat_client_message_id'",
        )
        .map((row) => row.read<String>('name'))
        .get();
    // Уникальность должна быть в пределах чата, а не глобальной.
    final indexColumns = await db
        .customSelect(
          "SELECT name FROM pragma_index_info('messages_chat_client_message_id') "
          'ORDER BY seqno',
        )
        .map((row) => row.read<String>('name'))
        .get();

    expect(columns, ['client_message_id']);
    expect(indexes, ['messages_chat_client_message_id']);
    expect(indexColumns, ['chat_id', 'client_message_id']);
  });

  test('v23 → v25 adds separate edit and metadata revisions', () async {
    final db = _openAtVersion(23);
    addTearDown(db.close);

    final columns = await db
        .customSelect(
          "SELECT name, dflt_value FROM pragma_table_info('chats') "
          "WHERE name IN ('message_edits_revision', 'revision') "
          'ORDER BY name',
        )
        .get();
    expect(columns, hasLength(2));
    expect(columns.first.read<String>('name'), 'message_edits_revision');
    expect(columns.first.read<String>('dflt_value'), '0');
    expect(columns.last.read<String>('name'), 'revision');
    expect(columns.last.read<String>('dflt_value'), '0');
  });

  test('v26 → v27 adds revisions to hosts, projects and MCP servers', () async {
    final db = _openSharedV26();
    addTearDown(db.close);

    for (final table in ['hosts', 'projects', 'mcp_servers']) {
      final column = await db
          .customSelect(
            "SELECT name, dflt_value FROM pragma_table_info('$table') "
            "WHERE name = 'revision'",
          )
          .getSingle();
      expect(column.read<String>('name'), 'revision');
      expect(column.read<String>('dflt_value'), '0');
    }
  });

  test('v21 → v22 separates result errors from call failures', () async {
    final db = _openToolRunsV21();
    addTearDown(db.close);

    final rows = await db
        .customSelect(
          'SELECT id, status, result_error FROM tool_runs ORDER BY id',
        )
        .get();
    final byId = {for (final row in rows) row.read<String>('id'): row};

    final command = byId['command']!;
    expect(command.read<String>('status'), 'done');
    expect(command.read<bool>('result_error'), isTrue);

    final dispatch = byId['dispatch']!;
    expect(dispatch.read<String>('status'), 'failed');
    expect(dispatch.read<bool>('result_error'), isFalse);
  });
}

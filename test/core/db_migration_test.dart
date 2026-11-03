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

/// Таблица saved_models в форме схемы v4 (без входных модальностей).
const _savedModelsV4 =
    'CREATE TABLE saved_models ('
    'id TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL, '
    'context_length INTEGER, supports_tools INTEGER NOT NULL DEFAULT 0)';

/// Открывает базу, созданную предыдущей версией схемы, и даёт миграции поработать.
AppDatabase _openAtVersion(
  int version, {
  bool withLlmModels = false,
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
        ..execute('PRAGMA user_version = $version');
      if (version >= 4) raw.execute(_savedModelsV4);
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
    expect(AppDatabase.currentSchemaVersion, 6);
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
}

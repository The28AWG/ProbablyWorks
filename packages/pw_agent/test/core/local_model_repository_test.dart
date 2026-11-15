import 'package:pw_agent/core/data/local_model_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/providers/ai/local_models.dart';
import 'package:test/test.dart';

LocalModelFile _file(
  String id, {
  String? cacheKey,
  LocalModelSettings settings = const LocalModelSettings(),
}) => LocalModelFile(
  id: id,
  name: 'Model $id',
  source: cacheKey == null ? '/models/$id.gguf' : 'hf://owner/repo/$id.gguf',
  sourceKind: cacheKey == null
      ? LocalModelSourceKind.path
      : LocalModelSourceKind.huggingFace,
  cacheKey: cacheKey,
  settings: settings,
  createdAt: DateTime.utc(2026, 1, 1),
);

void main() {
  late AppDatabase db;
  late LocalModelRepository repository;

  setUp(() {
    db = openInMemoryDatabase();
    repository = LocalModelRepository(db);
  });

  tearDown(() => db.close());

  test('empty store has no local models', () async {
    expect(await repository.all(), isEmpty);
  });

  test('upsert keeps cache key and settings', () async {
    await repository.upsert(
      file: _file(
        'a',
        cacheKey: 'cache-a',
        settings: const LocalModelSettings(contextSize: 8192),
      ),
    );

    final stored = (await repository.all()).single;
    expect(stored.cacheKey, 'cache-a');
    expect(stored.settings.contextSize, 8192);
  });

  test('saveSettings updates only the parameters', () async {
    await repository.upsert(file: _file('a', cacheKey: 'cache-a'));

    await repository.saveSettings(
      'a',
      const LocalModelSettings(temperature: 0.2, supportsTools: false),
    );

    final stored = await repository.byId('a');
    expect(stored?.settings.temperature, 0.2);
    expect(stored?.settings.supportsTools, isFalse);
    expect(stored?.name, 'Model a');
  });

  test('deleteCacheBacked keeps imported files', () async {
    await repository.upsert(file: _file('a', cacheKey: 'cache-a'));
    await repository.upsert(file: _file('b'));

    await repository.deleteCacheBacked();

    final remaining = await repository.all();
    expect(remaining.single.id, 'b');
  });

  test('touch records the last use', () async {
    await repository.upsert(file: _file('a', cacheKey: 'cache-a'));
    final at = DateTime.utc(2026, 5, 5);

    await repository.touch('a', at);

    expect((await repository.byId('a'))?.lastUsedAt, at.toLocal());
  });

  test('delete removes the record', () async {
    await repository.upsert(file: _file('a', cacheKey: 'cache-a'));

    await repository.delete('a');

    expect(await repository.byId('a'), isNull);
  });
}

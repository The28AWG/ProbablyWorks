import 'package:pw_agent/core/data/local_model_download_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/providers/ai/local_models.dart';
import 'package:test/test.dart';

LocalModelDownloadJob _job(String id) => LocalModelDownloadJob(
  id: id,
  source: 'hf://owner/repo/$id.gguf',
  name: 'Model $id',
  createdAt: DateTime.utc(2026),
);

void main() {
  late AppDatabase db;
  late LocalModelDownloadRepository repository;

  setUp(() {
    db = openInMemoryDatabase();
    repository = LocalModelDownloadRepository(db);
  });

  tearDown(() => db.close());

  test('empty store has no download jobs', () async {
    expect(await repository.all(), isEmpty);
  });

  test('upsert keeps the job fields', () async {
    await repository.upsert(_job('a'));

    final stored = (await repository.all()).single;
    expect(stored.id, 'a');
    expect(stored.source, 'hf://owner/repo/a.gguf');
    expect(stored.name, 'Model a');
  });

  test('delete removes one job and deleteAll removes the rest', () async {
    await repository.upsert(_job('a'));
    await repository.upsert(_job('b'));

    await repository.delete('a');
    expect((await repository.all()).single.id, 'b');

    await repository.deleteAll();
    expect(await repository.all(), isEmpty);
  });
}

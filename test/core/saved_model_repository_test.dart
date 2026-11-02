import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/data/saved_model_repository.dart';
import 'package:probably_works/core/db/app_database.dart';
import 'package:probably_works/core/db/db_connection.dart';
import 'package:probably_works/providers/ai/llm_port.dart';

void main() {
  late AppDatabase db;
  late SavedModelRepository repository;

  setUp(() {
    db = openInMemoryDatabase();
    repository = SavedModelRepository(db);
  });

  tearDown(() => db.close());

  test('empty store has no saved models', () async {
    expect(await repository.all(), isEmpty);
  });

  test('saved models keep their details', () async {
    await repository.save(const [
      SavedModel(
        id: 'openai/gpt-4o',
        name: 'GPT-4o',
        contextLength: 128000,
        supportsTools: true,
      ),
      SavedModel(id: 'anthropic/claude', name: 'Claude'),
    ]);

    final byId = {for (final m in await repository.all()) m.id: m};
    expect(byId.keys, unorderedEquals(['openai/gpt-4o', 'anthropic/claude']));
    expect(byId['openai/gpt-4o']!.name, 'GPT-4o');
    expect(byId['openai/gpt-4o']!.contextLength, 128000);
    expect(byId['openai/gpt-4o']!.supportsTools, isTrue);
    expect(byId['anthropic/claude']!.contextLength, isNull);
    expect(byId['anthropic/claude']!.supportsTools, isFalse);
  });

  test('saving the same id updates its details', () async {
    await repository.save(const [SavedModel(id: 'a/x', name: 'Old')]);
    await repository.save(const [SavedModel(id: 'a/x', name: 'New')]);

    final models = await repository.all();
    expect(models.single.name, 'New');
  });
}

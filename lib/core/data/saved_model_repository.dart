import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';
import 'package:probably_works/core/db/app_database.dart';
import 'package:probably_works/providers/ai/llm_port.dart';

/// Выбранные модели с деталями. Пишется только через [save] из [ModelCatalogService].
@lazySingleton
class SavedModelRepository {
  SavedModelRepository(this._db);

  final AppDatabase _db;

  Future<List<SavedModel>> all() async {
    final table = _db.savedModels;
    return [
      for (final row in await _db.select(table).get())
        SavedModel(
          id: row.id,
          name: row.name,
          contextLength: row.contextLength,
          supportsTools: row.supportsTools,
        ),
    ];
  }

  Future<void> save(Iterable<SavedModel> models) => _db.batch(
    (batch) => batch.insertAllOnConflictUpdate(_db.savedModels, [
      for (final model in models)
        SavedModelsCompanion.insert(
          id: model.id,
          name: model.name,
          contextLength: Value(model.contextLength),
          supportsTools: Value(model.supportsTools),
        ),
    ]),
  );
}

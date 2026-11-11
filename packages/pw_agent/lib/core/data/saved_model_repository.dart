import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';

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
          inputModalities: _parseModalities(row.inputModalities),
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
          inputModalities: Value(_joinModalities(model.inputModalities)),
        ),
    ]),
  );

  static List<String>? _parseModalities(String? raw) => raw == null
      ? null
      : [
          for (final part in raw.split(','))
            if (part.isNotEmpty) part,
        ];

  static String? _joinModalities(List<String>? modalities) =>
      modalities?.join(',');
}

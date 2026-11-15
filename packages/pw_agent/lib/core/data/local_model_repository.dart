/// Хранилище файлов локальных моделей.
///
/// Таблица `local_models` — это модели среды выполнения (файлы), а не модели
/// провайдера. Путь к файлу здесь не хранится: он разрешается по источнику и
/// ключу кэша при чтении, потому что контейнер приложения может переехать.
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/providers/ai/local_models.dart';

/// Читает и пишет записи о файлах моделей.
@lazySingleton
class LocalModelRepository {
  LocalModelRepository(this._db);

  final AppDatabase _db;

  $LocalModelsTable get _table => _db.localModels;

  /// Все записи в порядке добавления.
  Future<List<LocalModelFile>> all() async {
    final rows = await (_db.select(
      _table,
    )..orderBy([(table) => OrderingTerm(expression: table.createdAt)])).get();
    return [for (final row in rows) _map(row)];
  }

  /// Запись по id; null — файла нет.
  Future<LocalModelFile?> byId(String id) async {
    final row = await (_db.select(
      _table,
    )..where((table) => table.id.equals(id))).getSingleOrNull();
    return row == null ? null : _map(row);
  }

  /// Создаёт или обновляет запись.
  Future<void> upsert({required LocalModelFile file, DateTime? lastUsedAt}) =>
      _db
          .into(_table)
          .insertOnConflictUpdate(
            LocalModelsCompanion.insert(
              id: file.id,
              name: file.name,
              source: file.source,
              sourceKind: file.sourceKind.name,
              cacheKey: Value(file.cacheKey),
              sizeBytes: Value(file.sizeBytes),
              sha256: Value(file.sha256),
              settingsJson: Value(jsonEncode(file.settings.toJson())),
              createdAt: file.createdAt,
              lastUsedAt: Value(lastUsedAt ?? file.lastUsedAt),
            ),
          );

  /// Сохраняет только параметры: остальные поля не трогаются.
  Future<void> saveSettings(String id, LocalModelSettings settings) =>
      (_db.update(_table)..where((table) => table.id.equals(id))).write(
        LocalModelsCompanion(
          settingsJson: Value(jsonEncode(settings.toJson())),
        ),
      );

  /// Отмечает время последнего использования.
  Future<void> touch(String id, DateTime at) =>
      (_db.update(_table)..where((table) => table.id.equals(id))).write(
        LocalModelsCompanion(lastUsedAt: Value(at)),
      );

  /// Удаляет запись.
  Future<void> delete(String id) =>
      (_db.delete(_table)..where((table) => table.id.equals(id))).go();

  /// Удаляет записи о скачанных файлах, оставляя импортированные.
  Future<void> deleteCacheBacked() =>
      (_db.delete(_table)..where((table) => table.cacheKey.isNotNull())).go();

  LocalModelFile _map(LocalModelRow row) => LocalModelFile(
    id: row.id,
    name: row.name,
    source: row.source,
    sourceKind:
        LocalModelSourceKind.values.asNameMap()[row.sourceKind] ??
        LocalModelSourceKind.path,
    cacheKey: row.cacheKey,
    sizeBytes: row.sizeBytes,
    sha256: row.sha256,
    settings: LocalModelSettings.fromJson(_decodeSettings(row.settingsJson)),
    createdAt: row.createdAt,
    lastUsedAt: row.lastUsedAt,
  );

  static Object? _decodeSettings(String raw) {
    if (raw.isEmpty) return null;
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }
}

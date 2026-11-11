import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';
import 'package:probably_works/core/db/app_database.dart';
import 'package:probably_works/core/domain/mcp_server.dart';

/// Хранилище настроек подключения MCP-серверов.
///
/// Серверы из `mcp.json` и добавленные пользователем лежат в одной таблице,
/// но различаются полем [McpServerConfig.source]: синхронизация файла не
/// должна затирать пользовательские записи.
@lazySingleton
class McpServerRepository {
  McpServerRepository(this._db);

  final AppDatabase _db;

  $McpServersTable get _mcpServersTable => _db.mcpServers;

  Future<List<McpServerConfig>> all() async {
    final rows = await (_db.select(
      _mcpServersTable,
    )..orderBy([(t) => OrderingTerm(expression: t.name)])).get();
    return [for (final row in rows) _map(row)];
  }

  Stream<List<McpServerConfig>> watchAll() =>
      (_db.select(_mcpServersTable)
            ..orderBy([(t) => OrderingTerm(expression: t.name)]))
          .watch()
          .map((rows) => [for (final row in rows) _map(row)]);

  Future<void> upsert(McpServerConfig server) =>
      _db.into(_mcpServersTable).insertOnConflictUpdate(_companion(server));

  Future<void> delete(String id) =>
      (_db.delete(_mcpServersTable)..where((t) => t.id.equals(id))).go();

  /// Заменяет набор серверов из `mcp.json`, не трогая пользовательские записи.
  Future<void> replaceFileServers(List<McpServerConfig> servers) =>
      _db.transaction(() async {
        final keep = {for (final server in servers) server.id};
        final current = await (_db.select(
          _mcpServersTable,
        )..where((t) => t.source.equals(McpServerSource.file.name))).get();
        for (final row in current) {
          if (!keep.contains(row.id)) await delete(row.id);
        }
        for (final server in servers) {
          await upsert(server);
        }
      });

  McpServersCompanion _companion(McpServerConfig server) => McpServersCompanion(
    id: Value(server.id),
    name: Value(server.name),
    transport: Value(server.transport.name),
    source: Value(server.source.name),
    externalKey: Value(server.externalKey),
    enabled: Value(server.enabled),
    configJson: Value(server.configJson),
    createdAt: Value(server.createdAt),
    updatedAt: Value(server.updatedAt),
  );

  McpServerConfig _map(McpServerRow row) => McpServerConfig.fromRow(
    id: row.id,
    name: row.name,
    transport: _transport(row.transport),
    source: _source(row.source),
    externalKey: row.externalKey,
    enabled: row.enabled,
    configJson: row.configJson,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );

  static McpTransport _transport(String value) =>
      McpTransport.values
          .where((transport) => transport.name == value)
          .firstOrNull ??
      McpTransport.stdio;

  static McpServerSource _source(String value) =>
      McpServerSource.values
          .where((source) => source.name == value)
          .firstOrNull ??
      McpServerSource.user;
}

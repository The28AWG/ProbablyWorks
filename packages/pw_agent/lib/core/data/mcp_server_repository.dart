import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/domain/mcp_server.dart';

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

  /// Сохраняет сервер.
  ///
  /// [expectedRevision] — ревизия, на которой основана форма. При несовпадении
  /// бросает `409 mcp_conflict` до записи. Импорт `mcp.json` и служебные
  /// записи передают null и просто увеличивают ревизию.
  Future<void> upsert(McpServerConfig server, {int? expectedRevision}) async {
    final companion = _companion(server);
    if (expectedRevision == null) {
      final row = await (_db.select(
        _mcpServersTable,
      )..where((t) => t.id.equals(server.id))).getSingleOrNull();
      await _db
          .into(_mcpServersTable)
          .insertOnConflictUpdate(
            companion.copyWith(revision: Value((row?.revision ?? 0) + 1)),
          );
      return;
    }
    final next = expectedRevision + 1;
    final updated =
        await (_db.update(_mcpServersTable)..where(
              (t) =>
                  t.id.equals(server.id) & t.revision.equals(expectedRevision),
            ))
            .write(companion.copyWith(revision: Value(next)));
    if (updated > 0) return;
    final exists = await (_db.select(
      _mcpServersTable,
    )..where((t) => t.id.equals(server.id))).getSingleOrNull();
    if (exists != null || expectedRevision != 0) {
      throw const AgentApiException(
        409,
        'mcp_conflict',
        'MCP server was changed by another client',
      );
    }
    final inserted = await _db
        .into(_mcpServersTable)
        .insert(
          companion.copyWith(revision: Value(next)),
          mode: InsertMode.insertOrIgnore,
        );
    if (inserted == 0) {
      throw const AgentApiException(
        409,
        'mcp_conflict',
        'MCP server was changed by another client',
      );
    }
  }

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
    revision: Value(server.revision),
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
    revision: row.revision,
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

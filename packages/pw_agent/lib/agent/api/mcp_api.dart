import 'package:pw_agent/agent/mcp/mcp_client_manager.dart';
import 'package:pw_agent/agent/mcp/mcp_service.dart';
import 'package:pw_agent/core/domain/mcp_server.dart';

/// Снимок настроек и состояний MCP-серверов профиля.
final class McpSnapshot {
  const McpSnapshot({
    required this.servers,
    required this.states,
    this.configError,
  });

  final List<McpServerConfig> servers;
  final Map<String, McpServerState> states;

  /// Ошибка последнего импорта `mcp.json`; null — ошибки нет.
  final String? configError;
}

/// Управление MCP-серверами конкретного агента.
///
/// Локальная реализация работает с репозиторием и `McpService`, удалённая —
/// через HTTP профиля. В JSON не попадают значения секретов: только ссылки
/// вида `${secret:name}` внутри [McpServerConfig.env] и headers.
abstract interface class McpApi {
  Future<McpSnapshot> mcpSnapshot();
  Stream<McpServerState> watchStates();

  /// Подключает включённые серверы, если они ещё не подключены.
  Future<void> ensureReady();

  Future<void> save(McpServerConfig server);
  Future<void> delete(McpServerConfig server);
  Future<void> restart(McpServerConfig server);
  Future<void> refreshTools(McpServerConfig server);

  Future<McpImportResult> importConfig();
  Future<McpImportResult> importConfigText(String raw, {String? sourcePath});
  Future<String> exportConfig();
}

/// JSON-представление конфигурации MCP-сервера для HTTP API.
Map<String, Object?> mcpServerToJson(McpServerConfig server) => {
  'id': server.id,
  'name': server.name,
  'transport': server.transport.name,
  'source': server.source.name,
  'externalKey': server.externalKey,
  'enabled': server.enabled,
  'command': server.command,
  'args': server.args,
  'env': server.env,
  'cwd': server.cwd,
  'url': server.url,
  'headers': server.headers,
  'oauth': server.oauth?.toJson(),
  'createdAt': server.createdAt.toUtc().toIso8601String(),
  'updatedAt': server.updatedAt.toUtc().toIso8601String(),
};

/// Восстанавливает конфигурацию из JSON API. [id] из пути важнее поля в теле.
McpServerConfig mcpServerFromJson(String id, Map<String, dynamic> json) =>
    McpServerConfig(
      id: id,
      name: '${json['name'] ?? ''}',
      transport: _transport(json['transport']),
      source: _source(json['source']),
      externalKey: json['externalKey'] as String?,
      enabled: json['enabled'] != false,
      command: json['command'] as String?,
      args: _stringList(json['args']),
      env: _stringMap(json['env']),
      cwd: json['cwd'] as String?,
      url: json['url'] as String?,
      headers: _stringMap(json['headers']),
      oauth: json['oauth'] is Map
          ? McpOAuthConfig.fromJson(json['oauth'] as Map)
          : null,
      createdAt: _date(json['createdAt']) ?? DateTime.now().toUtc(),
      updatedAt: _date(json['updatedAt']) ?? DateTime.now().toUtc(),
    );

/// Восстанавливает снимок MCP из JSON API.
McpSnapshot mcpSnapshotFromJson(Map<String, dynamic> json) => McpSnapshot(
  servers: [
    for (final item in (json['servers'] as List? ?? const []))
      if (item is Map)
        mcpServerFromJson(
          '${item['id'] ?? ''}',
          Map<String, dynamic>.from(item),
        ),
  ],
  states: {
    for (final entry in (json['states'] as Map? ?? const {}).entries)
      if (entry.value is Map)
        '${entry.key}': mcpStateFromJson(
          Map<String, dynamic>.from(entry.value as Map),
        ),
  },
  configError: json['configError'] as String?,
);

/// JSON-представление состояния MCP-сервера.
Map<String, Object?> mcpStateToJson(McpServerState state) => {
  'serverId': state.serverId,
  'status': state.status.name,
  'tools': [
    for (final tool in state.tools)
      {
        'name': tool.name,
        'title': tool.title,
        'description': tool.description,
        'inputSchema': tool.inputSchema,
      },
  ],
  'error': state.error,
};

/// Восстанавливает состояние MCP-сервера из JSON API.
McpServerState mcpStateFromJson(Map<String, dynamic> json) => McpServerState(
  serverId: '${json['serverId'] ?? ''}',
  status:
      McpConnectionStatus.values
          .where((status) => status.name == '${json['status'] ?? ''}')
          .firstOrNull ??
      McpConnectionStatus.disconnected,
  tools: [
    for (final item in (json['tools'] as List? ?? const []))
      if (item is Map)
        McpToolInfo(
          name: '${item['name'] ?? ''}',
          title: item['title'] as String?,
          description: item['description'] as String?,
          inputSchema: item['inputSchema'] is Map
              ? Map<String, dynamic>.from(item['inputSchema'] as Map)
              : const {},
        ),
  ],
  error: json['error'] as String?,
);

/// JSON-представление результата импорта `mcp.json`.
Map<String, Object?> mcpImportToJson(McpImportResult result) => {
  'status': result.status.name,
  'path': result.path,
  'error': result.error,
};

/// Восстанавливает результат импорта из JSON API.
McpImportResult mcpImportFromJson(Map<String, dynamic> json) {
  final status = McpImportStatus.values
      .where((value) => value.name == '${json['status'] ?? ''}')
      .firstOrNull;
  final path = json['path'] as String?;
  final error = json['error'] as String?;
  return switch (status) {
    McpImportStatus.imported => McpImportResult.imported(path),
    McpImportStatus.missing => McpImportResult.missing(path),
    McpImportStatus.error => McpImportResult.error(error, path),
    null => McpImportResult.error(error ?? 'unknown import status', path),
  };
}

McpTransport _transport(Object? value) =>
    McpTransport.values
        .where((transport) => transport.name == '$value')
        .firstOrNull ??
    McpTransport.stdio;

McpServerSource _source(Object? value) =>
    McpServerSource.values
        .where((source) => source.name == '$value')
        .firstOrNull ??
    McpServerSource.user;

DateTime? _date(Object? value) => value is String && value.isNotEmpty
    ? DateTime.tryParse(value)?.toUtc()
    : null;

List<String> _stringList(Object? value) => value is List
    ? [
        for (final item in value)
          if (item is String) item,
      ]
    : const [];

Map<String, String> _stringMap(Object? value) => value is Map
    ? {
        for (final entry in value.entries)
          if (entry.key is String && entry.value is String)
            '${entry.key}': '${entry.value}',
      }
    : const {};

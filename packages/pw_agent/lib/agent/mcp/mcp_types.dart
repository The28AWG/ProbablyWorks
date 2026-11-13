/// Типы MCP, которые нужны и клиенту, и API, и UI.
///
/// Здесь нет транспорта и файловой системы: файл можно импортировать в web.
/// Реализации MCP импортируют его и реэкспортируют, чтобы старые импорты
/// `mcp_client_manager.dart` и `mcp_service.dart` продолжали работать.
library;

/// Состояние подключения MCP-сервера.
enum McpConnectionStatus { disconnected, connecting, connected, error }

/// Инструмент, который объявил MCP-сервер.
final class McpToolInfo {
  const McpToolInfo({
    required this.name,
    required this.inputSchema,
    this.title,
    this.description,
  });

  final String name;
  final String? title;
  final String? description;
  final Map<String, dynamic> inputSchema;

  String get displayName => title ?? name;
}

/// Снимок состояния одного сервера для настроек и источника инструментов.
final class McpServerState {
  const McpServerState({
    required this.serverId,
    required this.status,
    this.tools = const [],
    this.error,
  });

  const McpServerState.disconnected(this.serverId)
    : status = McpConnectionStatus.disconnected,
      tools = const [],
      error = null;

  final String serverId;
  final McpConnectionStatus status;
  final List<McpToolInfo> tools;
  final String? error;

  bool get isConnected => status == McpConnectionStatus.connected;
}

/// Итог ручного импорта `mcp.json`.
enum McpImportStatus { imported, missing, error }

/// Результат импорта: что произошло и с каким файлом.
final class McpImportResult {
  const McpImportResult.imported(this.path)
    : status = McpImportStatus.imported,
      error = null;

  const McpImportResult.missing(this.path)
    : status = McpImportStatus.missing,
      error = null;

  const McpImportResult.error(this.error, this.path)
    : status = McpImportStatus.error;

  final McpImportStatus status;
  final String? path;
  final String? error;
}

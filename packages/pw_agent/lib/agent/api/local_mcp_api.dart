import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/api/mcp_api.dart';
import 'package:pw_agent/agent/mcp/mcp_client_manager.dart';
import 'package:pw_agent/agent/mcp/mcp_service.dart';
import 'package:pw_agent/core/data/mcp_server_repository.dart';
import 'package:pw_agent/core/domain/mcp_server.dart';

/// Локальное управление MCP-серверами поверх репозитория и сервиса агента.
@LazySingleton(as: McpApi)
final class LocalMcpApi implements McpApi {
  LocalMcpApi(this._repository, this._service);

  final McpServerRepository _repository;
  final McpService _service;

  @override
  Future<McpSnapshot> mcpSnapshot() async {
    final servers = await _repository.all();
    return McpSnapshot(
      servers: servers,
      states: {
        for (final server in servers) server.id: _service.stateOf(server.id),
      },
      configError: _service.configError,
    );
  }

  @override
  Stream<McpServerState> watchStates() => _service.changes;

  @override
  Future<void> ensureReady() => _service.ensureReady();

  @override
  Future<void> save(McpServerConfig server) async {
    final updated = server.copyWith(updatedAt: DateTime.now());
    await _repository.upsert(updated);
    if (updated.enabled) {
      await _service.restart(updated);
    } else {
      await _service.disconnect(updated);
    }
  }

  @override
  Future<void> delete(McpServerConfig server) async {
    await _repository.delete(server.id);
    await _service.disconnect(server);
  }

  @override
  Future<void> restart(McpServerConfig server) => _service.restart(server);

  @override
  Future<void> refreshTools(McpServerConfig server) =>
      _service.refreshServer(server);

  @override
  Future<McpImportResult> importConfig() => _service.importConfig();

  @override
  Future<McpImportResult> importConfigText(String raw, {String? sourcePath}) =>
      _service.importConfigText(raw, sourcePath: sourcePath);

  @override
  Future<String> exportConfig() => _service.exportConfig();
}

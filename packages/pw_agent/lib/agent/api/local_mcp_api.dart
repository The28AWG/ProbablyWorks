import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/api/mcp_api.dart';
import 'package:pw_agent/agent/mcp/mcp_service.dart';
import 'package:pw_agent/agent/state/domain_change_bus.dart';
import 'package:pw_agent/agent/state/shared_state.dart';
import 'package:pw_agent/core/data/mcp_server_repository.dart';
import 'package:pw_agent/core/domain/mcp_server.dart';

/// Локальное управление MCP-серверами поверх репозитория и сервиса агента.
@LazySingleton(as: McpApi)
final class LocalMcpApi implements McpApi {
  LocalMcpApi(this._repository, this._service, [this._changes]);

  final McpServerRepository _repository;
  final McpService _service;
  final DomainChangeBus? _changes;

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
  Future<void> save(McpServerConfig server, {int? expectedRevision}) async {
    final updated = server.copyWith(updatedAt: DateTime.now());
    await _repository.upsert(updated, expectedRevision: expectedRevision);
    if (updated.enabled) {
      await _service.restart(updated);
    } else {
      await _service.disconnect(updated);
    }
    _changes?.publish(SharedResource.mcp);
  }

  @override
  Future<void> delete(McpServerConfig server) async {
    await _repository.delete(server.id);
    await _service.disconnect(server);
    _changes?.publish(SharedResource.mcp);
  }

  @override
  Future<void> restart(McpServerConfig server) async {
    await _service.restart(server);
    _changes?.publish(SharedResource.mcp);
  }

  @override
  Future<void> refreshTools(McpServerConfig server) async {
    await _service.refreshServer(server);
    _changes?.publish(SharedResource.mcp);
  }

  @override
  Future<McpImportResult> importConfig() async {
    final result = await _service.importConfig();
    _changes?.publish(SharedResource.mcp);
    return result;
  }

  @override
  Future<McpImportResult> importConfigText(
    String raw, {
    String? sourcePath,
  }) async {
    final result = await _service.importConfigText(raw, sourcePath: sourcePath);
    _changes?.publish(SharedResource.mcp);
    return result;
  }

  @override
  Future<String> exportConfig() => _service.exportConfig();
}

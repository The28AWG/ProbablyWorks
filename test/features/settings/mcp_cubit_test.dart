import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/features/settings/presentation/bloc/mcp_cubit.dart';
import 'package:pw_agent/agent/api/mcp_api.dart';
import 'package:pw_agent/agent/mcp/mcp_client_manager.dart';
import 'package:pw_agent/agent/mcp/mcp_service.dart';
import 'package:pw_agent/core/domain/mcp_server.dart';

final class _FakeMcp implements McpApi {
  final changes = StreamController<McpServerState>.broadcast();
  final servers = <McpServerConfig>[
    McpServerConfig(
      id: 'mcp-1',
      name: 'Search',
      transport: McpTransport.http,
      source: McpServerSource.user,
      url: 'https://example.test/mcp',
      createdAt: DateTime.utc(2026, 11, 11),
      updatedAt: DateTime.utc(2026, 11, 11),
    ),
  ];
  var states = <String, McpServerState>{
    'mcp-1': const McpServerState.disconnected('mcp-1'),
  };
  var ready = 0;
  McpServerConfig? saved;

  @override
  Future<McpSnapshot> mcpSnapshot() async =>
      McpSnapshot(servers: servers, states: states);

  @override
  Stream<McpServerState> watchStates() => changes.stream;

  @override
  Future<void> ensureReady() async {
    ready++;
    states = {
      'mcp-1': const McpServerState(
        serverId: 'mcp-1',
        status: McpConnectionStatus.connected,
      ),
    };
  }

  @override
  Future<void> save(McpServerConfig server) async {
    saved = server;
  }

  @override
  Future<void> delete(McpServerConfig server) => Future<void>.value();

  @override
  Future<void> restart(McpServerConfig server) => Future<void>.value();

  @override
  Future<void> refreshTools(McpServerConfig server) => Future<void>.value();

  @override
  Future<McpImportResult> importConfig() async =>
      const McpImportResult.imported('/tmp/mcp.json');

  @override
  Future<McpImportResult> importConfigText(
    String raw, {
    String? sourcePath,
  }) async => McpImportResult.imported(sourcePath);

  @override
  Future<String> exportConfig() async => '{"mcpServers":{}}';
}

void main() {
  late _FakeMcp api;
  late McpCubit cubit;

  setUp(() {
    api = _FakeMcp();
    cubit = McpCubit(api);
  });

  tearDown(() async {
    await api.changes.close();
    await cubit.close();
  });

  test('loads the profile servers and connects them', () async {
    await cubit.load();

    expect(cubit.state.servers.single.id, 'mcp-1');
    expect(api.ready, 1);
    expect(cubit.state.stateOf('mcp-1').status, McpConnectionStatus.connected);
  });

  test('state changes from the API reach the cubit', () async {
    await cubit.load();

    api.changes.add(
      const McpServerState(
        serverId: 'mcp-1',
        status: McpConnectionStatus.error,
        error: 'boom',
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(cubit.state.stateOf('mcp-1').error, 'boom');
  });

  test('saving a server goes through the profile API', () async {
    await cubit.load();
    final server = cubit.state.servers.single.copyWith(name: 'Docs');

    await cubit.save(server);

    expect(api.saved?.name, 'Docs');
  });
}

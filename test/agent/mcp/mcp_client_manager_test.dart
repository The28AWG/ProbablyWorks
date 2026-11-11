import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:pw_agent/agent/mcp/mcp_client_manager.dart';
import 'package:pw_agent/agent/mcp/mcp_tool_source.dart';
import 'package:pw_agent/core/domain/mcp_server.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';

McpServerConfig _server({Map<String, String> env = const {}}) =>
    McpServerConfig(
      id: 'file:test',
      name: 'Test',
      transport: McpTransport.stdio,
      source: McpServerSource.file,
      externalKey: 'test',
      command: 'ignored',
      env: env,
      createdAt: DateTime(2026, 11, 11),
      updatedAt: DateTime(2026, 11, 11),
    );

McpServer _createServer() =>
    McpServer(
      const Implementation(name: 'test-server', version: '1.0.0'),
    )..registerTool(
      'echo',
      description: 'Echo text',
      inputSchema: JsonSchema.object(
        properties: {'text': JsonSchema.string()},
        required: ['text'],
      ),
      callback: (args, extra) async =>
          CallToolResult(content: [TextContent(text: 'echo: ${args['text']}')]),
    );

Future<({McpServer server, McpClientManager manager})> _start() async {
  final clientToServer = StreamController<List<int>>();
  final serverToClient = StreamController<List<int>>();
  final server = _createServer();
  await server.connect(
    IOStreamTransport(stream: clientToServer.stream, sink: serverToClient.sink),
  );

  final secrets = MemorySecretStore();
  await secrets.write('token', 'secret-value');
  final manager = McpClientManager.withTransport(
    secrets,
    (server, environment, headers, authProvider) async => IOStreamTransport(
      stream: serverToClient.stream,
      sink: clientToServer.sink,
    ),
  );
  addTearDown(() async {
    await manager.closeAll();
    await server.close();
    await clientToServer.close();
    await serverToClient.close();
  });
  return (server: server, manager: manager);
}

void main() {
  test('connects, lists tools and calls one', () async {
    final started = await _start();

    final state = await started.manager.connect(_server());
    expect(state.status, McpConnectionStatus.connected);
    expect(state.tools.single.name, 'echo');

    final output = await started.manager.callTool(_server(), 'echo', {
      'text': 'hi',
    });
    expect(output.isError, isFalse);
    expect(output.text, 'echo: hi');
  });

  test('source namespaces tools and resolves the original name', () async {
    final started = await _start();
    final state = await started.manager.connect(_server());
    final source = McpToolSource(
      server: _server(),
      manager: started.manager,
      tools: state.tools,
    );

    expect(source.specs.single.name, 'mcp_file_test_echo');
    expect(source.specs.single.description, startsWith('[Test]'));
    expect(
      source.summaryFor(
        const LlmToolCall(id: '1', name: 'mcp_file_test_echo', arguments: '{}'),
        const {},
      ),
      'Test: echo',
    );
  });

  test('connection errors become state instead of exceptions', () async {
    final manager = McpClientManager.withTransport(
      MemorySecretStore(),
      (server, environment, headers, authProvider) async =>
          throw StateError('boom'),
    );

    final state = await manager.connect(_server());

    expect(state.status, McpConnectionStatus.error);
    expect(state.error, contains('boom'));
    expect(manager.stateOf('file:test').status, McpConnectionStatus.error);
  });

  test('secret references are resolved before spawning', () async {
    Map<String, String>? captured;
    final secrets = MemorySecretStore();
    await secrets.write('token', 'secret-value');
    final manager = McpClientManager.withTransport(secrets, (
      server,
      environment,
      headers,
      authProvider,
    ) async {
      captured = environment;
      throw StateError('stop after capture');
    });

    await manager.connect(_server(env: const {'TOKEN': r'${secret:token}'}));

    expect(captured?['TOKEN'], 'secret-value');
  });
}

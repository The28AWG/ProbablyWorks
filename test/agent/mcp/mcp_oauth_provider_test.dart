import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mcp_dart/mcp_dart.dart';
import 'package:pw_agent/agent/mcp/mcp_oauth_provider.dart';
import 'package:pw_agent/core/domain/mcp_server.dart';
import 'package:pw_agent/core/security/secret_store.dart';

McpServerConfig _server(int port) => McpServerConfig(
  id: 'remote',
  name: 'Remote',
  transport: McpTransport.http,
  source: McpServerSource.user,
  url: 'https://example.com/mcp',
  oauth: McpOAuthConfig(
    clientId: 'client',
    scopes: const ['tools:read'],
    redirectPort: port,
  ),
  createdAt: DateTime(2026, 11, 11),
  updatedAt: DateTime(2026, 11, 11),
);

void main() {
  test('receives the local callback and stores tokens', () async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();

    final secrets = MemorySecretStore();
    Uri? opened;
    final provider = McpOAuthProvider(
      server: _server(port),
      secrets: secrets,
      openUrl: (uri) async {
        opened = uri;
        await http.get(
          Uri.parse('http://127.0.0.1:$port/callback?code=abc&state=state-1'),
        );
      },
    );
    addTearDown(provider.close);

    await provider.redirectToAuthorizationUrl(
      Uri.parse('https://auth.example/authorize'),
    );
    final callback = await provider.waitForCallback(
      timeout: const Duration(seconds: 5),
    );

    expect(opened, Uri.parse('https://auth.example/authorize'));
    expect(callback.code, 'abc');
    expect(callback.state, 'state-1');
    expect(provider.redirectUri, Uri.parse('http://127.0.0.1:$port/callback'));

    await provider.saveTokens(
      OAuthTokens(accessToken: 'access', refreshToken: 'refresh'),
    );
    final tokens = await provider.tokens();
    expect(tokens?.accessToken, 'access');
    expect(tokens?.refreshToken, 'refresh');
    expect(secrets.values[mcpOAuthTokensKey('remote')], isNotNull);
  });
}

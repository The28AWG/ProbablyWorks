import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/agent/mcp/mcp_config_file.dart';
import 'package:probably_works/agent/mcp/mcp_json_config.dart';
import 'package:probably_works/core/data/mcp_server_repository.dart';
import 'package:probably_works/core/db/db_connection.dart';
import 'package:probably_works/core/domain/mcp_server.dart';
import 'package:probably_works/core/security/secret_store.dart';

void main() {
  test('parses stdio and http entries', () {
    final servers = McpJsonConfig.parse(
      jsonEncode({
        'mcpServers': {
          'local': {
            'command': 'node',
            'args': ['server.js'],
            'env': {'TOKEN': r'${secret:token}'},
            'cwd': '/tmp',
          },
          'remote': {
            'url': 'https://example.com/mcp',
            'headers': {'Authorization': 'Bearer x'},
            'enabled': false,
          },
        },
      }),
      now: DateTime(2026, 11, 11),
    );

    expect(servers, hasLength(2));
    expect(servers.first.transport, McpTransport.stdio);
    expect(servers.first.args, ['server.js']);
    expect(servers.first.source, McpServerSource.file);
    expect(servers.last.transport, McpTransport.http);
    expect(servers.last.enabled, isFalse);
  });

  test('rejects malformed files', () {
    expect(() => McpJsonConfig.parse('{'), throwsA(isA<McpConfigException>()));
    expect(
      () => McpJsonConfig.parse('{"mcpServers": {"x": {}}}'),
      throwsA(isA<McpConfigException>()),
    );
  });

  test('exported file can be parsed again', () {
    final server = McpServerConfig(
      id: 'file:one',
      name: 'One',
      transport: McpTransport.http,
      source: McpServerSource.file,
      externalKey: 'one',
      url: 'https://example.com/mcp',
      headers: const {'X': r'${secret:x}'},
      createdAt: DateTime(2026, 11, 11),
      updatedAt: DateTime(2026, 11, 11),
    );

    final parsed = McpJsonConfig.parse(
      McpJsonConfig.encode([server]),
      now: DateTime(2026, 11, 11),
    );

    expect(parsed.single.externalKey, 'one');
    expect(parsed.single.headers['X'], r'${secret:x}');
    expect(parsed.single.url, 'https://example.com/mcp');
  });

  test('file import replaces file servers and moves raw secrets', () async {
    final db = openInMemoryDatabase();
    final tmp = Directory.systemTemp.createTempSync('pw_mcp_json');
    addTearDown(() async {
      await db.close();
      tmp.deleteSync(recursive: true);
    });
    final repository = McpServerRepository(db);
    final secrets = MemorySecretStore();
    final file = File('${tmp.path}/mcp.json');
    final sync = McpConfigFile(file, repository, secrets);

    await file.writeAsString(
      jsonEncode({
        'mcpServers': {
          'local': {
            'command': 'node',
            'env': {'TOKEN': 'raw-secret'},
          },
        },
      }),
    );
    await sync.import();

    var servers = await repository.all();
    expect(servers.single.id, 'file:local');
    expect(servers.single.env['TOKEN'], r'${secret:mcp.local.env.TOKEN}');
    expect(secrets.values['mcp.local.env.TOKEN'], 'raw-secret');

    await repository.upsert(
      McpServerConfig(
        id: 'user',
        name: 'User',
        transport: McpTransport.http,
        source: McpServerSource.user,
        url: 'https://example.com/mcp',
        createdAt: DateTime(2026, 11, 11),
        updatedAt: DateTime(2026, 11, 11),
      ),
    );
    await file.writeAsString(jsonEncode({'mcpServers': <String, Object>{}}));
    await sync.import();

    servers = await repository.all();
    expect(servers.map((server) => server.id), ['user']);

    await sync.export();
    final exported = jsonDecode(await file.readAsString()) as Map;
    expect((exported['mcpServers'] as Map).keys, contains('User'));
  });
}

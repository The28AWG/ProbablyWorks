import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/core/data/mcp_server_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/domain/mcp_server.dart';

McpServerConfig _server(
  String id, {
  required McpServerSource source,
  String? externalKey,
  bool enabled = true,
}) => McpServerConfig(
  id: id,
  name: id,
  transport: McpTransport.stdio,
  source: source,
  externalKey: externalKey,
  enabled: enabled,
  command: 'node',
  args: const ['server.js'],
  env: const {'TOKEN': r'${secret:mcp}'},
  createdAt: DateTime(2026, 11, 11),
  updatedAt: DateTime(2026, 11, 11),
);

void main() {
  late AppDatabase db;
  late McpServerRepository repository;

  setUp(() async {
    db = openInMemoryDatabase();
    repository = McpServerRepository(db);
  });

  tearDown(() => db.close());

  test('user servers are stored and updated', () async {
    await repository.upsert(_server('one', source: McpServerSource.user));

    var servers = await repository.all();
    expect(servers, hasLength(1));
    expect(servers.single.transport, McpTransport.stdio);
    expect(servers.single.args, ['server.js']);
    expect(servers.single.env['TOKEN'], r'${secret:mcp}');

    await repository.upsert(
      servers.single.copyWith(
        enabled: false,
        updatedAt: DateTime(2026, 11, 12),
      ),
    );
    servers = await repository.all();
    expect(servers.single.enabled, isFalse);

    await repository.delete('one');
    expect(await repository.all(), isEmpty);
  });

  test('revision grows and a stale form is rejected', () async {
    await repository.upsert(_server('one', source: McpServerSource.user));
    final first = (await repository.all()).single;
    expect(first.revision, 1);

    await expectLater(
      repository.upsert(
        _server('one', source: McpServerSource.user).copyWith(name: 'stale'),
        expectedRevision: 0,
      ),
      throwsA(
        isA<AgentApiException>().having(
          (error) => error.code,
          'code',
          'mcp_conflict',
        ),
      ),
    );

    await repository.upsert(
      first.copyWith(name: 'fresh'),
      expectedRevision: first.revision,
    );
    final saved = (await repository.all()).single;
    expect(saved.name, 'fresh');
    expect(saved.revision, 2);
  });

  test('file sync replaces only file-managed servers', () async {
    await repository.upsert(_server('user', source: McpServerSource.user));
    await repository.upsert(
      _server('old', source: McpServerSource.file, externalKey: 'old'),
    );

    await repository.replaceFileServers([
      _server('new', source: McpServerSource.file, externalKey: 'new'),
    ]);

    final servers = await repository.all();
    expect(servers.map((server) => server.id), containsAll(['user', 'new']));
    expect(servers.map((server) => server.id), isNot(contains('old')));
    expect(
      servers.singleWhere((server) => server.id == 'user').source,
      McpServerSource.user,
    );
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:plugin_api/plugin_api.dart' as plugins;
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/agent_settings_api.dart';
import 'package:pw_agent/agent/api/chat_api.dart';
import 'package:pw_agent/agent/api/data_api.dart';
import 'package:pw_agent/agent/api/mcp_api.dart';
import 'package:pw_agent/agent/api/plugin_api.dart';
import 'package:pw_agent/agent/api/projects_api.dart';
import 'package:pw_agent/agent/api/push_api.dart';
import 'package:pw_agent/agent/api/security_audit_api.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/project.dart';
import 'package:pw_agent/agent/domain/search.dart';
import 'package:pw_agent/agent/domain/steps_display.dart';
import 'package:pw_agent/agent/domain/workspace_entry.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/agent/loop/prompt_queue.dart';
import 'package:pw_agent/agent/mcp/mcp_client_manager.dart';
import 'package:pw_agent/agent/mcp/mcp_service.dart';
import 'package:pw_agent/agent/policy/security_profile.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/domain/mcp_server.dart';
import 'package:pw_agent/core/security/security_audit.dart';
import 'package:pw_agent/providers/ai/llama_cpp/llama_cpp_connection.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/local_models.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';
import 'package:pw_agent/providers/ai/model_runtime.dart';
import 'package:pw_agent/providers/ai/openrouter/openrouter_llm_provider.dart';
import 'package:pw_server/pw_server.dart';
import 'package:test/test.dart';

const _token = 'test-token';

void main() {
  late _FakeBackend backend;
  late _FakeMcp mcp;
  late _FakePlugins pluginApi;
  late _FakeSecurityAudit securityAudit;
  late _FakePush push;
  late _FakeProjects projectsApi;
  late _FakeData dataApi;
  late ApiServer server;
  late HttpClient client;
  late String base;

  setUp(() async {
    backend = _FakeBackend();
    mcp = _FakeMcp();
    pluginApi = _FakePlugins();
    securityAudit = _FakeSecurityAudit();
    push = _FakePush();
    projectsApi = _FakeProjects();
    dataApi = _FakeData();
    server = ApiServer(
      backend,
      _token,
      port: 0,
      requireSession: false,
      projects: projectsApi,
      dataApi: dataApi,
      mcpApi: mcp,
      pluginApi: pluginApi,
      securityAuditApi: securityAudit,
      pushApi: push,
      allowedOrigins: const {'http://localhost:8080'},
    );
    final port = await server.start();
    base = 'http://127.0.0.1:$port';
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    await backend.dispose();
  });

  test('allows CORS preflight only for configured origins', () async {
    Future<String?> originHeader(HttpClient client, String origin) async {
      final request = await client.openUrl(
        'OPTIONS',
        Uri.parse('$base/api/v1/settings'),
      );
      request.headers
        ..set('Origin', origin)
        ..set('Access-Control-Request-Method', 'GET')
        ..set('Access-Control-Request-Headers', 'authorization');
      final response = await request.close();
      await response.drain<void>();
      return response.headers.value('access-control-allow-origin');
    }

    expect(await originHeader(client, 'http://localhost:8080'), isNotNull);
    expect(await originHeader(client, 'http://evil.test'), isNull);
  });

  test('CORS allows the client session header', () async {
    final request = await client.openUrl(
      'OPTIONS',
      Uri.parse('$base/api/v1/chats'),
    );
    request.headers
      ..set('Origin', 'http://localhost:8080')
      ..set('Access-Control-Request-Method', 'GET')
      ..set('Access-Control-Request-Headers', 'x-client-session');
    final response = await request.close();
    expect(
      response.headers.value('access-control-allow-headers'),
      contains('x-client-session'),
    );
    await response.drain<void>();
  });

  test('client probe checks the token without creating a session', () async {
    final registry = ClientSessionRegistry(
      sweepInterval: const Duration(hours: 1),
    );
    final probeServer = ApiServer(
      backend,
      _token,
      port: 0,
      clientSessions: registry,
    );
    final port = await probeServer.start();
    addTearDown(probeServer.stop);
    final base = 'http://127.0.0.1:$port';

    final (status, body) = await _request(
      client,
      base,
      'GET',
      '/api/v1/client/probe',
      token: _token,
    );

    expect(status, HttpStatus.ok);
    expect(jsonDecode(body), containsPair('protocol', 1));
    // Probe не должен появляться в списке клиентов и тратить TTL.
    expect(registry.list(), isEmpty);
  });

  test('validates data cleanup parameters', () async {
    final (badStatus, _) = await _request(
      client,
      base,
      'POST',
      '/api/v1/data/history/clear',
      token: _token,
      body: {'olderThanDays': 0.5},
    );
    expect(badStatus, HttpStatus.badRequest);
    expect(dataApi.clearCalls, 0);

    final (okStatus, _) = await _request(
      client,
      base,
      'POST',
      '/api/v1/data/history/clear',
      token: _token,
      body: {'olderThanDays': 30},
    );
    expect(okStatus, HttpStatus.ok);
    expect(dataApi.lastDays, 30);

    final (usageStatus, usageBody) = await _request(
      client,
      base,
      'GET',
      '/api/v1/data/usage',
      token: _token,
    );
    expect(usageStatus, HttpStatus.ok);
    expect(jsonDecode(usageBody), containsPair('scheduledTasks', 1));
  });

  test('health is open and reports ok', () async {
    final (status, body) = await _request(
      client,
      base,
      'GET',
      '/api/v1/health',
    );

    expect(status, HttpStatus.ok);
    expect(jsonDecode(body), containsPair('ok', true));
  });

  test('serves web without token and keeps API protected', () async {
    final temp = Directory.systemTemp.createTempSync('pw_api_web_');
    addTearDown(() => temp.deleteSync(recursive: true));
    File(p.join(temp.path, 'index.html')).writeAsStringSync('<html>web</html>');
    final webServer = ApiServer(
      backend,
      _token,
      port: 0,
      requireSession: false,
      web: StaticWeb.open(temp.path),
    );
    final webPort = await webServer.start();
    final webClient = HttpClient();
    addTearDown(() async {
      webClient.close(force: true);
      await webServer.stop();
    });
    final webBase = 'http://127.0.0.1:$webPort';

    expect((await _request(webClient, webBase, 'GET', '/')).$1, HttpStatus.ok);
    expect(
      (await _request(webClient, webBase, 'GET', '/a/x/chats')).$1,
      HttpStatus.ok,
    );
    expect(
      (await _request(webClient, webBase, 'GET', '/api/v1/health')).$1,
      HttpStatus.ok,
    );
    expect(
      (await _request(webClient, webBase, 'GET', '/api/v1/chats')).$1,
      HttpStatus.unauthorized,
    );
  });

  test('rate limits requests and returns Retry-After', () async {
    final limitedBackend = _FakeBackend();
    final limited = ApiServer(
      limitedBackend,
      _token,
      port: 0,
      requireSession: false,
      rateLimiter: ApiRateLimiter(
        maxRequests: 2,
        window: const Duration(minutes: 1),
      ),
    );
    final port = await limited.start();
    final limitedClient = HttpClient();
    addTearDown(() async {
      limitedClient.close(force: true);
      await limited.stop();
      await limitedBackend.dispose();
    });
    final limitedBase = 'http://127.0.0.1:$port';

    for (var attempt = 0; attempt < 2; attempt++) {
      expect(
        (await _request(
          limitedClient,
          limitedBase,
          'GET',
          '/api/v1/health',
        )).$1,
        HttpStatus.ok,
        reason: 'attempt $attempt must pass before the limit is exhausted',
      );
    }

    final request = await limitedClient.getUrl(
      Uri.parse('$limitedBase/api/v1/health'),
    );
    final response = await request.close();
    await response.drain<void>();
    expect(response.statusCode, HttpStatus.tooManyRequests);
    expect(response.headers.value(HttpHeaders.retryAfterHeader), isNotNull);
  });

  test('rejects requests above the concurrency limit', () async {
    backend
      ..chatsStarted = Completer<void>()
      ..chatsGate = Completer<void>();
    final limited = ApiServer(
      backend,
      _token,
      port: 0,
      requireSession: false,
      maxConcurrentRequests: 1,
      requestTimeout: const Duration(seconds: 10),
    );
    final port = await limited.start();
    final limitedClient = HttpClient();
    addTearDown(() async {
      if (!backend.chatsGate!.isCompleted) backend.chatsGate!.complete();
      limitedClient.close(force: true);
      await limited.stop();
    });
    final limitedBase = 'http://127.0.0.1:$port';

    final first = _request(
      limitedClient,
      limitedBase,
      'GET',
      '/api/v1/chats',
      token: _token,
    );
    await backend.chatsStarted!.future;

    final (busyStatus, busyBody) = await _request(
      limitedClient,
      limitedBase,
      'GET',
      '/api/v1/chats',
      token: _token,
    );
    expect(busyStatus, HttpStatus.serviceUnavailable);
    expect(busyBody, contains('server_busy'));

    backend.chatsGate!.complete();
    expect((await first).$1, HttpStatus.ok);
  });

  test('returns 504 when the backend does not finish in time', () async {
    backend
      ..chatsStarted = Completer<void>()
      ..chatsGate = Completer<void>();
    final limited = ApiServer(
      backend,
      _token,
      port: 0,
      requireSession: false,
      requestTimeout: const Duration(milliseconds: 50),
    );
    final port = await limited.start();
    final limitedClient = HttpClient();
    addTearDown(() async {
      if (!backend.chatsGate!.isCompleted) backend.chatsGate!.complete();
      limitedClient.close(force: true);
      await limited.stop();
    });

    final (status, body) = await _request(
      limitedClient,
      'http://127.0.0.1:$port',
      'GET',
      '/api/v1/chats',
      token: _token,
    );

    expect(status, HttpStatus.gatewayTimeout);
    expect(body, contains('request_timeout'));
  });

  test('does not expose internal error details', () async {
    backend.chatsError = StateError('secret /home/user/.ssh/config');

    final (status, body) = await _request(
      client,
      base,
      'GET',
      '/api/v1/chats',
      token: _token,
    );

    expect(status, HttpStatus.internalServerError);
    expect(body, contains('internal server error'));
    expect(body, isNot(contains('/home/user')));
    expect(body, isNot(contains('ssh')));
  });

  test('reads and revises project memory through the API', () async {
    final (emptyStatus, emptyBody) = await _request(
      client,
      base,
      'GET',
      '/api/v1/projects/p1/memory',
      token: _token,
    );
    expect(emptyStatus, HttpStatus.ok);
    expect(jsonDecode(emptyBody), containsPair('memory', null));

    final (status, body) = await _request(
      client,
      base,
      'POST',
      '/api/v1/projects/p1/memory',
      token: _token,
      body: {'instruction': 'add the build command'},
    );
    expect(status, HttpStatus.ok);
    final memory = (jsonDecode(body) as Map)['memory'] as Map;
    expect(memory['summary'], contains('pnpm'));
    expect(projectsApi.instruction, 'add the build command');

    final (badStatus, _) = await _request(
      client,
      base,
      'POST',
      '/api/v1/projects/p1/memory',
      token: _token,
      body: {'instruction': '   '},
    );
    expect(badStatus, HttpStatus.badRequest);
  });

  test(
    'looks up a project and searches mentions without client limits',
    () async {
      final now = DateTime.utc(2026, 11, 19);
      projectsApi
        ..found = Project(
          id: 'p1',
          hostId: 'local',
          name: 'app',
          workspace: '/work/app',
          workspaceKey: '/work/app',
          createdAt: now,
          updatedAt: now,
        )
        ..entries = const [
          WorkspaceEntry(path: 'src/app.dart', isDirectory: false),
          WorkspaceEntry(path: 'lib/features', isDirectory: true),
        ];

      final (lookupStatus, lookupBody) = await _request(
        client,
        base,
        'GET',
        '/api/v1/projects/lookup?hostId=local&workspace=%2Fwork%2Fapp',
        token: _token,
      );
      expect(lookupStatus, HttpStatus.ok);
      expect(((jsonDecode(lookupBody) as Map)['project'] as Map)['id'], 'p1');

      final (mentionsStatus, mentionsBody) = await _request(
        client,
        base,
        'GET',
        '/api/v1/projects/p1/mentions?q=rdm&depth=100000&limit=1',
        token: _token,
      );
      expect(mentionsStatus, HttpStatus.ok);
      final entries = (jsonDecode(mentionsBody) as Map)['entries'] as List;
      expect(entries, hasLength(2));
      expect((entries.first as Map)['path'], 'src/app.dart');
    },
  );

  test('searches chats and messages through the API', () async {
    final (status, body) = await _request(
      client,
      base,
      'GET',
      '/api/v1/search?q=alpha&scope=project&projectId=p1&limit=5',
      token: _token,
    );

    expect(status, HttpStatus.ok);
    final hits = (jsonDecode(body) as Map)['hits'] as List;
    expect(hits, hasLength(1));
    expect(hits.single['kind'], 'message');
    expect(hits.single['chatId'], 'c1');
    expect(backend.searchQueries.single.text, 'alpha');
    expect(backend.searchQueries.single.scope, SearchScope.project);
    expect(backend.searchQueries.single.projectId, 'p1');
    expect(backend.searchQueries.single.limit, 5);
  });

  test('protected endpoints require a bearer token', () async {
    final (status, body) = await _request(client, base, 'GET', '/api/v1/chats');

    expect(status, HttpStatus.unauthorized);
    expect(jsonDecode(body), contains('error'));
  });

  test('wrong token is rejected', () async {
    final (status, _) = await _request(
      client,
      base,
      'GET',
      '/api/v1/chats',
      token: 'wrong',
    );

    expect(status, HttpStatus.unauthorized);
  });

  test('lists main chats', () async {
    final (status, body) = await _request(
      client,
      base,
      'GET',
      '/api/v1/chats',
      token: _token,
    );

    expect(status, HttpStatus.ok);
    final chats = (jsonDecode(body) as Map)['chats'] as List;
    expect(chats, hasLength(1));
    expect(chats.single['title'], 'Test chat');
  });

  test('lists hosts and creates a chat', () async {
    final (hostsStatus, hostsBody) = await _request(
      client,
      base,
      'GET',
      '/api/v1/hosts',
      token: _token,
    );
    final (createStatus, createBody) = await _request(
      client,
      base,
      'POST',
      '/api/v1/chats',
      token: _token,
      body: {'hostId': 'local'},
    );

    expect(hostsStatus, HttpStatus.ok);
    final host =
        ((jsonDecode(hostsBody) as Map)['hosts'] as List).single as Map;
    expect(host['systemLabel'], 'Ubuntu 24.04.1 LTS');
    expect(createStatus, HttpStatus.created);
    expect((jsonDecode(createBody) as Map)['hostId'], 'local');
  });

  test('serializes host timestamps as UTC', () async {
    final source = (await backend.hosts()).single;
    final (status, body) = await _request(
      client,
      base,
      'GET',
      '/api/v1/hosts',
      token: _token,
    );

    expect(status, HttpStatus.ok);
    final host = ((jsonDecode(body) as Map)['hosts'] as List).single as Map;
    for (final key in ['createdAt', 'updatedAt', 'lastCheckAt']) {
      expect(host[key], endsWith('Z'), reason: key);
    }
    expect(
      DateTime.parse(host['createdAt'] as String)
          .isAtSameMomentAs(source.createdAt),
      isTrue,
    );
    expect(
      DateTime.parse(host['lastCheckAt'] as String)
          .isAtSameMomentAs(source.lastCheckAt!),
      isTrue,
    );
  });

  test('serializes chat and message timestamps as UTC', () async {
    final (status, body) = await _request(
      client,
      base,
      'GET',
      '/api/v1/chats/c1',
      token: _token,
    );

    expect(status, HttpStatus.ok);
    final json = jsonDecode(body) as Map;
    final chat = json['chat'] as Map;
    final messages = json['messages'] as List;
    expect(chat['createdAt'], endsWith('Z'));
    expect(chat['updatedAt'], endsWith('Z'));
    expect((messages.single as Map)['createdAt'], endsWith('Z'));
  });

  test('returns MCP servers and states', () async {
    final (status, body) = await _request(
      client,
      base,
      'GET',
      '/api/v1/mcp',
      token: _token,
    );

    expect(status, HttpStatus.ok);
    final json = jsonDecode(body) as Map;
    final server = (json['servers'] as List).single as Map;
    final state = (json['states'] as Map)['mcp-1'] as Map;
    expect(server['id'], 'mcp-1');
    expect(server['createdAt'], endsWith('Z'));
    expect(state['status'], 'connected');
    expect((state['tools'] as List).single['name'], 'search');
  });

  test('saves, restarts and deletes an MCP server', () async {
    final server = {
      'name': 'Docs',
      'transport': 'stdio',
      'source': 'user',
      'command': 'npx',
      'args': ['-y', 'docs'],
      'enabled': true,
    };
    final (saveStatus, _) = await _request(
      client,
      base,
      'PUT',
      '/api/v1/mcp/servers/mcp-1',
      token: _token,
      body: server,
    );
    final (restartStatus, _) = await _request(
      client,
      base,
      'POST',
      '/api/v1/mcp/servers/mcp-1/restart',
      token: _token,
    );
    final (toolsStatus, _) = await _request(
      client,
      base,
      'POST',
      '/api/v1/mcp/servers/mcp-1/tools/refresh',
      token: _token,
    );
    final (deleteStatus, _) = await _request(
      client,
      base,
      'DELETE',
      '/api/v1/mcp/servers/mcp-1',
      token: _token,
    );

    expect(saveStatus, HttpStatus.noContent);
    expect(restartStatus, HttpStatus.noContent);
    expect(toolsStatus, HttpStatus.noContent);
    expect(deleteStatus, HttpStatus.noContent);
    expect(mcp.saved?.name, 'Docs');
    expect(mcp.restarted, 'mcp-1');
    expect(mcp.refreshed, 'mcp-1');
    expect(mcp.deleted, 'mcp-1');
  });

  test('imports and exports MCP config', () async {
    const raw = '{"mcpServers":{}}';
    final (importStatus, importBody) = await _request(
      client,
      base,
      'POST',
      '/api/v1/mcp/import',
      token: _token,
      body: {'text': raw, 'sourcePath': '/tmp/mcp.json'},
    );
    final (exportStatus, exportBody) = await _request(
      client,
      base,
      'GET',
      '/api/v1/mcp/export',
      token: _token,
    );

    expect(importStatus, HttpStatus.ok);
    expect((jsonDecode(importBody) as Map)['status'], 'imported');
    expect(mcp.importedText, raw);
    expect(mcp.importedFrom, '/tmp/mcp.json');
    expect(exportStatus, HttpStatus.ok);
    expect((jsonDecode(exportBody) as Map)['text'], '{"mcpServers":{}}');
  });

  test('returns plugin cores and enabled state', () async {
    final (status, body) = await _request(
      client,
      base,
      'GET',
      '/api/v1/plugins',
      token: _token,
    );

    expect(status, HttpStatus.ok);
    final json = jsonDecode(body) as Map;
    expect((json['plugins'] as List), hasLength(2));
    expect(json['enabled'], ['first']);
  });

  test('returns plugin dependencies and updates enabled state', () async {
    final (missingStatus, missingBody) = await _request(
      client,
      base,
      'GET',
      '/api/v1/plugins/second/missing-dependencies',
      token: _token,
    );
    final (dependentsStatus, dependentsBody) = await _request(
      client,
      base,
      'GET',
      '/api/v1/plugins/first/dependents',
      token: _token,
    );
    final (setStatus, _) = await _request(
      client,
      base,
      'PUT',
      '/api/v1/plugins/enabled',
      token: _token,
      body: {
        'ids': ['first', 'second'],
        'enabled': false,
      },
    );

    expect(missingStatus, HttpStatus.ok);
    expect((jsonDecode(missingBody) as Map)['ids'], ['first']);
    expect(dependentsStatus, HttpStatus.ok);
    expect((jsonDecode(dependentsBody) as Map)['ids'], ['second']);
    expect(setStatus, HttpStatus.noContent);
    expect(pluginApi.lastIds, {'first', 'second'});
    expect(pluginApi.lastEnabled, isFalse);
  });

  test('rejects plugin changes while the agent is running', () async {
    pluginApi.busy = true;

    final (status, body) = await _request(
      client,
      base,
      'PUT',
      '/api/v1/plugins/enabled',
      token: _token,
      body: {
        'ids': ['first'],
        'enabled': false,
      },
    );

    expect(status, HttpStatus.conflict);
    expect((jsonDecode(body) as Map)['error']['code'], 'agent_busy');
    expect(pluginApi.lastIds, isNull);
  });

  test('reads and writes plugin settings', () async {
    final (readStatus, readBody) = await _request(
      client,
      base,
      'GET',
      '/api/v1/plugins/first/settings',
      token: _token,
    );
    final (writeStatus, _) = await _request(
      client,
      base,
      'PUT',
      '/api/v1/plugins/first/settings',
      token: _token,
      body: {
        'value': {'commands': []},
      },
    );

    expect(readStatus, HttpStatus.ok);
    expect((jsonDecode(readBody) as Map)['version'], 1);
    expect(writeStatus, HttpStatus.noContent);
    expect(pluginApi.savedSettings, {'commands': []});
  });

  test('returns a server-side security report', () async {
    final (status, body) = await _request(
      client,
      base,
      'GET',
      '/api/v1/security/audit',
      token: _token,
    );

    expect(status, HttpStatus.ok);
    final json = jsonDecode(body) as Map;
    expect(json['status'], 'baseline');
    expect(json['mode'], 'headless');
    expect(json['generatedAt'], endsWith('Z'));
    expect((json['findings'] as List).single['code'], 'headlessApi');
    expect(securityAudit.mode, SecurityRunMode.headless);
  });

  test('reads and saves push settings', () async {
    final (getStatus, getBody) = await _request(
      client,
      base,
      'GET',
      '/api/v1/push',
      token: _token,
    );
    final (putStatus, _) = await _request(
      client,
      base,
      'PUT',
      '/api/v1/push',
      token: _token,
      body: {
        'enabled': true,
        'relayUrl': 'https://relay.test',
        'token': 'relay-token',
      },
    );
    final (testStatus, _) = await _request(
      client,
      base,
      'POST',
      '/api/v1/push/test',
      token: _token,
    );

    expect(getStatus, HttpStatus.ok);
    expect((jsonDecode(getBody) as Map)['hasToken'], isFalse);
    expect(putStatus, HttpStatus.noContent);
    expect(push.saved?.enabled, isTrue);
    expect(push.saved?.relayUrl, 'https://relay.test');
    expect(push.token, 'relay-token');
    expect(testStatus, HttpStatus.noContent);
    expect(push.tested, isTrue);
  });

  test('rejects a push test without configuration', () async {
    push.busy = true;

    final (status, body) = await _request(
      client,
      base,
      'POST',
      '/api/v1/push/test',
      token: _token,
    );

    expect(status, HttpStatus.conflict);
    expect((jsonDecode(body) as Map)['error']['code'], 'push_not_configured');
  });

  test('unknown chat subresources return 404', () async {
    for (final path in [
      '/api/v1/chats/missing/messages',
      '/api/v1/chats/missing/runs',
      '/api/v1/chats/missing/events',
    ]) {
      final (status, _) = await _request(
        client,
        base,
        'GET',
        path,
        token: _token,
      );
      expect(status, HttpStatus.notFound, reason: path);
    }
  });

  test('unknown host is rejected when creating a chat', () async {
    final (status, body) = await _request(
      client,
      base,
      'POST',
      '/api/v1/chats',
      token: _token,
      body: {'hostId': 'missing'},
    );

    expect(status, HttpStatus.notFound);
    expect((jsonDecode(body) as Map)['error'], contains('code'));
  });

  test('upserts a chat by id', () async {
    final (status, _) = await _request(
      client,
      base,
      'PUT',
      '/api/v1/chats/new-chat',
      token: _token,
      body: {
        'hostId': 'local',
        'title': 'New chat',
        'policyMode': 'ask',
        'createdAt': '2026-11-11T00:00:00Z',
        'updatedAt': '2026-11-11T00:00:00Z',
      },
    );

    expect(status, HttpStatus.noContent);
    expect(backend.savedChatId, 'new-chat');
    expect(backend.savedChatTitle, 'New chat');
  });

  test('updates chat model, policy and workspace', () async {
    final (status, _) = await _request(
      client,
      base,
      'PATCH',
      '/api/v1/chats/c1',
      token: _token,
      body: {
        'title': 'Renamed',
        'model': 'model/x',
        'policyMode': 'yolo',
        'workspace': '/work',
        'workspaceSpecified': true,
      },
    );

    expect(status, HttpStatus.noContent);
    expect(backend.updatedTitle, 'Renamed');
    expect(backend.updatedModel, 'model/x');
    expect(backend.updatedPolicy, PolicyMode.yolo);
    expect(backend.updatedWorkspace, '/work');
  });

  test('chat state endpoints report unsupported without ChatApi', () async {
    for (final path in [
      '/api/v1/settings',
      '/api/v1/models',
      '/api/v1/chats/c1/usage',
      '/api/v1/chats/c1/project',
    ]) {
      final (status, _) = await _request(
        client,
        base,
        'GET',
        path,
        token: _token,
      );
      expect(status, HttpStatus.notImplemented, reason: path);
    }
  });

  test('session endpoints report unsupported without ChatApi', () async {
    final (status, body) = await _request(
      client,
      base,
      'GET',
      '/api/v1/chats/c1/session',
      token: _token,
    );

    expect(status, HttpStatus.notImplemented);
    expect((jsonDecode(body) as Map)['error'], contains('code'));
  });

  test('returns chat journal and pending cards', () async {
    final (status, body) = await _request(
      client,
      base,
      'GET',
      '/api/v1/chats/c1',
      token: _token,
    );

    expect(status, HttpStatus.ok);
    final json = jsonDecode(body) as Map;
    expect((json['messages'] as List).single['text'], 'hello');
    expect((json['approvals'] as List).single['id'], 'a1');
    expect((json['questions'] as List).single['text'], 'continue?');
  });

  test('accepts a message and forwards sendNow and clientMessageId', () async {
    final (status, _) = await _request(
      client,
      base,
      'POST',
      '/api/v1/chats/c1/messages',
      token: _token,
      body: {'text': 'do it', 'sendNow': true, 'clientMessageId': 'client-1'},
    );

    expect(status, HttpStatus.accepted);
    expect(backend.sent, [('c1', 'do it', true)]);
    expect(backend.clientMessageIds, ['client-1']);
  });

  test('resolves approvals with the requested scope', () async {
    final (status, _) = await _request(
      client,
      base,
      'PUT',
      '/api/v1/approvals/a1/decision',
      token: _token,
      body: {'action': 'allowTurn'},
    );

    expect(status, HttpStatus.noContent);
    expect(backend.decisions, [ApprovalAction.allowTurn]);
  });

  test('exposes messages and runs as subresources', () async {
    final (messagesStatus, messagesBody) = await _request(
      client,
      base,
      'GET',
      '/api/v1/chats/c1/messages',
      token: _token,
    );
    final (runsStatus, runsBody) = await _request(
      client,
      base,
      'GET',
      '/api/v1/chats/c1/runs',
      token: _token,
    );

    expect(messagesStatus, HttpStatus.ok);
    expect((jsonDecode(messagesBody) as Map)['messages'], hasLength(1));
    expect(runsStatus, HttpStatus.ok);
    expect((jsonDecode(runsBody) as Map)['runs'], isEmpty);
  });

  test('reports pending scheduled tasks and passes the fork choice', () async {
    backend.pendingTasks = 2;
    final (countStatus, countBody) = await _request(
      client,
      base,
      'GET',
      '/api/v1/chats/c1/scheduled-tasks?untilMessageId=a1',
      token: _token,
    );
    expect(countStatus, HttpStatus.ok);
    expect((jsonDecode(countBody) as Map)['count'], 2);
    // Счётчик обязан знать линию форка: ниже неё задачи не переносятся.
    expect(backend.countsUntilMessageId, 'a1');

    final (forkStatus, _) = await _request(
      client,
      base,
      'POST',
      '/api/v1/chats/c1/forks',
      token: _token,
      body: {'title': 'copy', 'untilMessageId': 'a1', 'copyPendingTasks': true},
    );
    expect(forkStatus, HttpStatus.created);
    expect(backend.copiedPendingTasks, isTrue);
    expect(backend.forkedUntilMessageId, 'a1');
  });

  test('uses resources for presence and stopping a turn', () async {
    final (presence, _) = await _request(
      client,
      base,
      'PUT',
      '/api/v1/chats/c1/presence',
      token: _token,
    );
    final (turn, _) = await _request(
      client,
      base,
      'DELETE',
      '/api/v1/chats/c1/turn',
      token: _token,
    );

    expect(presence, HttpStatus.noContent);
    expect(turn, HttpStatus.noContent);
    expect(backend.opened, 1);
    expect(backend.stopped, 1);
  });

  test('answers questions and resolves edit changes', () async {
    final (answer, _) = await _request(
      client,
      base,
      'PUT',
      '/api/v1/questions/q1/answer',
      token: _token,
      body: {'answer': 'yes'},
    );
    final (choice, _) = await _request(
      client,
      base,
      'PUT',
      '/api/v1/edit-file-changes/e1/decision',
      token: _token,
      body: {'choice': 'cancel'},
    );

    expect(answer, HttpStatus.noContent);
    expect(choice, HttpStatus.noContent);
    expect(backend.answers, ['yes']);
    expect(backend.choices, [EditFileChangesChoice.cancel]);
  });

  test('streams more than one event on the same connection', () async {
    final request = await client.getUrl(
      Uri.parse('$base/api/v1/events?chatId=c1'),
    );
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
    final response = await request.close();
    final lines = StreamIterator(
      response
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(const Duration(seconds: 3)),
    );
    expect(await lines.moveNext(), isTrue);
    expect(lines.current, ': connected');

    backend
      ..emit(const AgentTurnStarted('c1'))
      ..emit(
        const ApprovalRequest(
          id: 'a1',
          chatId: 'c1',
          toolName: 'run_command',
          summary: 'ls',
          reason: 'ask',
        ),
      );

    final data = <String>[];
    while (await lines.moveNext()) {
      if (lines.current.startsWith('data:')) data.add(lines.current);
      if (data.length == 2) break;
    }
    await lines.cancel();
    expect(data, hasLength(2));
  });

  test('queue mutations require item id and expected revision', () async {
    final queueSession = _FakeQueueSession();
    final queueServer = ApiServer(
      backend,
      _token,
      port: 0,
      requireSession: false,
      chat: _FakeQueueChatApi(queueSession),
    );
    final port = await queueServer.start();
    addTearDown(queueServer.stop);
    final queueBase = 'http://127.0.0.1:$port';

    final (snapshotStatus, snapshotBody) = await _request(
      client,
      queueBase,
      'GET',
      '/api/v1/chats/c1/session',
      token: _token,
    );
    expect(snapshotStatus, HttpStatus.ok);
    final snapshot = jsonDecode(snapshotBody) as Map;
    expect(snapshot['queueRevision'], 3);
    expect(
      [for (final item in snapshot['queue'] as List) item['id']],
      ['q1', 'q2', 'q3'],
    );

    final (staleStatus, staleBody) = await _request(
      client,
      queueBase,
      'PATCH',
      '/api/v1/chats/c1/queue/q3',
      token: _token,
      body: {'position': 0, 'expectedRevision': 2},
    );
    expect(staleStatus, HttpStatus.conflict);
    expect((jsonDecode(staleBody) as Map)['error']['code'], 'queue_conflict');
    expect(
      [for (final item in queueSession.items) item.id],
      ['q1', 'q2', 'q3'],
    );

    final (missingStatus, _) = await _request(
      client,
      queueBase,
      'PATCH',
      '/api/v1/chats/c1/queue/missing',
      token: _token,
      body: {'position': 0, 'expectedRevision': 3},
    );
    expect(missingStatus, HttpStatus.conflict);

    final (promoteStatus, _) = await _request(
      client,
      queueBase,
      'PATCH',
      '/api/v1/chats/c1/queue/q3',
      token: _token,
      body: {'position': 0, 'expectedRevision': 3},
    );
    expect(promoteStatus, HttpStatus.noContent);
    expect(
      [for (final item in queueSession.items) item.id],
      ['q3', 'q1', 'q2'],
    );
    expect(queueSession.revision, 4);

    final (staleDeleteStatus, _) = await _request(
      client,
      queueBase,
      'DELETE',
      '/api/v1/chats/c1/queue/q1?expectedRevision=3',
      token: _token,
    );
    expect(staleDeleteStatus, HttpStatus.conflict);
    expect(queueSession.items, hasLength(3));

    final (deleteStatus, _) = await _request(
      client,
      queueBase,
      'DELETE',
      '/api/v1/chats/c1/queue/q1?expectedRevision=4',
      token: _token,
    );
    expect(deleteStatus, HttpStatus.noContent);
    expect([for (final item in queueSession.items) item.id], ['q3', 'q2']);
    expect(queueSession.revision, 5);
  });

  test('queue mutation without expected revision is rejected', () async {
    final queueServer = ApiServer(
      backend,
      _token,
      port: 0,
      requireSession: false,
      chat: _FakeQueueChatApi(_FakeQueueSession()),
    );
    final port = await queueServer.start();
    addTearDown(queueServer.stop);
    final queueBase = 'http://127.0.0.1:$port';

    final (patchStatus, patchBody) = await _request(
      client,
      queueBase,
      'PATCH',
      '/api/v1/chats/c1/queue/q1',
      token: _token,
      body: {'position': 0},
    );
    expect(patchStatus, HttpStatus.badRequest);
    expect(
      (jsonDecode(patchBody) as Map)['error']['code'],
      'revision_required',
    );

    final (deleteStatus, deleteBody) = await _request(
      client,
      queueBase,
      'DELETE',
      '/api/v1/chats/c1/queue/q1',
      token: _token,
    );
    expect(deleteStatus, HttpStatus.badRequest);
    expect(
      (jsonDecode(deleteBody) as Map)['error']['code'],
      'revision_required',
    );
  });

  test('streams chatChanged and full queue snapshots', () async {
    final request = await client.getUrl(Uri.parse('$base/api/v1/events'));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
    final response = await request.close();
    final lines = StreamIterator(
      response.transform(utf8.decoder).transform(const LineSplitter()),
    );
    expect(await lines.moveNext(), isTrue);
    expect(lines.current, ': connected');

    backend.emit(
      AgentQueueChanged('c1', [const QueuedPrompt.user('queued')], revision: 4),
    );

    String? event;
    String? data;
    while (await lines.moveNext()) {
      if (lines.current.startsWith('event:')) event = lines.current;
      if (lines.current.startsWith('data:')) data = lines.current;
      if (event != null && data != null) break;
    }
    expect(event, 'event: queueChanged');
    final queue = jsonDecode(data!.replaceFirst('data: ', '')) as Map;
    expect(queue['queueRevision'], 4);
    expect((queue['items'] as List).single['text'], 'queued');

    event = null;
    data = null;
    final (status, _) = await _request(
      client,
      base,
      'PATCH',
      '/api/v1/chats/c1',
      token: _token,
      body: {'title': 'Renamed'},
    );
    expect(status, HttpStatus.noContent);
    while (await lines.moveNext()) {
      if (lines.current.startsWith('event:')) {
        event = lines.current;
        continue;
      }
      if (lines.current.startsWith('data:')) {
        data = lines.current;
        if (event == 'event: chatChanged') break;
      }
    }
    await lines.cancel();
    expect(event, 'event: chatChanged');
    expect(jsonDecode(data!.replaceFirst('data: ', ''))['chatId'], 'c1');
  });

  test('streams chatDeleted after a chat is removed', () async {
    final request = await client.getUrl(Uri.parse('$base/api/v1/events'));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
    final response = await request.close();
    final lines = StreamIterator(
      response.transform(utf8.decoder).transform(const LineSplitter()),
    );
    expect(await lines.moveNext(), isTrue);
    expect(lines.current, ': connected');

    final (status, body) = await _request(
      client,
      base,
      'DELETE',
      '/api/v1/chats/c1',
      token: _token,
    );
    expect(status, HttpStatus.ok);
    expect((jsonDecode(body) as Map)['chatIds'], ['c1']);

    String? event;
    String? data;
    while (await lines.moveNext()) {
      if (lines.current.startsWith('event:')) event = lines.current;
      if (lines.current.startsWith('data:')) data = lines.current;
      if (event == 'event: chatDeleted' && data != null) break;
    }
    await lines.cancel();
    expect(event, 'event: chatDeleted');
    expect(jsonDecode(data!.replaceFirst('data: ', ''))['chatId'], 'c1');
  });

  test('streams chatDeleted for subagents removed with the chat', () async {
    backend.deletedChatIds = ['c1', 's1'];
    final request = await client.getUrl(Uri.parse('$base/api/v1/events'));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
    final response = await request.close();
    final lines = StreamIterator(
      response.transform(utf8.decoder).transform(const LineSplitter()),
    );
    expect(await lines.moveNext(), isTrue);
    expect(lines.current, ': connected');

    final (status, body) = await _request(
      client,
      base,
      'DELETE',
      '/api/v1/chats/c1',
      token: _token,
    );
    expect(status, HttpStatus.ok);
    expect((jsonDecode(body) as Map)['chatIds'], ['c1', 's1']);

    final deleted = <String>[];
    String? event;
    while (await lines.moveNext()) {
      if (lines.current.startsWith('event:')) event = lines.current;
      if (lines.current.startsWith('data:')) {
        if (event == 'event: chatDeleted') {
          deleted.add(
            jsonDecode(lines.current.replaceFirst('data: ', ''))['chatId']
                as String,
          );
          if (deleted.length == 2) break;
        }
      }
    }
    await lines.cancel();
    expect(deleted, ['c1', 's1']);
  });

  test(
    'streams chatDeleted for every chat removed by history cleanup',
    () async {
      final request = await client.getUrl(Uri.parse('$base/api/v1/events'));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
      final response = await request.close();
      final lines = StreamIterator(
        response.transform(utf8.decoder).transform(const LineSplitter()),
      );
      expect(await lines.moveNext(), isTrue);
      expect(lines.current, ': connected');

      final (status, _) = await _request(
        client,
        base,
        'POST',
        '/api/v1/data/history/clear',
        token: _token,
        body: {'olderThanDays': 30},
      );
      expect(status, HttpStatus.ok);

      String? event;
      String? data;
      while (await lines.moveNext()) {
        if (lines.current.startsWith('event:')) event = lines.current;
        if (lines.current.startsWith('data:')) data = lines.current;
        if (event == 'event: chatDeleted' && data != null) break;
      }
      await lines.cancel();
      expect(event, 'event: chatDeleted');
      expect(jsonDecode(data!.replaceFirst('data: ', ''))['chatId'], 'c1');
    },
  );

  test('streams resolved cards over SSE', () async {
    final request = await client.getUrl(Uri.parse('$base/api/v1/events'));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
    final response = await request.close();
    final lines = StreamIterator(
      response.transform(utf8.decoder).transform(const LineSplitter()),
    );
    expect(await lines.moveNext(), isTrue);
    expect(lines.current, ': connected');

    backend.emit(const ApprovalResolved(chatId: 'c1', requestId: 'a1'));

    String? event;
    String? data;
    while (await lines.moveNext()) {
      if (lines.current.startsWith('event:')) event = lines.current;
      if (lines.current.startsWith('data:')) data = lines.current;
      if (event != null && data != null) break;
    }
    await lines.cancel();
    expect(event, 'event: approvalResolved');
    expect(jsonDecode(data!.replaceFirst('data: ', ''))['requestId'], 'a1');
  });

  test('publishes state changes after mutating requests', () async {
    final request = await client.getUrl(Uri.parse('$base/api/v1/events'));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
    final response = await request.close();
    final lines = StreamIterator(
      response.transform(utf8.decoder).transform(const LineSplitter()),
    );
    expect(await lines.moveNext(), isTrue);
    expect(lines.current, ': connected');

    final (status, _) = await _request(
      client,
      base,
      'PUT',
      '/api/v1/chats/c1',
      token: _token,
      body: {'title': 'Renamed'},
    );
    expect(status, HttpStatus.noContent);

    String? event;
    String? data;
    while (await lines.moveNext()) {
      if (lines.current.startsWith('event:')) event = lines.current;
      if (lines.current.startsWith('data:')) data = lines.current;
      if (event != null && data != null) break;
    }
    await lines.cancel();
    expect(event, 'event: stateAreaChanged');
    expect(jsonDecode(data!.replaceFirst('data: ', ''))['area'], 'chats');
  });

  test('streams agent events over SSE', () async {
    final request = await client.getUrl(
      Uri.parse('$base/api/v1/events?chatId=c1'),
    );
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
    final response = await request.close();
    final lines = StreamIterator(
      response
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(const Duration(seconds: 3)),
    );
    // Первая строка подтверждает, что сервер подписался на события.
    expect(await lines.moveNext(), isTrue);
    expect(lines.current, ': connected');
    backend.emit(const AgentTurnStarted('c1'));

    String? event;
    String? data;
    while (await lines.moveNext()) {
      if (lines.current.startsWith('event:')) event = lines.current;
      if (lines.current.startsWith('data:')) data = lines.current;
      if (event != null && data != null) break;
    }
    await lines.cancel();
    expect(event, 'event: turnStarted');
    expect(jsonDecode(data!.replaceFirst('data: ', ''))['chatId'], 'c1');
  });

  test('streams unknown context window in usage events', () async {
    final request = await client.getUrl(
      Uri.parse('$base/api/v1/events?chatId=c1'),
    );
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
    final response = await request.close();
    final lines = StreamIterator(
      response
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(const Duration(seconds: 3)),
    );
    expect(await lines.moveNext(), isTrue);
    expect(lines.current, ': connected');
    backend.emit(
      const AgentUsageUpdated('c1', 123, 32000, contextWindowKnown: false),
    );

    String? event;
    String? data;
    while (await lines.moveNext()) {
      if (lines.current.startsWith('event:')) event = lines.current;
      if (lines.current.startsWith('data:')) data = lines.current;
      if (event != null && data != null) break;
    }
    await lines.cancel();
    expect(event, 'event: usage');
    final json = jsonDecode(data!.replaceFirst('data: ', '')) as Map;
    expect(json['contextWindowKnown'], false);
  });

  group('settings api', () {
    late _FakeSettings settings;
    late ApiServer settingsServer;
    late String settingsBase;

    setUp(() async {
      settings = _FakeSettings();
      settingsServer = ApiServer(
        backend,
        _token,
        port: 0,
        requireSession: false,
        settingsApi: settings,
      );
      final port = await settingsServer.start();
      settingsBase = 'http://127.0.0.1:$port';
    });

    tearDown(() => settingsServer.stop());

    test('returns the settings snapshot', () async {
      final (status, body) = await _request(
        client,
        settingsBase,
        'GET',
        '/api/v1/settings',
        token: _token,
      );

      expect(status, HttpStatus.ok);
      final json = jsonDecode(body) as Map<String, dynamic>;
      expect(json['defaultModel'], 'openai/gpt-4o');
      expect(json['defaultReasoning'], 'high');
      expect(json['pinnedModels'], ['openai/gpt-4o']);
      expect(json['steps'], containsPair('thoughts', 'all'));
      expect((json['catalog'] as Map)['models'], hasLength(1));
    });

    test('exposes model runtime and routes load/unload', () async {
      final (status, body) = await _request(
        client,
        settingsBase,
        'GET',
        '/api/v1/models/runtime',
        token: _token,
      );
      expect(status, HttpStatus.ok);
      expect(jsonDecode(body), containsPair('providers', isEmpty));

      final (loadStatus, _) = await _request(
        client,
        settingsBase,
        'POST',
        '/api/v1/models/runtime/load',
        token: _token,
        body: {'model': 'llamacpp:qwen'},
      );
      expect(loadStatus, HttpStatus.noContent);
      expect(settings.runtime.loads, ['llamacpp:qwen']);

      final (unloadStatus, _) = await _request(
        client,
        settingsBase,
        'POST',
        '/api/v1/models/runtime/unload',
        token: _token,
        body: {'model': 'llamacpp:qwen'},
      );
      expect(unloadStatus, HttpStatus.noContent);
      expect(settings.runtime.unloads, ['llamacpp:qwen']);
    });

    test('serves local model files and routes actions', () async {
      final (status, body) = await _request(
        client,
        settingsBase,
        'GET',
        '/api/v1/models/files',
        token: _token,
      );
      expect(status, HttpStatus.ok);
      expect((jsonDecode(body) as Map)['supported'], isTrue);

      final (installStatus, installBody) = await _request(
        client,
        settingsBase,
        'POST',
        '/api/v1/models/files/install',
        token: _token,
        body: {'source': 'hf://owner/repo/model.gguf', 'name': 'Model'},
      );
      expect(installStatus, HttpStatus.ok);
      expect(jsonDecode(installBody), {'id': 'model-1'});
      expect(settings.localModelsApi.installs, ['hf://owner/repo/model.gguf']);

      final (importStatus, _) = await _request(
        client,
        settingsBase,
        'POST',
        '/api/v1/models/files/import',
        token: _token,
        body: {'path': '/models/local.gguf'},
      );
      expect(importStatus, HttpStatus.ok);
      expect(settings.localModelsApi.imports, ['/models/local.gguf']);

      final (settingsStatus, _) = await _request(
        client,
        settingsBase,
        'PATCH',
        '/api/v1/models/files/model-1',
        token: _token,
        body: {
          'settings': {'contextSize': 8192, 'supportsTools': false},
        },
      );
      expect(settingsStatus, HttpStatus.noContent);
      expect(settings.localModelsApi.settings?.contextSize, 8192);
      expect(settings.localModelsApi.settings?.supportsTools, isFalse);

      final (autoStatus, _) = await _request(
        client,
        settingsBase,
        'PUT',
        '/api/v1/models/files/auto-unload',
        token: _token,
        body: {'minutes': 30},
      );
      expect(autoStatus, HttpStatus.noContent);
      expect(settings.localModelsApi.autoUnload, 30);

      final (deleteStatus, _) = await _request(
        client,
        settingsBase,
        'DELETE',
        '/api/v1/models/files/model-1',
        token: _token,
      );
      expect(deleteStatus, HttpStatus.noContent);
      expect(settings.localModelsApi.deleted, ['model-1']);

      final (clearStatus, _) = await _request(
        client,
        settingsBase,
        'POST',
        '/api/v1/models/files/clear',
        token: _token,
      );
      expect(clearStatus, HttpStatus.noContent);
      expect(settings.localModelsApi.cleared, 1);
    });

    test('reads and writes provider settings', () async {
      final (listStatus, listBody) = await _request(
        client,
        settingsBase,
        'GET',
        '/api/v1/providers',
        token: _token,
      );
      expect(listStatus, HttpStatus.ok);
      final listJson = jsonDecode(listBody) as Map<String, dynamic>;
      expect(listJson['providers'], hasLength(2));

      final (snapshotStatus, snapshotBody) = await _request(
        client,
        settingsBase,
        'GET',
        '/api/v1/settings',
        token: _token,
      );
      expect(snapshotStatus, HttpStatus.ok);
      final json = jsonDecode(snapshotBody) as Map<String, dynamic>;
      final catalog = json['catalog'] as Map;
      expect(catalog['providers'], hasLength(2));
      expect(catalog['providerStatuses'], contains(llamaCppProviderId));

      final (baseUrlStatus, _) = await _request(
        client,
        settingsBase,
        'PUT',
        '/api/v1/providers/$llamaCppProviderId',
        token: _token,
        body: {'baseUrl': 'http://127.0.0.1:9000'},
      );
      expect(baseUrlStatus, HttpStatus.noContent);
      expect(settings.llamaCppBaseUrl, 'http://127.0.0.1:9000');

      final (enabledStatus, _) = await _request(
        client,
        settingsBase,
        'PUT',
        '/api/v1/providers/$llamaCppProviderId',
        token: _token,
        body: {'enabled': false},
      );
      expect(enabledStatus, HttpStatus.noContent);
      expect(settings.llamaCppEnabled, isFalse);

      final (keyStatus, keyBody) = await _request(
        client,
        settingsBase,
        'POST',
        '/api/v1/providers/$llamaCppProviderId/key',
        token: _token,
        body: {'key': 'secret-key'},
      );
      expect(keyStatus, HttpStatus.ok);
      expect(settings.llamaCppApiKey, isTrue);
      final keyJson = jsonDecode(keyBody) as Map<String, dynamic>;
      expect(keyJson['apiKeySet'], isTrue);

      final (checkStatus, checkBody) = await _request(
        client,
        settingsBase,
        'POST',
        '/api/v1/providers/$llamaCppProviderId/check',
        token: _token,
      );
      expect(checkStatus, HttpStatus.ok);
      final statusJson = jsonDecode(checkBody) as Map<String, dynamic>;
      expect(statusJson['enabled'], isFalse);
      expect(statusJson['baseUrl'], 'http://127.0.0.1:9000');
      expect(statusJson['apiKeySet'], isTrue);
      expect(settings.llamaCppChecked, 1);

      final (deleteStatus, _) = await _request(
        client,
        settingsBase,
        'DELETE',
        '/api/v1/providers/$llamaCppProviderId/key',
        token: _token,
      );
      expect(deleteStatus, HttpStatus.noContent);
      expect(settings.llamaCppApiKey, isFalse);
    });

    test('writes an arbitrary setting', () async {
      final (status, _) = await _request(
        client,
        settingsBase,
        'PUT',
        '/api/v1/settings/titleModel',
        token: _token,
        body: {'value': 'openai/gpt-4o-mini'},
      );

      expect(status, HttpStatus.noContent);
      expect(settings.written, {'titleModel': 'openai/gpt-4o-mini'});
    });

    test('saves structured settings without treating them as keys', () async {
      final (pinnedStatus, _) = await _request(
        client,
        settingsBase,
        'PUT',
        '/api/v1/settings/pinned',
        token: _token,
        body: {
          'pinnedModels': ['a', 'b'],
        },
      );
      final (stepsStatus, _) = await _request(
        client,
        settingsBase,
        'PUT',
        '/api/v1/settings/steps',
        token: _token,
        body: {
          'group': false,
          'expandWhileActive': false,
          'thoughts': 'expanded',
          'tools': 'active',
        },
      );
      final (denylistStatus, _) = await _request(
        client,
        settingsBase,
        'PUT',
        '/api/v1/settings/denylist',
        token: _token,
        body: {
          'denylist': ['rm -rf', 'mkfs'],
        },
      );
      final (limitsStatus, _) = await _request(
        client,
        settingsBase,
        'PUT',
        '/api/v1/settings/limits',
        token: _token,
        body: {'limits': const AppLimits(attachmentsPerMessage: 3).toMap()},
      );

      expect(pinnedStatus, HttpStatus.noContent);
      expect(stepsStatus, HttpStatus.noContent);
      expect(denylistStatus, HttpStatus.noContent);
      expect(limitsStatus, HttpStatus.noContent);
      expect(settings.pinned, ['a', 'b']);
      expect(settings.steps.group, isFalse);
      expect(settings.steps.thoughts, ThoughtsVisibility.expanded);
      expect(settings.denylist, ['rm -rf', 'mkfs']);
      expect(settings.limits.attachmentsPerMessage, 3);
      expect(settings.written, isEmpty);
    });

    test('saves and deletes the OpenRouter key', () async {
      final (saveStatus, saveBody) = await _request(
        client,
        settingsBase,
        'POST',
        '/api/v1/providers/$openRouterProviderId/key',
        token: _token,
        body: {'key': 'sk-or-v1-secret-abc'},
      );
      expect(saveStatus, HttpStatus.ok);
      expect(settings.savedKey, 'sk-or-v1-secret-abc');
      expect((jsonDecode(saveBody) as Map)['apiKeySet'], isTrue);

      final (checkStatus, checkBody) = await _request(
        client,
        settingsBase,
        'POST',
        '/api/v1/providers/$openRouterProviderId/check',
        token: _token,
      );
      expect(checkStatus, HttpStatus.ok);
      expect(
        ((jsonDecode(checkBody) as Map)['keyInfo'] as Map)['label'],
        'sk-or-v1-...abc',
      );

      final (deleteStatus, _) = await _request(
        client,
        settingsBase,
        'DELETE',
        '/api/v1/providers/$openRouterProviderId/key',
        token: _token,
      );
      expect(deleteStatus, HttpStatus.noContent);
      expect(settings.savedKey, isNull);
    });

    test('refreshes and remembers models', () async {
      final (refreshStatus, _) = await _request(
        client,
        settingsBase,
        'POST',
        '/api/v1/models/refresh',
        token: _token,
      );
      final (rememberStatus, _) = await _request(
        client,
        settingsBase,
        'POST',
        '/api/v1/models/remember',
        token: _token,
        body: {
          'ids': ['openai/gpt-4o'],
        },
      );

      expect(refreshStatus, HttpStatus.accepted);
      expect(rememberStatus, HttpStatus.noContent);
      expect(settings.refreshed, 1);
      expect(settings.remembered, ['openai/gpt-4o']);
    });
  });

  group('access log', () {
    late Directory temp;
    late ApiAccessLog accessLog;
    late ApiServer logServer;
    late String logBase;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('pw_api_access');
      accessLog = ApiAccessLog(temp);
      logServer = ApiServer(
        backend,
        _token,
        port: 0,
        requireSession: false,
        accessLog: accessLog,
      );
      final port = await logServer.start();
      logBase = 'http://127.0.0.1:$port';
    });

    tearDown(() async {
      await logServer.stop();
      temp.deleteSync(recursive: true);
    });

    test('logs SSE connection open', () async {
      final eventClient = HttpClient();
      addTearDown(() => eventClient.close(force: true));
      final request = await eventClient.getUrl(
        Uri.parse('$logBase/api/v1/events'),
      );
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
      final response = await request.close();
      final lines = StreamIterator(
        response.transform(utf8.decoder).transform(const LineSplitter()),
      );
      expect(await lines.moveNext(), isTrue);
      expect(lines.current, ': connected');
      await lines.cancel();

      final file = File(p.join(temp.path, 'api-access.log'));
      final entries = [
        for (final line in file.readAsLinesSync())
          jsonDecode(line) as Map<String, dynamic>,
      ];
      expect(entries.map((entry) => entry['event']), contains('api.sse.open'));
    });

    test('accepts and echoes a valid request id', () async {
      final request = await client.openUrl(
        'GET',
        Uri.parse('$logBase/api/v1/chats'),
      );
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
      request.headers.set('x-request-id', 'client-request-1');
      request.headers.set('x-client-app', 'ProbablyWorks');
      request.headers.set('x-client-version', '1.2.3');
      request.headers.set('x-client-build', '42');
      request.headers.set('x-client-platform', 'linux');
      final response = await request.close();
      await response.drain<void>();

      expect(response.headers.value('x-request-id'), 'client-request-1');
      final entries = [
        for (final line in File(
          p.join(temp.path, 'api-access.log'),
        ).readAsLinesSync())
          jsonDecode(line) as Map<String, dynamic>,
      ];
      expect(entries.single['requestId'], 'client-request-1');
      expect(entries.single['clientApp'], 'ProbablyWorks');
      expect(entries.single['clientVersion'], '1.2.3');
      expect(entries.single['clientBuild'], '42');
      expect(entries.single['clientPlatform'], 'linux');
    });

    test('replaces an invalid request id', () async {
      final request = await client.openUrl(
        'GET',
        Uri.parse('$logBase/api/v1/chats'),
      );
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
      request.headers.set('x-request-id', 'bad id with spaces');
      final response = await request.close();
      await response.drain<void>();

      final echoed = response.headers.value('x-request-id');
      expect(echoed, isNotNull);
      expect(echoed, isNot('bad id with spaces'));
      expect(echoed, matches(RegExp(r'^[a-f0-9]{16}$')));
    });

    test('logs metadata without health, bodies, query or token', () async {
      await _request(client, logBase, 'GET', '/api/v1/health', token: _token);
      await _request(client, logBase, 'GET', '/api/v1/chats');
      await _request(
        client,
        logBase,
        'GET',
        '/api/v1/chats?secret=value',
        token: 'wrong-token',
      );
      await _request(
        client,
        logBase,
        'GET',
        '/api/v1/chats?secret=value',
        token: _token,
      );

      final file = File(p.join(temp.path, 'api-access.log'));
      final entries = [
        for (final line in file.readAsLinesSync())
          jsonDecode(line) as Map<String, dynamic>,
      ];
      expect(entries, hasLength(3));

      expect(entries.first['status'], HttpStatus.unauthorized);
      expect(entries.first['auth'], 'missing');
      expect(entries.first['token'], isNull);
      expect(entries.first['error'], 'unauthorized');
      expect(entries.first['path'], '/api/v1/chats');

      expect(entries[1]['auth'], 'invalid');
      expect(entries[1]['token'], ApiAccessLog.fingerprint('wrong-token'));
      expect(entries[1]['path'], '/api/v1/chats');

      expect(entries[2]['status'], HttpStatus.ok);
      expect(entries[2]['auth'], 'ok');
      expect(entries[2]['token'], ApiAccessLog.fingerprint(_token));
      expect(entries[2]['method'], 'GET');
      expect(entries[2]['durationMs'], isA<int>());
      expect(entries[2].containsKey('body'), isFalse);
      expect(entries[2]['path'], '/api/v1/chats');
    });
  });

  group('draft api', () {
    late _FakeDraftStore store;
    late _FakeDraftChatApi chatApi;
    late ApiServer draftServer;
    late String draftBase;

    setUp(() async {
      store = _FakeDraftStore();
      chatApi = _FakeDraftChatApi(store);
      draftServer = ApiServer(
        backend,
        _token,
        port: 0,
        requireSession: false,
        chat: chatApi,
      );
      final port = await draftServer.start();
      draftBase = 'http://127.0.0.1:$port';
    });

    tearDown(() => draftServer.stop());

    test('saves drafts and rejects a stale revision', () async {
      final (status, body) = await _request(
        client,
        draftBase,
        'PUT',
        '/api/v1/chats/c1/draft',
        token: _token,
        body: {
          'text': 'hello @app.dart',
          'attachments': [],
          'mentions': [
            {'kind': 'file', 'path': 'src/app.dart', 'start': 6, 'end': 15},
          ],
          'revision': 0,
        },
      );
      expect(status, HttpStatus.ok);
      expect((jsonDecode(body) as Map)['revision'], 1);
      expect(store.draft?.text, 'hello @app.dart');
      expect(store.draft?.mentions.single.path, 'src/app.dart');

      final (conflict, _) = await _request(
        client,
        draftBase,
        'PUT',
        '/api/v1/chats/c1/draft',
        token: _token,
        body: {'text': 'stale', 'attachments': [], 'revision': 0},
      );
      expect(conflict, HttpStatus.conflict);
    });

    test('saves message edits', () async {
      final (status, body) = await _request(
        client,
        draftBase,
        'PUT',
        '/api/v1/chats/c1/message-edits',
        token: _token,
        body: {
          'edits': {
            'm1': {'text': 'edited', 'attachments': []},
          },
          'revision': 0,
        },
      );

      expect(status, HttpStatus.ok);
      expect((jsonDecode(body) as Map)['revision'], 1);
      expect(store.edits['m1']?.text, 'edited');
    });
  });

  group('client sessions', () {
    const clientHeaders = {
      'x-client-app': 'ProbablyWorks',
      'x-client-package': 'probably_works',
      'x-client-version': '1.0.0',
      'x-client-build': '1',
      'x-client-platform': 'linux',
    };

    late ApiServer sessionServer;
    late String sessionBase;
    late DateTime sessionNow;
    late String sessionId;
    late String instanceId;
    late String deviceId;

    setUp(() async {
      sessionNow = DateTime.utc(2026, 11, 24, 12);
      sessionServer = ApiServer(
        backend,
        _token,
        port: 0,
        clientSessions: ClientSessionRegistry(
          ttl: const Duration(seconds: 60),
          sweepInterval: const Duration(hours: 1),
          now: () => sessionNow,
        ),
      );
      final port = await sessionServer.start();
      sessionBase = 'http://127.0.0.1:$port';
      final (status, body) = await _request(
        client,
        sessionBase,
        'POST',
        '/api/v1/client/handshake',
        token: _token,
        headers: clientHeaders,
        body: {'protocol': 1},
      );
      expect(status, HttpStatus.ok);
      final json = jsonDecode(body) as Map;
      sessionId = json['sessionId'] as String;
      instanceId = json['instanceId'] as String;
      deviceId = json['deviceId'] as String;
    });

    tearDown(() => sessionServer.stop());

    test('health exposes the running instance id', () async {
      final (status, body) = await _request(
        client,
        sessionBase,
        'GET',
        '/api/v1/health',
      );

      expect(status, HttpStatus.ok);
      expect(jsonDecode(body), containsPair('instanceId', instanceId));
    });

    test('requires a session after handshake', () async {
      final (without, _) = await _request(
        client,
        sessionBase,
        'GET',
        '/api/v1/chats',
        token: _token,
      );
      expect(without, HttpStatus.badRequest);

      final (withSession, _) = await _request(
        client,
        sessionBase,
        'GET',
        '/api/v1/chats',
        token: _token,
        session: sessionId,
      );
      expect(withSession, HttpStatus.ok);
    });

    test('two handshakes are two sessions with the same device id', () async {
      final (status, body) = await _request(
        client,
        sessionBase,
        'POST',
        '/api/v1/client/handshake',
        token: _token,
        headers: clientHeaders,
        body: {'protocol': 1},
      );
      expect(status, HttpStatus.ok);
      final json = jsonDecode(body) as Map;

      expect(json['sessionId'], isNot(sessionId));
      expect(json['deviceId'], deviceId);
      expect(json['instanceId'], instanceId);

      final (listStatus, listBody) = await _request(
        client,
        sessionBase,
        'GET',
        '/api/v1/client/sessions',
        token: _token,
        session: sessionId,
      );
      expect(listStatus, HttpStatus.ok);
      final sessions = (jsonDecode(listBody) as Map)['sessions'] as List;
      expect(sessions, hasLength(2));
      expect(
        sessions.map((entry) => (entry as Map)['deviceId']),
        everyElement(deviceId),
      );
    });

    test('previous session id is reused while alive', () async {
      final (status, body) = await _request(
        client,
        sessionBase,
        'POST',
        '/api/v1/client/handshake',
        token: _token,
        headers: clientHeaders,
        body: {'protocol': 1, 'previousSessionId': sessionId},
      );

      expect(status, HttpStatus.ok);
      expect((jsonDecode(body) as Map)['sessionId'], sessionId);
    });

    test('heartbeat keeps the session and reports presence', () async {
      sessionNow = sessionNow.add(const Duration(seconds: 30));
      final (status, _) = await _request(
        client,
        sessionBase,
        'PUT',
        '/api/v1/client/session',
        token: _token,
        session: sessionId,
        body: {'focused': true, 'activeChatId': 'c1'},
      );
      expect(status, HttpStatus.ok);

      final (listStatus, body) = await _request(
        client,
        sessionBase,
        'GET',
        '/api/v1/client/sessions',
        token: _token,
        session: sessionId,
      );
      expect(listStatus, HttpStatus.ok);
      final sessions = (jsonDecode(body) as Map)['sessions'] as List;
      final current = sessions.cast<Map>().firstWhere(
        (entry) => entry['id'] == sessionId,
      );
      expect(current['focused'], isTrue);
      expect(current['activeChatId'], 'c1');
      expect(current['current'], isTrue);
      expect(current['online'], isTrue);
    });

    test('an out-of-order presence request does not roll back', () async {
      final (ackStatus, ackBody) = await _request(
        client,
        sessionBase,
        'PUT',
        '/api/v1/client/session',
        token: _token,
        session: sessionId,
        body: {'focused': true, 'activeChatId': 'c2', 'presenceRevision': 2},
      );
      expect(ackStatus, HttpStatus.ok);
      expect((jsonDecode(ackBody) as Map)['presenceRevision'], 2);

      // Периодический heartbeat со старым снимком приходит позже свежего
      // запроса: сервер обязан сохранить более новое присутствие и вернуть
      // принятую ревизию, чтобы отставший клиент догнал её.
      final (staleStatus, staleBody) = await _request(
        client,
        sessionBase,
        'PUT',
        '/api/v1/client/session',
        token: _token,
        session: sessionId,
        body: {'focused': false, 'activeChatId': null, 'presenceRevision': 1},
      );
      expect(staleStatus, HttpStatus.ok);
      expect((jsonDecode(staleBody) as Map)['presenceRevision'], 2);

      final (_, body) = await _request(
        client,
        sessionBase,
        'GET',
        '/api/v1/client/sessions',
        token: _token,
        session: sessionId,
      );
      final current = ((jsonDecode(body) as Map)['sessions'] as List)
          .cast<Map>()
          .firstWhere((entry) => entry['id'] == sessionId);
      expect(current['focused'], isTrue);
      expect(current['activeChatId'], 'c2');
      expect(current['presenceRevision'], 2);
    });

    test('a non-finite presence revision is treated as missing', () async {
      // jsonEncode не воспроизводит бесконечность, а разбор тела получает её
      // из 1e400: без проверки toInt() бросает и запрос отвечает 500.
      final (status, _) = await _request(
        client,
        sessionBase,
        'PUT',
        '/api/v1/client/session',
        token: _token,
        session: sessionId,
        rawBody: '{"focused": true, "presenceRevision": 1e400}',
      );
      expect(status, HttpStatus.ok);

      final (_, list) = await _request(
        client,
        sessionBase,
        'GET',
        '/api/v1/client/sessions',
        token: _token,
        session: sessionId,
      );
      final current = ((jsonDecode(list) as Map)['sessions'] as List)
          .cast<Map>()
          .firstWhere((entry) => entry['id'] == sessionId);
      // Ревизия как у старого клиента: присутствие применяется, номер не растёт.
      expect(current['focused'], isTrue);
      expect(current['presenceRevision'], 0);
    });

    test('handshake returns the presence revision for reload', () async {
      await _request(
        client,
        sessionBase,
        'PUT',
        '/api/v1/client/session',
        token: _token,
        session: sessionId,
        body: {'focused': true, 'activeChatId': 'c1', 'presenceRevision': 9},
      );

      final (status, body) = await _request(
        client,
        sessionBase,
        'POST',
        '/api/v1/client/handshake',
        token: _token,
        headers: clientHeaders,
        body: {'protocol': 1, 'previousSessionId': sessionId},
      );
      expect(status, HttpStatus.ok);
      final json = jsonDecode(body) as Map;
      expect(json['sessionId'], sessionId);
      expect(json['presenceRevision'], 9);
    });

    test(
      'expired session gets 410 and a new handshake gets a new id',
      () async {
        sessionNow = sessionNow.add(const Duration(seconds: 61));

        final (status, body) = await _request(
          client,
          sessionBase,
          'GET',
          '/api/v1/chats',
          token: _token,
          session: sessionId,
        );
        expect(status, HttpStatus.gone);
        expect((jsonDecode(body) as Map)['error']['code'], 'session_expired');

        final (handshakeStatus, handshakeBody) = await _request(
          client,
          sessionBase,
          'POST',
          '/api/v1/client/handshake',
          token: _token,
          headers: clientHeaders,
          body: {'protocol': 1, 'previousSessionId': sessionId},
        );
        expect(handshakeStatus, HttpStatus.ok);
        final json = jsonDecode(handshakeBody) as Map;
        expect(json['sessionId'], isNot(sessionId));
        expect(json['instanceId'], instanceId);
      },
    );

    test('delete closes the session', () async {
      final (status, _) = await _request(
        client,
        sessionBase,
        'DELETE',
        '/api/v1/client/session',
        token: _token,
        session: sessionId,
      );
      expect(status, HttpStatus.noContent);

      final (after, _) = await _request(
        client,
        sessionBase,
        'GET',
        '/api/v1/chats',
        token: _token,
        session: sessionId,
      );
      expect(after, HttpStatus.gone);
    });
  });
}

Future<(int, String)> _request(
  HttpClient client,
  String base,
  String method,
  String path, {
  String? token,
  String? session,
  Map<String, String>? headers,
  Object? body,
  String? rawBody,
}) async {
  final request = await client.openUrl(method, Uri.parse('$base$path'));
  if (token != null) {
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  }
  if (session != null) {
    request.headers.set('x-client-session', session);
  }
  for (final entry in headers?.entries ?? const <MapEntry<String, String>>[]) {
    request.headers.set(entry.key, entry.value);
  }
  if (body != null) {
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
  }
  if (rawBody != null) {
    // Нужно для тел, которые jsonEncode не воспроизводит, например 1e400:
    // бесконечность нельзя закодировать, но её понимает разбор на сервере.
    request.headers.contentType = ContentType.json;
    request.write(rawBody);
  }
  final response = await request.close();
  return (response.statusCode, await utf8.decoder.bind(response).join());
}

final class _FakeBackend implements AgentApi, InteractionEventsApi {
  final _events = StreamController<AgentEvent>.broadcast();
  final _approvals = StreamController<ApprovalRequest>.broadcast();
  final _questions = StreamController<UserQuestion>.broadcast();
  final _editChanges = StreamController<EditFileChangesRequest>.broadcast();
  final _resolutions = StreamController<InteractionResolution>.broadcast();
  final sent = <(String, String, bool)>[];
  final clientMessageIds = <String?>[];
  final decisions = <ApprovalAction>[];
  final answers = <String?>[];
  int pendingTasks = 0;
  bool? copiedPendingTasks;
  String? forkedUntilMessageId;
  String? updatedTitle;
  String? updatedModel;
  PolicyMode? updatedPolicy;
  String? updatedWorkspace;
  String? savedChatId;
  String? savedChatTitle;
  final choices = <EditFileChangesChoice>[];
  var opened = 0;
  var stopped = 0;
  List<String> deletedChatIds = const [];
  final searchQueries = <SearchQuery>[];
  Completer<void>? chatsGate;
  Completer<void>? chatsStarted;
  Object? chatsError;

  final _chat = Chat(
    id: 'c1',
    hostId: 'local',
    title: 'Test chat',
    createdAt: DateTime(2026, 11, 11),
    updatedAt: DateTime(2026, 11, 11),
  );

  void emit(Object event) {
    switch (event) {
      case AgentEvent value:
        _events.add(value);
      case ApprovalRequest value:
        _approvals.add(value);
      case UserQuestion value:
        _questions.add(value);
      case EditFileChangesRequest value:
        _editChanges.add(value);
      case InteractionResolution value:
        _resolutions.add(value);
    }
  }

  Future<void> dispose() async {
    await _events.close();
    await _approvals.close();
    await _questions.close();
    await _editChanges.close();
    await _resolutions.close();
  }

  @override
  AgentStatus get status => AgentStatus.online;

  @override
  Stream<AgentStatus> get statusChanges => const Stream<AgentStatus>.empty();

  @override
  Future<bool> checkConnection() async => true;

  @override
  Set<String> get runningChatIds => const {};

  @override
  Set<String> get waitingChatIds => const {};

  @override
  Stream<List<Chat>> watchChats() => Stream.value([_chat]);

  @override
  Stream<List<Host>> watchHosts() => Stream.value(const []);

  @override
  Future<List<Host>> hosts() async => [
    Host(
      id: 'local',
      name: 'Local',
      kind: HostKind.local,
      systemLabel: 'Ubuntu 24.04.1 LTS',
      createdAt: DateTime(2026, 11, 11),
      updatedAt: DateTime(2026, 11, 11),
      lastCheckAt: DateTime(2026, 11, 11, 12, 30),
      lastLatencyMs: 12,
    ),
  ];

  @override
  Future<List<Chat>> chats() async {
    if (chatsStarted != null && !chatsStarted!.isCompleted) {
      chatsStarted!.complete();
    }
    final gate = chatsGate;
    if (gate != null) await gate.future;
    final error = chatsError;
    if (error != null) throw error;
    return [_chat];
  }

  @override
  Future<List<SearchHit>> search(SearchQuery query) async {
    searchQueries.add(query);
    return const [
      SearchHit(
        kind: SearchHitKind.message,
        title: 'alpha result',
        chatId: 'c1',
        chatTitle: 'Test chat',
        projectId: 'p1',
        messageId: 'm1',
        seq: 3,
        snippet: 'alpha result',
        score: 0.9,
      ),
    ];
  }

  @override
  Future<void> saveChat(Chat chat) async {
    savedChatId = chat.id;
    savedChatTitle = chat.title;
  }

  @override
  Future<void> renameChat(String chatId, String title) => Future<void>.value();

  @override
  Future<void> updateChat(
    String chatId, {
    String? title,
    String? model,
    ReasoningPreference? reasoning,
    PolicyMode? policyMode,
    String? workspace,
    bool workspaceSpecified = false,
  }) async {
    updatedTitle = title;
    updatedModel = model;
    updatedPolicy = policyMode;
    updatedWorkspace = workspace;
  }

  @override
  Future<Chat?> forkChat(
    String chatId, {
    String? title,
    String? untilMessageId,
    bool copyPendingTasks = false,
  }) async {
    copiedPendingTasks = copyPendingTasks;
    forkedUntilMessageId = untilMessageId;
    return _chat;
  }

  String? countsUntilMessageId;

  @override
  Future<int> pendingScheduledTasks(
    String chatId, {
    String? untilMessageId,
  }) async {
    countsUntilMessageId = untilMessageId;
    return pendingTasks;
  }

  @override
  Future<List<String>> deleteChat(String chatId) async =>
      deletedChatIds.isEmpty ? [chatId] : deletedChatIds;

  @override
  Future<Chat> createChat(String hostId) async {
    if (hostId != 'local') {
      throw AgentApiException(404, 'host_not_found', 'host $hostId not found');
    }
    return Chat(
      id: 'c2',
      hostId: hostId,
      title: '',
      createdAt: DateTime(2026, 11, 11),
      updatedAt: DateTime(2026, 11, 11),
    );
  }

  @override
  Future<Chat?> chat(String id) async => id == 'c1' ? _chat : null;

  @override
  Future<List<ChatMessage>> messages(String id) async {
    if (id != 'c1') {
      throw AgentApiException(404, 'chat_not_found', 'chat $id not found');
    }
    return [
      ChatMessage(
        id: 'm1',
        chatId: id,
        seq: 1,
        role: MessageRole.user,
        createdAt: DateTime(2026, 11, 11),
        text: 'hello',
      ),
    ];
  }

  @override
  Future<List<ToolRun>> runs(String id) async {
    if (id != 'c1') {
      throw AgentApiException(404, 'chat_not_found', 'chat $id not found');
    }
    return const [];
  }

  @override
  Future<void> openChat(String id) async {
    opened++;
  }

  @override
  Future<void> send(
    String chatId,
    String text, {
    bool sendNow = false,
    List<AttachmentRef> attachments = const [],
    List<MentionRef> mentions = const [],
    String? clientMessageId,
  }) async {
    sent.add((chatId, text, sendNow));
    clientMessageIds.add(clientMessageId);
  }

  @override
  Future<void> stop(String chatId, {String? reason}) async {
    stopped++;
  }

  @override
  Future<void> resolveApproval(
    String id,
    ApprovalAction action, {
    String? reason,
  }) async {
    decisions.add(action);
  }

  @override
  Future<void> answerQuestion(String id, String? text) async {
    answers.add(text);
  }

  @override
  Future<void> resolveEditFileChanges(
    String id,
    EditFileChangesChoice choice,
  ) async {
    choices.add(choice);
  }

  @override
  Future<List<ApprovalRequest>> pendingApprovals(String chatId) async => const [
    ApprovalRequest(
      id: 'a1',
      chatId: 'c1',
      toolName: 'run_command',
      summary: 'ls',
      reason: 'ask',
    ),
  ];

  @override
  Future<List<UserQuestion>> pendingQuestions(String chatId) async => const [
    UserQuestion(id: 'q1', chatId: 'c1', text: 'continue?'),
  ];

  @override
  Future<List<EditFileChangesRequest>> pendingEditFileChanges(
    String chatId,
  ) async => const [];

  @override
  Future<void> resumeAfterRestart() => Future<void>.value();

  @override
  Stream<AgentEvent> get events => _events.stream;

  @override
  Stream<ApprovalRequest> get approvals => _approvals.stream;

  @override
  Stream<UserQuestion> get questions => _questions.stream;

  @override
  Stream<EditFileChangesRequest> get editChanges => _editChanges.stream;

  @override
  Stream<InteractionResolution> get resolutions => _resolutions.stream;
}

final class _FakeSecurityAudit implements SecurityAuditApi {
  SecurityRunMode? mode;

  @override
  Future<SecurityReport> run({
    SecurityRunMode mode = SecurityRunMode.gui,
  }) async {
    this.mode = mode;
    return SecurityReport(
      generatedAt: DateTime.utc(2026, 11, 12, 10, 0),
      mode: mode,
      platform: 'test',
      status: SecurityStatus.baseline,
      findings: const [
        SecurityFinding(
          code: SecurityFindingCode.headlessApi,
          severity: SecuritySeverity.info,
        ),
      ],
    );
  }
}

final class _FakePlugins implements PluginApi {
  var busy = false;
  Set<String>? lastIds;
  bool? lastEnabled;
  Map<String, Object?>? savedSettings;

  @override
  Future<PluginSnapshot> pluginSnapshot() async => const PluginSnapshot(
    plugins: [
      PluginDescriptor(id: 'first', dependsOn: {}, defaultEnabled: false),
      PluginDescriptor(
        id: 'second',
        dependsOn: {'first'},
        defaultEnabled: false,
      ),
    ],
    enabled: {'first'},
  );

  @override
  Future<Set<String>> missingDependencies(String id) async =>
      id == 'second' ? {'first'} : {};

  @override
  Future<Set<String>> dependents(String id) async =>
      id == 'first' ? {'second'} : {};

  @override
  Future<void> setEnabled(Set<String> ids, {required bool enabled}) async {
    if (busy) {
      throw const AgentApiException(
        409,
        'agent_busy',
        'cannot change plugins while the agent is running',
      );
    }
    lastIds = ids;
    lastEnabled = enabled;
  }

  @override
  plugins.PluginSettings settingsFor(String id) => _FakePluginSettings(this);

  @override
  Future<void> refresh() => Future<void>.value();
}

final class _FakePluginSettings implements plugins.PluginSettings {
  _FakePluginSettings(this._api);

  final _FakePlugins _api;

  @override
  Future<Map<String, Object?>> read() async => {'version': 1};

  @override
  Future<void> save(Map<String, Object?> value) async {
    _api.savedSettings = value;
  }

  @override
  Future<bool> hasSecret(String name) async => false;

  @override
  Future<void> writeSecret(String name, String? value) => Future<void>.value();
}

final class _FakePush implements PushApi {
  PushSettings? saved;
  String? token;
  var tested = false;
  var busy = false;

  @override
  Future<PushSettings> pushSettings() async => const PushSettings();

  @override
  Future<void> savePush(
    PushSettings settings, {
    String? token,
    bool clearToken = false,
  }) async {
    saved = settings;
    this.token = token;
  }

  @override
  Future<void> testPush() async {
    if (busy) {
      throw const AgentApiException(
        409,
        'push_not_configured',
        'configure push relay URL and token first',
      );
    }
    tested = true;
  }
}

final class _FakeDraftChatApi implements ChatApi {
  _FakeDraftChatApi(this.store);

  final _FakeDraftStore store;

  @override
  ChatStore get chatStore => store;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('ChatApi is not used in draft tests');
}

/// ChatApi только с очередью: HTTP-маршруты очереди не ходят в остальные методы.
final class _FakeQueueChatApi implements ChatApi {
  _FakeQueueChatApi(this.queueSession);

  final _FakeQueueSession queueSession;

  @override
  ChatSessionApi session(String chatId) => queueSession;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('ChatApi is used only for queue routes');
}

/// Очередь с ревизией: проверяет, что маршрут передаёт id и ожидаемую ревизию.
final class _FakeQueueSession implements ChatSessionApi {
  final items = <QueuedPrompt>[
    const QueuedPrompt.user('a', id: 'q1'),
    const QueuedPrompt.user('b', id: 'q2'),
    const QueuedPrompt.user('c', id: 'q3'),
  ];
  var revision = 3;

  @override
  bool get isRunning => false;

  @override
  TurnSnapshot get turnSnapshot => const TurnSnapshot();

  @override
  List<QueuedPrompt> get queue => List.unmodifiable(items);

  @override
  int get queueRevision => revision;

  @override
  Future<bool> promoteQueued(
    String itemId, {
    required int expectedRevision,
  }) async {
    if (expectedRevision != revision) return false;
    final index = items.indexWhere((item) => item.id == itemId);
    if (index < 0) return false;
    items.insert(0, items.removeAt(index));
    revision++;
    return true;
  }

  @override
  Future<QueuedPrompt?> takeQueued(
    String itemId, {
    required int expectedRevision,
  }) async {
    if (expectedRevision != revision) return null;
    final index = items.indexWhere((item) => item.id == itemId);
    if (index < 0) return null;
    revision++;
    return items.removeAt(index);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('only queue methods are used in queue tests');
}

final class _FakeDraftStore implements ChatStore {
  var revision = 0;
  ChatDraft? draft;
  Map<String, ChatDraft> edits = {};

  @override
  Future<Chat?> chat(String id) async => Chat(
    id: id,
    hostId: 'local',
    title: 'Chat',
    createdAt: DateTime.utc(2026, 11, 11),
    updatedAt: DateTime.utc(2026, 11, 11),
    draft: draft ?? ChatDraft.empty,
    messageEdits: edits,
    draftRevision: revision,
  );

  @override
  Future<List<ChatMessage>> messages(String id) async => const [];

  @override
  Future<List<ToolRun>> toolRunsForChat(String id) async => const [];

  @override
  Future<void> createChat(Chat chat) => Future<void>.value();

  @override
  Future<void> saveChat(Chat chat) => Future<void>.value();

  @override
  Future<Chat> updateChat(
    String chatId, {
    String? title,
    String? model,
    ReasoningPreference? reasoning,
    PolicyMode? policyMode,
    String? workspace,
    bool workspaceSpecified = false,
    int? expectedRevision,
  }) async => throw UnimplementedError();

  @override
  Stream<String> watchDraftChanges() => const Stream.empty();

  @override
  Future<int> saveDraft(
    String chatId,
    ChatDraft value, {
    int? expectedRevision,
  }) async {
    if (expectedRevision != null && expectedRevision != revision) {
      throw const AgentApiException(409, 'draft_conflict', 'draft changed');
    }
    revision++;
    draft = value;
    return revision;
  }

  @override
  Future<int> saveMessageEdits(
    String chatId,
    Map<String, ChatDraft> value, {
    int? expectedRevision,
  }) async {
    if (expectedRevision != null && expectedRevision != revision) {
      throw const AgentApiException(409, 'draft_conflict', 'draft changed');
    }
    revision++;
    edits = value;
    return revision;
  }
}

final class _FakeData implements DataApi {
  var clearCalls = 0;
  int? lastDays;

  @override
  Future<DataUsage> usage() async => const DataUsage(
    chats: 1,
    subagentChats: 0,
    messages: 2,
    toolRuns: 3,
    scheduledTasks: 1,
    completedTasks: 4,
    failedTasks: 0,
    cancelledTasks: 0,
    chatFilesBytes: 10,
    databaseBytes: 20,
  );

  @override
  Future<HistoryClearResult> clearHistory({int? olderThanDays}) async {
    clearCalls++;
    lastDays = olderThanDays;
    return const HistoryClearResult(
      deletedChats: 1,
      freedBytes: 10,
      compacted: false,
      deletedChatIds: ['c1'],
    );
  }

  @override
  Future<void> resetSettings() => Future<void>.value();
}

final class _FakeMcp implements McpApi {
  var servers = <McpServerConfig>[
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
    'mcp-1': const McpServerState(
      serverId: 'mcp-1',
      status: McpConnectionStatus.connected,
      tools: [McpToolInfo(name: 'search', inputSchema: {})],
    ),
  };
  String? savedId;
  McpServerConfig? saved;
  String? deleted;
  String? restarted;
  String? refreshed;
  String? importedText;
  String? importedFrom;

  @override
  Future<McpSnapshot> mcpSnapshot() async =>
      McpSnapshot(servers: servers, states: states, configError: null);

  @override
  Stream<McpServerState> watchStates() => const Stream.empty();

  @override
  Future<void> ensureReady() => Future<void>.value();

  @override
  Future<void> save(McpServerConfig server) async {
    savedId = server.id;
    saved = server;
  }

  @override
  Future<void> delete(McpServerConfig server) async {
    deleted = server.id;
  }

  @override
  Future<void> restart(McpServerConfig server) async {
    restarted = server.id;
  }

  @override
  Future<void> refreshTools(McpServerConfig server) async {
    refreshed = server.id;
  }

  @override
  Future<McpImportResult> importConfig() async =>
      const McpImportResult.imported('/default/mcp.json');

  @override
  Future<McpImportResult> importConfigText(
    String raw, {
    String? sourcePath,
  }) async {
    importedText = raw;
    importedFrom = sourcePath;
    return McpImportResult.imported(sourcePath);
  }

  @override
  Future<String> exportConfig() async => '{"mcpServers":{}}';
}

final class _FakeLocalModels implements LocalModelsSource {
  final installs = <String>[];
  final imports = <String>[];
  final deleted = <String>[];
  var cleared = 0;
  var autoUnload = 0;
  LocalModelSettings? settings;

  @override
  LocalModelsState get state => const LocalModelsState();

  @override
  Stream<LocalModelsState> watch() => Stream.value(state);

  @override
  Future<void> refresh() => Future<void>.value();

  Future<String> install(String source, {String? name, String? sha256}) =>
      startInstall(source, name: name, sha256: sha256);

  @override
  Future<String> startInstall(
    String source, {
    String? name,
    String? sha256,
  }) async {
    installs.add(source);
    return 'model-1';
  }

  @override
  Future<void> cancelInstall(String id) => Future<void>.value();

  @override
  Future<String> importPath(String path, {String? name}) async {
    imports.add(path);
    return 'model-2';
  }

  @override
  Future<void> delete(String id) async => deleted.add(id);

  @override
  Future<void> updateSettings(String id, LocalModelSettings value) async {
    settings = value;
  }

  @override
  Future<void> clearCache() async => cleared++;

  @override
  Future<void> saveAutoUnload(int minutes) async => autoUnload = minutes;
}

final class _FakeSettings implements AgentSettingsApi {
  String? savedKey;
  final written = <String, String?>{};
  var pinned = <String>['openai/gpt-4o'];
  var denylist = <String>[];
  var securityProfile = const SecurityProfile();
  var steps = const StepsDisplay();
  var limits = const AppLimits();
  var refreshed = 0;
  var remembered = <String>[];
  var llamaCppBaseUrl = llamaCppDefaultBaseUrl;
  var llamaCppEnabled = true;
  var llamaCppApiKey = false;
  var llamaCppChecked = 0;

  final runtime = _FakeRuntime();
  final localModelsApi = _FakeLocalModels();

  @override
  ModelRuntimeSource get modelRuntime => runtime;

  @override
  LocalModelsSource get localModels => localModelsApi;

  LlmProviderStatus get _openRouter => LlmProviderStatus(
    id: openRouterProviderId,
    apiKeySet: savedKey != null,
    apiKeyTail: savedKey == null ? '' : 'abc',
    available: savedKey != null,
    keyInfo: savedKey == null
        ? null
        : const LlmKeyInfo(
            label: 'sk-or-v1-...abc',
            usage: 1,
            limit: 10,
            limitRemaining: 9,
          ),
  );

  LlmProviderStatus get _llamaCpp => LlmProviderStatus(
    id: llamaCppProviderId,
    enabled: llamaCppEnabled,
    baseUrl: llamaCppBaseUrl,
    apiKeySet: llamaCppApiKey,
    apiKeyTail: llamaCppApiKey ? 'key' : '',
    available: true,
    modelCount: 1,
  );

  AgentSettingsSnapshot get _snapshot => AgentSettingsSnapshot(
    defaultModel: 'openai/gpt-4o',
    titleModel: '',
    memoryModel: '',
    subagentModel: '',
    fallbackModel: '',
    defaultReasoning: ReasoningPreference.high,
    memoryReasoning: ReasoningPreference.auto,
    subagentReasoning: ReasoningPreference.auto,
    fallbackReasoning: ReasoningPreference.auto,
    defaultPolicy: 'ask',
    denylist: denylist,
    securityProfile: const SecurityProfile(),
    limits: limits,
    pinnedModels: pinned,
    stepsDisplay: steps,
    catalog: ModelCatalogState(
      models: const [
        LlmModelInfo(id: 'openai/gpt-4o', name: 'GPT-4o', supportsTools: true),
      ],
      providers: const [openRouterDescriptor, llamaCppDescriptor],
      providerStatuses: {
        openRouterProviderId: _openRouter,
        llamaCppProviderId: _llamaCpp,
      },
    ),
  );

  @override
  Future<AgentSettingsSnapshot> load() async => _snapshot;

  @override
  Stream<ModelCatalogState> watchCatalog() => Stream.value(_snapshot.catalog);

  @override
  Stream<List<String>> watchPinnedModels() => Stream.value(pinned);

  @override
  Future<void> writeSetting(String key, String? value) async {
    written[key] = value;
  }

  @override
  Future<void> saveStepsDisplay(StepsDisplay value) async {
    steps = value;
  }

  @override
  Future<void> savePinnedModels(List<String> ids) async {
    pinned = ids;
  }

  @override
  Future<void> saveDenylist(List<String> patterns) async {
    denylist = patterns;
  }

  @override
  Future<void> saveSecurityProfile(SecurityProfile profile) async {
    securityProfile = profile;
  }

  @override
  Future<void> saveLimits(AppLimits value) async {
    limits = value;
  }

  @override
  Future<void> refreshModels() async {
    refreshed++;
  }

  @override
  Future<void> rememberModels(List<String> ids) async {
    remembered = ids;
  }

  @override
  Future<List<LlmProviderStatus>> providerStatuses() async => [
    _openRouter,
    _llamaCpp,
  ];

  @override
  Future<LlmProviderStatus> checkProvider(String providerId) async {
    if (providerId == llamaCppProviderId) llamaCppChecked++;
    return providerId == openRouterProviderId ? _openRouter : _llamaCpp;
  }

  @override
  Future<void> saveProviderBaseUrl(String providerId, String? baseUrl) async {
    if (providerId == llamaCppProviderId) {
      llamaCppBaseUrl = baseUrl ?? llamaCppDefaultBaseUrl;
    }
  }

  @override
  Future<LlmProviderStatus> saveProviderApiKey(
    String providerId,
    String key,
  ) async {
    if (providerId == openRouterProviderId) {
      savedKey = key;
      return _openRouter;
    }
    llamaCppApiKey = true;
    return _llamaCpp;
  }

  @override
  Future<void> deleteProviderApiKey(String providerId) async {
    if (providerId == openRouterProviderId) {
      savedKey = null;
    } else {
      llamaCppApiKey = false;
    }
  }

  @override
  Future<void> setProviderEnabled(String providerId, bool enabled) async {
    if (providerId == llamaCppProviderId) llamaCppEnabled = enabled;
  }
}

final class _FakeRuntime implements ModelRuntimeSource {
  final loads = <String>[];
  final unloads = <String>[];

  @override
  ModelRuntimeState get runtime => const ModelRuntimeState();

  @override
  Stream<ModelRuntimeState> watchRuntime() =>
      Stream.value(const ModelRuntimeState());

  @override
  Future<void> refreshRuntime() => Future<void>.value();

  @override
  Future<void> loadModel(String modelId) async => loads.add(modelId);

  @override
  Future<void> unloadModel(String modelId) async => unloads.add(modelId);
}

final class _FakeProjects implements ProjectsApi {
  ProjectMemory? memory;
  String? instruction;
  Project? found;
  List<WorkspaceEntry> entries = const [];

  @override
  Future<Project?> find({
    required String hostId,
    required String workspace,
  }) async => found;

  @override
  Future<List<WorkspaceEntry>> searchMentions(
    String projectId,
    String query,
  ) async => entries;

  @override
  Stream<ProjectMemory?> watchMemory(String projectId) => Stream.value(memory);

  @override
  Future<void> reviseMemory(String projectId, String instruction) async {
    this.instruction = instruction;
    memory = ProjectMemory(
      projectId: projectId,
      summary: '## Build\n- pnpm',
      updatedAt: DateTime.utc(2026, 11, 13),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('ProjectsApi is not used in this test');
}

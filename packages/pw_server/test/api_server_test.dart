import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:plugin_api/plugin_api.dart' as plugins;
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/agent_settings_api.dart';
import 'package:pw_agent/agent/api/chat_api.dart';
import 'package:pw_agent/agent/api/mcp_api.dart';
import 'package:pw_agent/agent/api/plugin_api.dart';
import 'package:pw_agent/agent/api/projects_api.dart';
import 'package:pw_agent/agent/api/push_api.dart';
import 'package:pw_agent/agent/api/security_audit_api.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/project.dart';
import 'package:pw_agent/agent/domain/search.dart';
import 'package:pw_agent/agent/domain/steps_display.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/agent/mcp/mcp_client_manager.dart';
import 'package:pw_agent/agent/mcp/mcp_service.dart';
import 'package:pw_agent/agent/policy/security_profile.dart';
import 'package:pw_agent/agent/schedule/scheduled_task.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/domain/mcp_server.dart';
import 'package:pw_agent/core/security/security_audit.dart';
import 'package:pw_agent/providers/ai/llama_cpp/llama_cpp_connection.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';
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
    server = ApiServer(
      backend,
      _token,
      port: 0,
      projects: projectsApi,
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
    expect((jsonDecode(hostsBody) as Map)['hosts'], hasLength(1));
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

  test('accepts a message and forwards sendNow', () async {
    final (status, _) = await _request(
      client,
      base,
      'POST',
      '/api/v1/chats/c1/messages',
      token: _token,
      body: {'text': 'do it', 'sendNow': true},
    );

    expect(status, HttpStatus.accepted);
    expect(backend.sent, [('c1', 'do it', true)]);
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

  test('creates a scheduled task', () async {
    final dueAt = DateTime(2026, 11, 12, 9);
    final (status, body) = await _request(
      client,
      base,
      'POST',
      '/api/v1/schedules',
      token: _token,
      body: {
        'chatId': 'c1',
        'prompt': 'later',
        'dueAt': dueAt.toIso8601String(),
      },
    );

    expect(status, HttpStatus.created);
    expect((jsonDecode(body) as Map)['prompt'], 'later');
    expect(backend.scheduled, hasLength(1));
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

  test('serializes schedule timestamps as UTC', () async {
    final local = DateTime(2030, 1, 1, 5);
    backend.scheduled.add(
      ScheduledTask(
        id: 'local',
        chatId: 'c1',
        prompt: 'later',
        dueAt: local,
        status: ScheduledTaskStatus.pending,
        createdAt: local,
        updatedAt: local,
      ),
    );

    final (status, body) = await _request(
      client,
      base,
      'GET',
      '/api/v1/schedules/local',
      token: _token,
    );

    expect(status, HttpStatus.ok);
    final dueRaw = (jsonDecode(body) as Map)['dueAt'] as String;
    expect(dueRaw, endsWith('Z'));
    expect(DateTime.parse(dueRaw).isAtSameMomentAs(local), isTrue);
  });

  test('returns 404 for an unknown schedule', () async {
    final (status, body) = await _request(
      client,
      base,
      'GET',
      '/api/v1/schedules/missing',
      token: _token,
    );

    expect(status, HttpStatus.notFound);
    expect((jsonDecode(body) as Map)['error'], contains('code'));
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
      expect(json['pinnedModels'], ['openai/gpt-4o']);
      expect(json['steps'], containsPair('thoughts', 'all'));
      expect((json['catalog'] as Map)['models'], hasLength(1));
    });

    test('reads and writes llama.cpp settings', () async {
      final (status, body) = await _request(
        client,
        settingsBase,
        'GET',
        '/api/v1/settings',
        token: _token,
      );
      expect(status, HttpStatus.ok);
      final json = jsonDecode(body) as Map<String, dynamic>;
      expect((json['catalog'] as Map)['llamaCpp'], isNotNull);

      final (baseUrlStatus, _) = await _request(
        client,
        settingsBase,
        'PUT',
        '/api/v1/settings/llama-cpp/base-url',
        token: _token,
        body: {'baseUrl': 'http://127.0.0.1:9000'},
      );
      expect(baseUrlStatus, HttpStatus.noContent);
      expect(settings.llamaCppBaseUrl, 'http://127.0.0.1:9000');

      final (enabledStatus, _) = await _request(
        client,
        settingsBase,
        'PUT',
        '/api/v1/settings/llama-cpp/enabled',
        token: _token,
        body: {'enabled': false},
      );
      expect(enabledStatus, HttpStatus.noContent);
      expect(settings.llamaCppEnabled, isFalse);

      final (keyStatus, _) = await _request(
        client,
        settingsBase,
        'POST',
        '/api/v1/settings/llama-cpp/api-key',
        token: _token,
        body: {'key': 'secret-key'},
      );
      expect(keyStatus, HttpStatus.noContent);
      expect(settings.llamaCppApiKey, isTrue);

      final (checkStatus, checkBody) = await _request(
        client,
        settingsBase,
        'POST',
        '/api/v1/settings/llama-cpp/check',
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
        '/api/v1/settings/llama-cpp/api-key',
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

    test('saves and deletes the api key', () async {
      final (saveStatus, _) = await _request(
        client,
        settingsBase,
        'POST',
        '/api/v1/settings/api-key',
        token: _token,
        body: {'key': 'sk-or-v1-secret-abc'},
      );
      expect(saveStatus, HttpStatus.noContent);
      expect(settings.savedKey, 'sk-or-v1-secret-abc');

      final (checkStatus, checkBody) = await _request(
        client,
        settingsBase,
        'POST',
        '/api/v1/settings/api-key/check',
        token: _token,
      );
      expect(checkStatus, HttpStatus.ok);
      expect((jsonDecode(checkBody) as Map)['label'], 'sk-or-v1-...abc');

      final (deleteStatus, _) = await _request(
        client,
        settingsBase,
        'DELETE',
        '/api/v1/settings/api-key',
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
      logServer = ApiServer(backend, _token, port: 0, accessLog: accessLog);
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
      draftServer = ApiServer(backend, _token, port: 0, chat: chatApi);
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
        body: {'text': 'hello', 'attachments': [], 'revision': 0},
      );
      expect(status, HttpStatus.ok);
      expect((jsonDecode(body) as Map)['revision'], 1);
      expect(store.draft?.text, 'hello');

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
}

Future<(int, String)> _request(
  HttpClient client,
  String base,
  String method,
  String path, {
  String? token,
  Object? body,
}) async {
  final request = await client.openUrl(method, Uri.parse('$base$path'));
  if (token != null) {
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  }
  if (body != null) {
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
  }
  final response = await request.close();
  return (response.statusCode, await utf8.decoder.bind(response).join());
}

final class _FakeBackend implements AgentApi {
  final _events = StreamController<AgentEvent>.broadcast();
  final _approvals = StreamController<ApprovalRequest>.broadcast();
  final _questions = StreamController<UserQuestion>.broadcast();
  final _editChanges = StreamController<EditFileChangesRequest>.broadcast();
  final sent = <(String, String, bool)>[];
  final decisions = <ApprovalAction>[];
  final scheduled = <ScheduledTask>[];
  final answers = <String?>[];
  String? updatedTitle;
  String? updatedModel;
  PolicyMode? updatedPolicy;
  String? updatedWorkspace;
  String? savedChatId;
  String? savedChatTitle;
  final choices = <EditFileChangesChoice>[];
  var opened = 0;
  var stopped = 0;
  final searchQueries = <SearchQuery>[];

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
    }
  }

  Future<void> dispose() async {
    await _events.close();
    await _approvals.close();
    await _questions.close();
    await _editChanges.close();
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
      createdAt: DateTime(2026, 11, 11),
      updatedAt: DateTime(2026, 11, 11),
      lastCheckAt: DateTime(2026, 11, 11, 12, 30),
      lastLatencyMs: 12,
    ),
  ];

  @override
  Future<List<Chat>> chats() async => [_chat];

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
  Future<Chat?> forkChat(String chatId, {String? title}) async => _chat;

  @override
  Future<void> deleteChat(String chatId) => Future<void>.value();

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
  }) async {
    sent.add((chatId, text, sendNow));
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
  Future<List<ScheduledTask>> schedules() async => scheduled;

  @override
  Future<ScheduledTask?> scheduledTask(String id) async {
    for (final task in scheduled) {
      if (task.id == id) return task;
    }
    return null;
  }

  @override
  Future<ScheduledTask> schedule({
    required String chatId,
    required String prompt,
    required DateTime dueAt,
  }) async {
    final task = ScheduledTask(
      id: 's1',
      chatId: chatId,
      prompt: prompt,
      dueAt: dueAt,
      status: ScheduledTaskStatus.pending,
      createdAt: DateTime(2026, 11, 11),
      updatedAt: DateTime(2026, 11, 11),
    );
    scheduled.add(task);
    return task;
  }

  @override
  Future<void> cancelSchedule(String id) => Future<void>.value();

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

final class _FakeSettings implements AgentSettingsApi, LlamaCppSettingsApi {
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

  AgentSettingsSnapshot get _snapshot => AgentSettingsSnapshot(
    defaultModel: 'openai/gpt-4o',
    titleModel: '',
    memoryModel: '',
    subagentModel: '',
    fallbackModel: '',
    defaultPolicy: 'ask',
    denylist: denylist,
    securityProfile: const SecurityProfile(),
    limits: limits,
    pinnedModels: pinned,
    stepsDisplay: steps,
    apiKeyTail: savedKey == null ? '' : 'abc',
    catalog: const ModelCatalogState(
      models: [
        LlmModelInfo(id: 'openai/gpt-4o', name: 'GPT-4o', supportsTools: true),
      ],
    ),
    llamaCpp: LlamaCppStatus(
      enabled: llamaCppEnabled,
      baseUrl: llamaCppBaseUrl,
      apiKeySet: llamaCppApiKey,
      apiKeyTail: llamaCppApiKey ? 'key' : '',
      available: true,
      modelCount: 1,
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
  Future<void> saveApiKey(String key) async {
    savedKey = key;
  }

  @override
  Future<void> deleteApiKey() async {
    savedKey = null;
  }

  @override
  Future<LlmKeyInfo?> checkKey() async => savedKey == null
      ? null
      : LlmKeyInfo(
          label: 'sk-or-v1-...abc',
          usage: 1,
          limit: 10,
          limitRemaining: 9,
          isFreeTier: false,
        );

  @override
  Future<void> refreshModels() async {
    refreshed++;
  }

  @override
  Future<void> rememberModels(List<String> ids) async {
    remembered = ids;
  }

  @override
  Future<void> saveLlamaCppBaseUrl(String baseUrl) async {
    llamaCppBaseUrl = baseUrl;
  }

  @override
  Future<void> saveLlamaCppApiKey(String key) async {
    llamaCppApiKey = true;
  }

  @override
  Future<void> deleteLlamaCppApiKey() async {
    llamaCppApiKey = false;
  }

  @override
  Future<void> setLlamaCppEnabled(bool enabled) async {
    llamaCppEnabled = enabled;
  }

  @override
  Future<LlamaCppStatus?> checkLlamaCpp() async {
    llamaCppChecked++;
    return LlamaCppStatus(
      enabled: llamaCppEnabled,
      baseUrl: llamaCppBaseUrl,
      apiKeySet: llamaCppApiKey,
      apiKeyTail: llamaCppApiKey ? 'key' : '',
      available: true,
      modelCount: 1,
      checkedAt: DateTime.utc(2026, 11, 14),
    );
  }
}

final class _FakeProjects implements ProjectsApi {
  ProjectMemory? memory;
  String? instruction;

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

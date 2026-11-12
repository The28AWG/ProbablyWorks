import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/agent_settings_api.dart';
import 'package:pw_agent/agent/api/chat_api.dart';
import 'package:pw_agent/agent/api/hosts_api.dart';
import 'package:pw_agent/agent/api/mcp_api.dart';
import 'package:pw_agent/agent/api/plugin_api.dart';
import 'package:pw_agent/agent/api/projects_api.dart';
import 'package:pw_agent/agent/api/push_api.dart';
import 'package:pw_agent/agent/api/security_audit_api.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/project.dart';
import 'package:pw_agent/agent/domain/steps_display.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/agent/policy/security_profile.dart';
import 'package:pw_agent/agent/schedule/scheduled_task.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/domain/mcp_server.dart';
import 'package:pw_agent/core/security/security_audit.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';
import 'package:pw_server/src/api/api_access_log.dart';

/// Локальный HTTP API поверх агента.
///
/// По умолчанию слушает loopback. Авторизация — `Authorization: Bearer <token>`.
/// API не запускает команды само: все действия идут через [AgentApi], а значит
/// через policy и карточки подтверждения.
final class ApiServer {
  ApiServer(
    this._backend,
    this._token, {
    InternetAddress? address,
    this._port = 7787,
    ChatApi? chat,
    HostsApi? hosts,
    ProjectsApi? projects,
    this.settingsApi,
    this.mcpApi,
    this.pluginApi,
    this.securityAuditApi,
    this.pushApi,
    this.accessLog,
  }) : _address = address ?? InternetAddress.loopbackIPv4,
       _chatApi = chat,
       _hostsApi = hosts,
       _projectsApi = projects;

  static const _maxBodyBytes = 8 << 20;
  static const _eventHeartbeat = Duration(seconds: 15);

  final AgentApi _backend;
  final ChatApi? _chatApi;
  final HostsApi? _hostsApi;
  final ProjectsApi? _projectsApi;
  final AgentSettingsApi? settingsApi;
  final McpApi? mcpApi;
  final PluginApi? pluginApi;
  final SecurityAuditApi? securityAuditApi;
  final PushApi? pushApi;
  final ApiAccessLog? accessLog;
  final String _token;
  final InternetAddress _address;
  final int _port;

  HttpServer? _server;
  final _clients = <HttpResponse>{};
  static final _random = Random.secure();
  static final _requestIdPattern = RegExp(r'^[A-Za-z0-9._:-]{1,64}$');
  final _stateEvents = StreamController<Object>.broadcast();

  /// Запускает сервер и возвращает фактический порт (0 превращается в выбранный ОС).
  Future<int> start() async {
    if (_server != null) throw StateError('API server is already running');
    final server = await HttpServer.bind(_address, _port);
    _server = server;
    server
      ..idleTimeout = const Duration(seconds: 30)
      ..listen(_handle);
    return server.port;
  }

  Future<void> stop() async {
    for (final response in [..._clients]) {
      await response.close();
    }
    _clients.clear();
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final stopwatch = Stopwatch()..start();
    final requestId = _requestId(request);
    response.headers.set('x-request-id', requestId);
    var audit = true;
    var auth = 'ok';
    String? token;
    String? errorCode;
    var sse = false;
    try {
      if (request.method == 'GET' && request.uri.path == '/api/v1/health') {
        audit = false;
        _json(response, HttpStatus.ok, {'ok': true, 'version': '1'});
        return;
      }
      final header = request.headers.value(HttpHeaders.authorizationHeader);
      if (header != null && header.startsWith('Bearer ')) {
        token = ApiAccessLog.fingerprint(header.replaceFirst('Bearer ', ''));
      }
      if (!_authorized(request)) {
        auth = header == null ? 'missing' : 'invalid';
        errorCode = 'unauthorized';
        response.headers.set(
          HttpHeaders.wwwAuthenticateHeader,
          'Bearer realm="probablyworks"',
        );
        _error(
          response,
          HttpStatus.unauthorized,
          'unauthorized',
          'invalid token',
          requestId: requestId,
        );
        return;
      }
      sse = request.method == 'GET' && request.uri.path == '/api/v1/events';
      if (sse) {
        _writeAccess(
          request,
          requestId: requestId,
          event: 'api.sse.open',
          auth: auth,
          token: token,
          status: HttpStatus.ok,
          durationMs: 0,
        );
      }
      await _route(request);
      _publishState(request);
    } on AgentApiException catch (error) {
      errorCode = error.code;
      _error(
        response,
        error.status,
        error.code,
        error.message,
        requestId: requestId,
      );
    } on FormatException catch (error) {
      errorCode = 'bad_json';
      _error(
        response,
        HttpStatus.badRequest,
        'bad_json',
        error.message,
        requestId: requestId,
      );
    } on Object catch (error) {
      errorCode = 'internal_error';
      _error(
        response,
        HttpStatus.internalServerError,
        'internal_error',
        '$error',
        requestId: requestId,
      );
    } finally {
      try {
        await response.close();
      } on Object {
        // Соединение уже закрыто клиентом (например, SSE).
      }
      if (audit) {
        _writeAccess(
          request,
          requestId: requestId,
          event: sse ? 'api.sse.close' : 'api.request',
          auth: auth,
          token: token,
          error: errorCode,
          status: response.statusCode,
          durationMs: stopwatch.elapsedMilliseconds,
        );
      }
    }
  }

  static String _requestId(HttpRequest request) {
    final supplied = request.headers.value('x-request-id');
    if (supplied != null && _requestIdPattern.hasMatch(supplied)) {
      return supplied;
    }
    return _newRequestId();
  }

  static String? _clientHeader(HttpRequest request, String name) {
    final value = request.headers.value(name);
    if (value == null) return null;
    return String.fromCharCodes(value.codeUnits.take(120));
  }

  static String _newRequestId() => [
    for (var i = 0; i < 8; i++)
      _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();

  void _writeAccess(
    HttpRequest request, {
    required String requestId,
    required String event,
    required String auth,
    required int status,
    required int durationMs,
    String? token,
    String? error,
  }) {
    final log = accessLog;
    if (log == null) return;
    log.write({
      'ts': DateTime.now().toUtc().toIso8601String(),
      'event': event,
      'requestId': requestId,
      'method': request.method,
      'path': request.uri.path,
      'status': status,
      'durationMs': durationMs,
      'remote': request.connectionInfo?.remoteAddress.address ?? '',
      'clientApp': _clientHeader(request, 'x-client-app'),
      'clientPackage': _clientHeader(request, 'x-client-package'),
      'clientVersion': _clientHeader(request, 'x-client-version'),
      'clientBuild': _clientHeader(request, 'x-client-build'),
      'clientPlatform': _clientHeader(request, 'x-client-platform'),
      'auth': auth,
      'token': token,
      'error': error,
    });
  }

  /// Сообщает SSE-клиентам, какие списки могли измениться после запроса.
  void _publishState(HttpRequest request) {
    if (request.method == 'GET') return;
    final path = request.uri.pathSegments;
    if (path.length < 3 || path.first != 'api' || path[1] != 'v1') return;
    // Черновик обновляется часто; для него есть отдельное SSE-событие, список чатов не трогаем.
    if (path[2] == 'chats' &&
        path.length > 3 &&
        (path[3] == 'draft' || path[3] == 'message-edits')) {
      return;
    }
    switch (path[2]) {
      case 'hosts':
        _emitState('hosts');
      case 'chats':
        _emitState('chats');
        _emitState('projects');
      case 'projects':
      case 'policy-profiles':
        _emitState('projects');
    }
  }

  void _emitState(String area) {
    if (!_stateEvents.isClosed) _stateEvents.add(_StateChanged(area));
  }

  Future<void> _route(HttpRequest request) async {
    final path = request.uri.pathSegments;
    if (path.length < 3 || path.first != 'api' || path[1] != 'v1') {
      throw const AgentApiException(
        HttpStatus.notFound,
        'not_found',
        'unknown endpoint',
      );
    }
    final rest = path.sublist(3);
    switch (path[2]) {
      case 'mcp':
        if (rest.isEmpty && request.method == 'GET') return _mcp(request);
        if (rest.firstOrNull == 'import' &&
            rest.length == 1 &&
            request.method == 'POST') {
          return _mcpImport(request);
        }
        if (rest.firstOrNull == 'export' &&
            rest.length == 1 &&
            request.method == 'GET') {
          return _mcpExport(request);
        }
        if (rest.firstOrNull == 'ready' &&
            rest.length == 1 &&
            request.method == 'POST') {
          return _mcpReady(request);
        }
        if (rest.length >= 2 && rest.first == 'servers') {
          final id = rest[1];
          if (rest.length == 2) {
            if (request.method == 'PUT') return _saveMcpServer(request, id);
            if (request.method == 'DELETE') {
              return _deleteMcpServer(request, id);
            }
          }
          if (rest.length == 3 &&
              rest[2] == 'restart' &&
              request.method == 'POST') {
            return _restartMcpServer(request, id);
          }
          if (rest.length == 4 &&
              rest[2] == 'tools' &&
              rest[3] == 'refresh' &&
              request.method == 'POST') {
            return _refreshMcpTools(request, id);
          }
        }
      case 'plugins':
        if (rest.isEmpty && request.method == 'GET') return _plugins(request);
        if (rest.length == 1 &&
            rest.first == 'enabled' &&
            request.method == 'PUT') {
          return _setPluginsEnabled(request);
        }
        if (rest.length == 1 &&
            rest.first == 'refresh' &&
            request.method == 'POST') {
          return _refreshPlugins(request);
        }
        if (rest.length == 2) {
          final id = rest.first;
          if (rest[1] == 'settings') {
            if (request.method == 'GET') return _pluginSettings(request, id);
            if (request.method == 'PUT') {
              return _savePluginSettings(request, id);
            }
          }
          if (rest[1] == 'missing-dependencies' && request.method == 'GET') {
            return _pluginMissing(request, id);
          }
          if (rest[1] == 'dependents' && request.method == 'GET') {
            return _pluginDependents(request, id);
          }
        }
      case 'security':
        if (rest.length == 1 &&
            rest.first == 'audit' &&
            request.method == 'GET') {
          return _securityAudit(request);
        }
      case 'push':
        if (rest.isEmpty && request.method == 'GET') {
          return _pushSettings(request);
        }
        if (rest.isEmpty && request.method == 'PUT') {
          return _savePushSettings(request);
        }
        if (rest.length == 1 &&
            rest.first == 'test' &&
            request.method == 'POST') {
          return _testPush(request);
        }
      case 'hosts':
        if (rest.isEmpty && request.method == 'GET') return _hosts(request);
        if (rest.length == 1) {
          if (request.method == 'PUT') return _saveHost(request, rest.first);
          if (request.method == 'DELETE') {
            await _requireHostsApi().deleteHost(rest.first);
            return _json(request.response, HttpStatus.noContent, {});
          }
        }
        if (rest.length == 2 && rest[1] == 'test' && request.method == 'POST') {
          return _testHost(request, rest.first);
        }
        if (rest.length == 2 && rest[1] == 'trust' && request.method == 'PUT') {
          return _trustHost(request, rest.first);
        }
      case 'projects':
        return _routeProjects(request, rest);
      case 'policy-profiles':
        if (rest.isEmpty && request.method == 'GET') {
          return _policyProfiles(request);
        }
        if (rest.length == 1) {
          if (request.method == 'PUT') {
            return _savePolicyProfile(request, rest.first);
          }
          if (request.method == 'DELETE') {
            await _requireProjectsApi().deletePolicyProfile(rest.first);
            return _json(request.response, HttpStatus.noContent, {});
          }
        }
      case 'settings':
        if (rest.isEmpty && request.method == 'GET') return _settings(request);
        if (rest.length == 1 &&
            rest.first == 'pinned' &&
            request.method == 'PUT') {
          return _savePinned(request);
        }
        if (rest.length == 1 &&
            rest.first == 'steps' &&
            request.method == 'PUT') {
          return _saveSteps(request);
        }
        if (rest.length == 1 &&
            rest.first == 'limits' &&
            request.method == 'PUT') {
          return _saveLimits(request);
        }
        if (rest.length == 1 &&
            rest.first == 'denylist' &&
            request.method == 'PUT') {
          return _saveDenylist(request);
        }
        if (rest.length == 1 &&
            rest.first == 'security-profile' &&
            request.method == 'PUT') {
          return _saveSecurityProfile(request);
        }
        if (rest.length == 1 && request.method == 'PUT') {
          return _saveSetting(request, rest.first);
        }
        if (rest.length == 1 &&
            rest.first == 'api-key' &&
            request.method == 'POST') {
          return _saveApiKey(request);
        }
        if (rest.length == 1 &&
            rest.first == 'api-key' &&
            request.method == 'DELETE') {
          await _requireSettingsApi().deleteApiKey();
          return _json(request.response, HttpStatus.noContent, {});
        }
        if (rest.length == 2 &&
            rest.first == 'api-key' &&
            rest[1] == 'check' &&
            request.method == 'POST') {
          return _checkKey(request);
        }
      case 'models':
        if (rest.isEmpty && request.method == 'GET') return _models(request);
        if (rest.length == 1 &&
            rest.first == 'remember' &&
            request.method == 'POST') {
          return _rememberModels(request);
        }
        if (rest.length == 1 &&
            rest.first == 'refresh' &&
            request.method == 'POST') {
          return _refreshModels(request);
        }
      case 'chats':
        return _routeChats(request, rest);
      case 'approvals':
        if (rest.length == 2 &&
            rest[1] == 'decision' &&
            request.method == 'PUT') {
          return _approval(request, rest.first);
        }
      case 'questions':
        if (rest.length == 2 &&
            rest[1] == 'answer' &&
            request.method == 'PUT') {
          return _answer(request, rest.first);
        }
      case 'edit-file-changes':
        if (rest.length == 2 &&
            rest[1] == 'decision' &&
            request.method == 'PUT') {
          return _editFileChanges(request, rest.first);
        }
      case 'schedules':
        if (rest.isEmpty && request.method == 'GET') return _schedules(request);
        if (rest.isEmpty && request.method == 'POST') return _schedule(request);
        if (rest.length == 1 && request.method == 'GET') {
          return _scheduleItem(request, rest.first);
        }
        if (rest.length == 1 && request.method == 'DELETE') {
          await _backend.cancelSchedule(rest.first);
          return _json(request.response, HttpStatus.noContent, {});
        }
      case 'events':
        if (rest.isEmpty && request.method == 'GET') return _events(request);
    }
    throw const AgentApiException(
      HttpStatus.notFound,
      'not_found',
      'unknown endpoint',
    );
  }

  Future<void> _routeChats(HttpRequest request, List<String> rest) async {
    if (rest.isEmpty && request.method == 'GET') return _chats(request);
    if (rest.isEmpty && request.method == 'POST') return _createChat(request);
    if (rest.length == 1) {
      final id = rest.first;
      if (request.method == 'GET') return _chat(request, id);
      if (request.method == 'PUT') return _saveChat(request, id);
      if (request.method == 'PATCH') return _renameChat(request, id);
      if (request.method == 'DELETE') {
        await _backend.deleteChat(id);
        return _json(request.response, HttpStatus.noContent, {});
      }
    }
    if (rest.length >= 2) {
      final chatId = rest.first;
      switch (rest[1]) {
        case 'draft':
          if (rest.length == 2 && request.method == 'PUT') {
            return _saveDraft(request, chatId);
          }
        case 'message-edits':
          if (rest.length == 2 && request.method == 'PUT') {
            return _saveMessageEdits(request, chatId);
          }
        case 'messages':
          if (rest.length == 2 && request.method == 'GET') {
            return _messages(request, chatId);
          }
          if (rest.length == 2 && request.method == 'POST') {
            return _send(request, chatId);
          }
          if (rest.length == 3 && request.method == 'PATCH') {
            return _editMessage(request, chatId, rest[2]);
          }
          if (rest.length == 4 &&
              rest[3] == 'following' &&
              request.method == 'DELETE') {
            return _deleteFollowing(request, chatId, rest[2]);
          }
        case 'runs':
          if (rest.length == 2 && request.method == 'GET') {
            return _runs(request, chatId);
          }
        case 'usage':
          if (rest.length == 2 && request.method == 'GET') {
            return _chatUsage(request, chatId);
          }
        case 'budget':
          if (rest.length == 2 && request.method == 'PUT') {
            return _saveBudget(request, chatId);
          }
        case 'project':
          if (rest.length == 2 && request.method == 'GET') {
            return _project(request, chatId);
          }
        case 'events':
          if (rest.length == 2 && request.method == 'GET') {
            return _events(request, chatId: chatId);
          }
        case 'presence':
          if (rest.length == 2 && request.method == 'PUT') {
            await _backend.openChat(chatId);
            return _json(request.response, HttpStatus.noContent, {});
          }
        case 'turn':
          if (rest.length == 2 && request.method == 'PUT') {
            return _continueTurn(request, chatId);
          }
          if (rest.length == 2 && request.method == 'DELETE') {
            await _backend.stop(
              chatId,
              reason: request.uri.queryParameters['reason'],
            );
            return _json(request.response, HttpStatus.noContent, {});
          }
        case 'forks':
          if (rest.length == 2 && request.method == 'POST') {
            return _forkChat(request, chatId);
          }
        case 'regenerations':
          if (rest.length == 2 && request.method == 'POST') {
            return _regenerate(request, chatId);
          }
        case 'compactions':
          if (rest.length == 2 && request.method == 'POST') {
            return _compact(request, chatId);
          }
        case 'queue':
          if (rest.length == 3 && request.method == 'PATCH') {
            return _promoteQueued(request, chatId, rest[2]);
          }
          if (rest.length == 3 && request.method == 'DELETE') {
            _session(chatId).takeQueued(int.tryParse(rest[2]) ?? -1);
            return _json(request.response, HttpStatus.noContent, {});
          }
        case 'session':
          if (rest.length == 2 && request.method == 'GET') {
            return _sessionInfo(request, chatId);
          }
      }
    }
    throw const AgentApiException(
      HttpStatus.notFound,
      'not_found',
      'unknown chat endpoint',
    );
  }

  ProjectsApi _requireProjectsApi() {
    final projects = _projectsApi;
    if (projects == null) {
      throw const AgentApiException(
        HttpStatus.notImplemented,
        'not_supported',
        'projects API is not available',
      );
    }
    return projects;
  }

  Future<void> _routeProjects(HttpRequest request, List<String> rest) async {
    final api = _requireProjectsApi();
    if (rest.isEmpty && request.method == 'GET') {
      final projects = await api.watchProjects().first;
      return _json(request.response, HttpStatus.ok, {
        'projects': [for (final project in projects) _projectJson(project)],
      });
    }
    if (rest.length == 1 && rest.first == 'counts' && request.method == 'GET') {
      final counts = await api.watchChatCounts().first;
      return _json(request.response, HttpStatus.ok, {'counts': counts});
    }
    if (rest.length == 1) {
      final id = rest.first;
      if (request.method == 'PUT' || request.method == 'PATCH') {
        final body = await _body(request);
        await api.saveProject(_projectFromJson(id, body));
        return _json(request.response, HttpStatus.noContent, {});
      }
      if (request.method == 'DELETE') {
        await api.deleteProject(id);
        return _json(request.response, HttpStatus.noContent, {});
      }
    }
    if (rest.length == 2) {
      final id = rest.first;
      if (rest[1] == 'chats' && request.method == 'GET') {
        final chats = await api.watchProjectChats(id).first;
        return _json(request.response, HttpStatus.ok, {
          'chats': [
            for (final chat in chats)
              _chatJson(
                chat,
                running: _backend.runningChatIds.contains(chat.id),
                waiting: _backend.waitingChatIds.contains(chat.id),
              ),
          ],
        });
      }
      if (rest[1] == 'facts' && request.method == 'GET') {
        final facts = await api.watchFacts(id).first;
        return _json(request.response, HttpStatus.ok, {
          'facts': [for (final fact in facts) _factJson(fact)],
        });
      }
      if (rest[1] == 'skills' && request.method == 'GET') {
        final skills = await api.watchSkills(id).first;
        return _json(request.response, HttpStatus.ok, {
          'skills': [for (final skill in skills) _skillJson(skill)],
        });
      }
      if (rest[1] == 'facts' && request.method == 'POST') {
        final body = await _body(request);
        await api.addFact(_factFromJson(id, body));
        return _json(request.response, HttpStatus.created, {});
      }
      if (rest[1] == 'trust' && request.method == 'POST') {
        await api.trustWorkspace(id);
        return _json(request.response, HttpStatus.noContent, {});
      }
    }
    if (rest.length == 3 && rest[1] == 'skills' && request.method == 'PUT') {
      final body = await _body(request);
      await api.setSkillTrusted(
        rest.first,
        rest[2],
        trusted: body['trusted'] != false,
      );
      return _json(request.response, HttpStatus.noContent, {});
    }
    if (rest.length == 3 && rest[1] == 'facts' && request.method == 'DELETE') {
      await api.deleteFact(rest.first, rest[2]);
      return _json(request.response, HttpStatus.noContent, {});
    }
    throw const AgentApiException(
      HttpStatus.notFound,
      'not_found',
      'unknown project endpoint',
    );
  }

  Future<void> _policyProfiles(HttpRequest request) async {
    final profiles = await _requireProjectsApi().watchPolicyProfiles().first;
    _json(request.response, HttpStatus.ok, {
      'profiles': [for (final profile in profiles) _policyJson(profile)],
    });
  }

  Future<void> _savePolicyProfile(HttpRequest request, String id) async {
    final body = await _body(request);
    await _requireProjectsApi().savePolicyProfile(_policyFromJson(id, body));
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _mcp(HttpRequest request) async {
    final snapshot = await _requireMcpApi().mcpSnapshot();
    _json(request.response, HttpStatus.ok, {
      'servers': [
        for (final server in snapshot.servers) mcpServerToJson(server),
      ],
      'states': {
        for (final entry in snapshot.states.entries)
          entry.key: mcpStateToJson(entry.value),
      },
      'configError': snapshot.configError,
    });
  }

  Future<void> _saveMcpServer(HttpRequest request, String id) async {
    final body = await _body(request);
    await _requireMcpApi().save(mcpServerFromJson(id, body));
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _deleteMcpServer(HttpRequest request, String id) async {
    final api = _requireMcpApi();
    await api.delete(await _mcpServer(api, id));
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _restartMcpServer(HttpRequest request, String id) async {
    final api = _requireMcpApi();
    await api.restart(await _mcpServer(api, id));
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _refreshMcpTools(HttpRequest request, String id) async {
    final api = _requireMcpApi();
    await api.refreshTools(await _mcpServer(api, id));
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _mcpReady(HttpRequest request) async {
    await _requireMcpApi().ensureReady();
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _mcpImport(HttpRequest request) async {
    final body = await _body(request);
    final text = body['text'];
    final api = _requireMcpApi();
    final result = text is String
        ? await api.importConfigText(
            text,
            sourcePath: body['sourcePath'] as String?,
          )
        : await api.importConfig();
    _json(request.response, HttpStatus.ok, mcpImportToJson(result));
  }

  Future<void> _mcpExport(HttpRequest request) async {
    final text = await _requireMcpApi().exportConfig();
    _json(request.response, HttpStatus.ok, {'text': text});
  }

  Future<McpServerConfig> _mcpServer(McpApi api, String id) async {
    final snapshot = await api.mcpSnapshot();
    for (final server in snapshot.servers) {
      if (server.id == id) return server;
    }
    throw AgentApiException(
      HttpStatus.notFound,
      'mcp_server_not_found',
      'MCP server $id not found',
    );
  }

  McpApi _requireMcpApi() {
    final api = mcpApi;
    if (api == null) {
      throw const AgentApiException(
        HttpStatus.notImplemented,
        'not_supported',
        'MCP API is not available',
      );
    }
    return api;
  }

  Future<void> _plugins(HttpRequest request) async {
    final snapshot = await _requirePluginApi().pluginSnapshot();
    _json(request.response, HttpStatus.ok, pluginSnapshotToJson(snapshot));
  }

  Future<void> _pluginMissing(HttpRequest request, String id) async {
    final ids = await _requirePluginApi().missingDependencies(id);
    _json(request.response, HttpStatus.ok, {'ids': ids.toList()..sort()});
  }

  Future<void> _pluginDependents(HttpRequest request, String id) async {
    final ids = await _requirePluginApi().dependents(id);
    _json(request.response, HttpStatus.ok, {'ids': ids.toList()..sort()});
  }

  Future<void> _setPluginsEnabled(HttpRequest request) async {
    final body = await _body(request);
    final rawIds = body['ids'];
    final enabled = body['enabled'];
    if (rawIds is! List || enabled is! bool) {
      throw const AgentApiException(
        HttpStatus.badRequest,
        'bad_plugins',
        'ids must be a list and enabled must be a boolean',
      );
    }
    await _requirePluginApi().setEnabled({
      for (final id in rawIds)
        if (id is String) id,
    }, enabled: enabled);
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _pluginSettings(HttpRequest request, String id) async {
    final value = await _requirePluginApi().settingsFor(id).read();
    _json(request.response, HttpStatus.ok, value);
  }

  Future<void> _savePluginSettings(HttpRequest request, String id) async {
    final body = await _body(request);
    final raw = body['value'];
    if (raw is! Map) {
      throw const AgentApiException(
        HttpStatus.badRequest,
        'bad_settings',
        'value must be an object',
      );
    }
    await _requirePluginApi()
        .settingsFor(id)
        .save(Map<String, Object?>.from(raw));
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _refreshPlugins(HttpRequest request) async {
    await _requirePluginApi().refresh();
    _json(request.response, HttpStatus.noContent, {});
  }

  PluginApi _requirePluginApi() {
    final api = pluginApi;
    if (api == null) {
      throw const AgentApiException(
        HttpStatus.notImplemented,
        'not_supported',
        'plugin API is not available',
      );
    }
    return api;
  }

  Future<void> _securityAudit(HttpRequest request) async {
    final report = await _requireSecurityAuditApi().run(
      mode: SecurityRunMode.headless,
    );
    _json(request.response, HttpStatus.ok, securityReportToJson(report));
  }

  SecurityAuditApi _requireSecurityAuditApi() {
    final api = securityAuditApi;
    if (api == null) {
      throw const AgentApiException(
        HttpStatus.notImplemented,
        'not_supported',
        'security audit API is not available',
      );
    }
    return api;
  }

  Future<void> _pushSettings(HttpRequest request) async {
    final settings = await _requirePushApi().pushSettings();
    _json(request.response, HttpStatus.ok, {
      'enabled': settings.enabled,
      'relayUrl': settings.relayUrl,
      'hasToken': settings.hasToken,
    });
  }

  Future<void> _savePushSettings(HttpRequest request) async {
    final body = await _body(request);
    await _requirePushApi().savePush(
      PushSettings(
        enabled: body['enabled'] == true,
        relayUrl: body['relayUrl'] is String ? body['relayUrl'] as String : '',
      ),
      token: body['token'] as String?,
      clearToken: body['clearToken'] == true,
    );
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _testPush(HttpRequest request) async {
    await _requirePushApi().testPush();
    _json(request.response, HttpStatus.noContent, {});
  }

  PushApi _requirePushApi() {
    final api = pushApi;
    if (api == null) {
      throw const AgentApiException(
        HttpStatus.notImplemented,
        'not_supported',
        'push API is not available',
      );
    }
    return api;
  }

  Future<void> _hosts(HttpRequest request) async {
    final hosts = await (_hostsApi?.hosts() ?? _backend.hosts());
    _json(request.response, HttpStatus.ok, {
      'hosts': [for (final host in hosts) _hostJson(host)],
    });
  }

  HostsApi _requireHostsApi() {
    final hosts = _hostsApi;
    if (hosts == null) {
      throw const AgentApiException(
        HttpStatus.notImplemented,
        'not_supported',
        'hosts API is not available',
      );
    }
    return hosts;
  }

  Future<void> _saveHost(HttpRequest request, String id) async {
    final body = await _body(request);
    final api = _requireHostsApi();
    final host = _hostFromJson(id, body);
    final existing = (await api.hosts())
        .where((item) => item.id == id)
        .firstOrNull;
    final environment = _stringMap(body['environment']);
    await api.saveHost(
      // Без environment сохраняем прежние переменные: редактирование хоста
      // не должно их стирать.
      existing == null || environment != null
          ? host
          : host.copyWith(environment: existing.environment),
      secret: body['secret'] as String?,
      privateKeyPem: body['privateKeyPem'] as String?,
      environment: environment,
    );
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _testHost(HttpRequest request, String id) async {
    final body = await _body(request);
    await _requireHostsApi().testHost(_hostFromJson(id, body));
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _chats(HttpRequest request) async {
    final chats = await _backend.chats();
    _json(request.response, HttpStatus.ok, {
      'chats': [
        for (final chat in chats)
          _chatJson(
            chat,
            running: _backend.runningChatIds.contains(chat.id),
            waiting: _backend.waitingChatIds.contains(chat.id),
          ),
      ],
    });
  }

  Future<void> _createChat(HttpRequest request) async {
    final body = await _body(request);
    final chat = await _backend.createChat(_string(body, 'hostId'));
    _json(
      request.response,
      HttpStatus.created,
      _chatJson(
        chat,
        running: _backend.runningChatIds.contains(chat.id),
        waiting: _backend.waitingChatIds.contains(chat.id),
      ),
    );
  }

  Future<void> _saveChat(HttpRequest request, String id) async {
    final body = await _body(request);
    await _backend.saveChat(_chatFromJson(id, body));
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _renameChat(HttpRequest request, String id) async {
    final body = await _body(request);
    final policy = body['policyMode'] is String
        ? PolicyMode.values.asNameMap()[body['policyMode'] as String]
        : null;
    if (body['policyMode'] != null && policy == null) {
      throw const AgentApiException(
        HttpStatus.badRequest,
        'bad_policy',
        'unknown policy mode',
      );
    }
    await _backend.updateChat(
      id,
      title: body['title'] is String ? body['title'] as String : null,
      model: body['model'] is String ? body['model'] as String : null,
      policyMode: policy,
      workspace: body['workspace'] is String
          ? body['workspace'] as String
          : null,
      workspaceSpecified: body['workspaceSpecified'] == true,
    );
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _forkChat(HttpRequest request, String chatId) async {
    final body = await _body(request);
    final title = body['title'] is String ? body['title'] as String : null;
    final chat = await _backend.forkChat(chatId, title: title);
    if (chat == null) {
      throw AgentApiException(
        HttpStatus.notFound,
        'chat_not_found',
        'chat $chatId not found',
      );
    }
    _json(
      request.response,
      HttpStatus.created,
      _chatJson(
        chat,
        running: _backend.runningChatIds.contains(chat.id),
        waiting: _backend.waitingChatIds.contains(chat.id),
      ),
    );
  }

  Future<void> _chat(HttpRequest request, String id) async {
    final chat = await _backend.chat(id);
    if (chat == null) {
      throw AgentApiException(
        HttpStatus.notFound,
        'chat_not_found',
        'chat $id not found',
      );
    }
    final messages = await _backend.messages(id);
    final runs = await _backend.runs(id);
    final approvals = await _backend.pendingApprovals(id);
    final questions = await _backend.pendingQuestions(id);
    final edits = await _backend.pendingEditFileChanges(id);
    _json(request.response, HttpStatus.ok, {
      'chat': _chatJson(
        chat,
        running: _backend.runningChatIds.contains(chat.id),
        waiting: _backend.waitingChatIds.contains(chat.id),
      ),
      'messages': [for (final message in messages) _messageJson(message)],
      'runs': [for (final run in runs) _runJson(run)],
      'approvals': [for (final approval in approvals) _approvalJson(approval)],
      'questions': [for (final question in questions) _questionJson(question)],
      'editFileChanges': [for (final edit in edits) _editJson(edit)],
    });
  }

  ChatApi _requireChatApi() {
    final chat = _chatApi;
    if (chat == null) {
      throw const AgentApiException(
        HttpStatus.notImplemented,
        'not_supported',
        'chat API is not available',
      );
    }
    return chat;
  }

  AgentSettingsApi _requireSettingsApi() {
    final settings = settingsApi;
    if (settings == null) {
      throw const AgentApiException(
        HttpStatus.notImplemented,
        'not_supported',
        'settings API is not available',
      );
    }
    return settings;
  }

  Future<void> _settings(HttpRequest request) async {
    final snapshot = await _requireSettingsApi().load();
    _json(request.response, HttpStatus.ok, {
      'defaultModel': snapshot.defaultModel,
      'titleModel': snapshot.titleModel,
      'subagentModel': snapshot.subagentModel,
      'fallbackModel': snapshot.fallbackModel,
      'defaultPolicy': snapshot.defaultPolicy,
      'denylist': snapshot.denylist,
      'securityProfile': snapshot.securityProfile.encode(),
      'limits': snapshot.limits.toMap(),
      'pinnedModels': snapshot.pinnedModels,
      'steps': _stepsJson(snapshot.stepsDisplay),
      'apiKeyTail': snapshot.apiKeyTail,
      'catalog': _catalogJson(snapshot.catalog),
    });
  }

  Future<void> _saveSetting(HttpRequest request, String key) async {
    final body = await _body(request);
    final value = body['value'];
    if (value != null && value is! String) {
      throw const AgentApiException(
        HttpStatus.badRequest,
        'bad_value',
        'value must be a string or null',
      );
    }
    await _requireSettingsApi().writeSetting(key, value as String?);
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _saveApiKey(HttpRequest request) async {
    final body = await _body(request);
    try {
      await _requireSettingsApi().saveApiKey(_string(body, 'key'));
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(
        AgentApiException(HttpStatus.badRequest, 'api_key_rejected', '$error'),
        stackTrace,
      );
    }
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _checkKey(HttpRequest request) async {
    final info = await _requireSettingsApi().checkKey();
    if (info == null) {
      return _json(request.response, HttpStatus.noContent, {});
    }
    _json(request.response, HttpStatus.ok, _keyInfoJson(info));
  }

  Future<void> _refreshModels(HttpRequest request) async {
    await _requireSettingsApi().refreshModels();
    _json(request.response, HttpStatus.accepted, {});
  }

  Future<void> _saveSteps(HttpRequest request) async {
    final body = await _body(request);
    await _requireSettingsApi().saveStepsDisplay(
      StepsDisplay(
        group: body['group'] != false,
        expandWhileActive: body['expandWhileActive'] != false,
        thoughts: ThoughtsVisibility.values.byName(
          '${body['thoughts'] ?? 'all'}',
        ),
        tools: ToolsVisibility.values.byName('${body['tools'] ?? 'all'}'),
      ),
    );
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _saveLimits(HttpRequest request) async {
    final body = await _body(request);
    final raw = body['limits'];
    if (raw is! Map) {
      throw const AgentApiException(
        HttpStatus.badRequest,
        'bad_limits',
        'limits must be an object',
      );
    }
    await _requireSettingsApi().saveLimits(
      AppLimits.fromJson(jsonEncode(Map<String, dynamic>.from(raw))),
    );
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _saveDenylist(HttpRequest request) async {
    final body = await _body(request);
    final raw = body['denylist'];
    if (raw is! List) {
      throw const AgentApiException(
        HttpStatus.badRequest,
        'bad_denylist',
        'denylist must be a list',
      );
    }
    await _requireSettingsApi().saveDenylist([
      for (final item in raw)
        if (item is String) item,
    ]);
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _saveSecurityProfile(HttpRequest request) async {
    final body = await _body(request);
    await _requireSettingsApi().saveSecurityProfile(
      SecurityProfile.decode('${body['profile'] ?? '{}'}'),
    );
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _savePinned(HttpRequest request) async {
    final body = await _body(request);
    final pinned = body['pinnedModels'];
    if (pinned is! List) {
      throw const AgentApiException(
        HttpStatus.badRequest,
        'bad_pinned',
        'pinnedModels must be a list',
      );
    }
    await _requireSettingsApi().savePinnedModels([
      for (final id in pinned)
        if (id is String) id,
    ]);
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _chatUsage(HttpRequest request, String chatId) async {
    final settings = _requireChatApi().settings;
    final usage = await settings.readDailyUsage(chatId);
    final budget = await settings.readDailyBudget(chatId);
    final compaction = await settings.readCompactionInfo(chatId);
    _json(request.response, HttpStatus.ok, {
      'usage': {
        'promptTokens': usage.promptTokens,
        'completionTokens': usage.completionTokens,
        'costUsd': usage.costUsd,
        'requests': usage.requests,
      },
      'budget': budget,
      'compaction': compaction == null
          ? null
          : {
              'at': compaction.at.toUtc().toIso8601String(),
              'reason': compaction.reason,
              'cutoffSeq': compaction.cutoffSeq,
              'summaryChars': compaction.summaryChars,
            },
    });
  }

  Future<void> _saveBudget(HttpRequest request, String chatId) async {
    final body = await _body(request);
    final value = body['budget'];
    await _requireChatApi().settings.saveDailyBudget(
      chatId,
      value is num ? value.toDouble() : null,
    );
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _project(HttpRequest request, String chatId) async {
    final project = await _requireChatApi().projectStore.forChat(chatId);
    _json(request.response, HttpStatus.ok, {
      'project': project == null ? null : _projectJson(project),
    });
  }

  Future<void> _trustHost(HttpRequest request, String hostId) async {
    final body = await _body(request);
    final workspace = _string(body, 'workspace');
    await _requireChatApi().settings.setTrusted(
      hostId,
      workspace,
      trusted: body['trusted'] != false,
    );
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _models(HttpRequest request) async {
    final state = (await _requireSettingsApi().load()).catalog;
    _json(request.response, HttpStatus.ok, _catalogJson(state));
  }

  Future<void> _rememberModels(HttpRequest request) async {
    final body = await _body(request);
    final ids = body['ids'];
    if (ids is! List) {
      throw const AgentApiException(
        HttpStatus.badRequest,
        'bad_ids',
        'ids must be a list',
      );
    }
    await _requireSettingsApi().rememberModels([
      for (final id in ids)
        if (id is String) id,
    ]);
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _saveDraft(HttpRequest request, String chatId) async {
    final body = await _body(request);
    final revision = await _requireChatApi().chatStore.saveDraft(
      chatId,
      ChatDraft(
        text: body['text'] is String ? body['text'] as String : '',
        attachments: _attachments(body['attachments']),
      ),
      expectedRevision: _revisionOf(body),
    );
    _publishDraft(chatId, revision);
    _json(request.response, HttpStatus.ok, {'revision': revision});
  }

  Future<void> _saveMessageEdits(HttpRequest request, String chatId) async {
    final body = await _body(request);
    final raw = body['edits'];
    if (raw is! Map) {
      throw const AgentApiException(
        HttpStatus.badRequest,
        'bad_edits',
        'edits must be an object',
      );
    }
    final edits = <String, ChatDraft>{
      for (final entry in raw.entries)
        '${entry.key}': ChatDraft(
          text: entry.value is Map && entry.value['text'] is String
              ? entry.value['text'] as String
              : '',
          attachments: entry.value is Map
              ? _attachments(entry.value['attachments'])
              : const [],
        ),
    };
    final revision = await _requireChatApi().chatStore.saveMessageEdits(
      chatId,
      edits,
      expectedRevision: _revisionOf(body),
    );
    _publishDraft(chatId, revision);
    _json(request.response, HttpStatus.ok, {'revision': revision});
  }

  int? _revisionOf(Map<String, dynamic> body) =>
      body['revision'] is num ? (body['revision'] as num).toInt() : null;

  void _publishDraft(String chatId, int revision) {
    if (!_stateEvents.isClosed) {
      _stateEvents.add(_DraftChanged(chatId, revision));
    }
  }

  Future<void> _messages(HttpRequest request, String chatId) async {
    final messages = await _backend.messages(chatId);
    _json(request.response, HttpStatus.ok, {
      'messages': [for (final message in messages) _messageJson(message)],
    });
  }

  Future<void> _runs(HttpRequest request, String chatId) async {
    final runs = await _backend.runs(chatId);
    _json(request.response, HttpStatus.ok, {
      'runs': [for (final run in runs) _runJson(run)],
    });
  }

  ChatSessionApi _session(String chatId) {
    final chat = _chatApi;
    if (chat == null) {
      throw const AgentApiException(
        HttpStatus.notImplemented,
        'not_supported',
        'session API is not available',
      );
    }
    return chat.session(chatId);
  }

  Future<void> _sessionInfo(HttpRequest request, String chatId) {
    final session = _session(chatId);
    _json(request.response, HttpStatus.ok, {
      'isRunning': session.isRunning,
      'queue': [
        for (final item in session.queue)
          {'text': item.text, 'isEvent': item.isEvent},
      ],
    });
    return Future<void>.value();
  }

  Future<void> _continueTurn(HttpRequest request, String chatId) async {
    await _session(chatId).continueAfterStepLimit();
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _editMessage(
    HttpRequest request,
    String chatId,
    String messageId,
  ) async {
    final body = await _body(request);
    try {
      final accepted = await _session(chatId)
          .editUserMessage(messageId, _string(body, 'text'));
      _json(request.response, HttpStatus.ok, {'accepted': accepted});
    } on StateError catch (error, stack) {
      Error.throwWithStackTrace(
        AgentApiException(HttpStatus.conflict, 'session_busy', error.message),
        stack,
      );
    }
  }

  Future<void> _deleteFollowing(
    HttpRequest request,
    String chatId,
    String messageId,
  ) async {
    await _session(chatId).deleteAfter(messageId);
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _regenerate(HttpRequest request, String chatId) async {
    final accepted = await _session(chatId).regenerateLast();
    _json(request.response, HttpStatus.ok, {'accepted': accepted});
  }

  Future<void> _compact(HttpRequest request, String chatId) async {
    final body = await _body(request);
    await _session(chatId).compactNow(force: body['force'] == true);
    _json(request.response, HttpStatus.accepted, {});
  }

  Future<void> _promoteQueued(
    HttpRequest request,
    String chatId,
    String index,
  ) async {
    final body = await _body(request);
    if (body['position'] != null && body['position'] != 0) {
      throw const AgentApiException(
        HttpStatus.badRequest,
        'bad_position',
        'only position 0 is supported',
      );
    }
    _session(chatId).promoteQueued(int.tryParse(index) ?? -1);
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _send(HttpRequest request, String chatId) async {
    final body = await _body(request);
    final text = body['text'] is String ? body['text'] as String : '';
    final attachments = _attachments(body['attachments']);
    await _backend.send(
      chatId,
      text,
      sendNow: body['sendNow'] == true,
      attachments: attachments,
    );
    _json(request.response, HttpStatus.accepted, {'ok': true});
  }

  Future<void> _approval(HttpRequest request, String id) async {
    final body = await _body(request);
    final action = switch (_string(body, 'action')) {
      'allowOnce' => ApprovalAction.allowOnce,
      'allowTurn' => ApprovalAction.allowTurn,
      'allowChat' => ApprovalAction.allowChat,
      'deny' => ApprovalAction.deny,
      final value => throw AgentApiException(
        HttpStatus.badRequest,
        'bad_action',
        'unknown approval action: $value',
      ),
    };
    await _backend.resolveApproval(
      id,
      action,
      reason: body['reason'] is String ? body['reason'] as String : null,
    );
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _answer(HttpRequest request, String id) async {
    final body = await _body(request);
    final value = body['answer'];
    await _backend.answerQuestion(id, value is String ? value : null);
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _editFileChanges(HttpRequest request, String id) async {
    final body = await _body(request);
    final choice = switch (_string(body, 'choice')) {
      'rollbackAndContinue' => EditFileChangesChoice.rollbackAndContinue,
      'continueWithoutRollback' =>
        EditFileChangesChoice.continueWithoutRollback,
      'cancel' => EditFileChangesChoice.cancel,
      final value => throw AgentApiException(
        HttpStatus.badRequest,
        'bad_choice',
        'unknown choice: $value',
      ),
    };
    await _backend.resolveEditFileChanges(id, choice);
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _scheduleItem(HttpRequest request, String id) async {
    final task = await _backend.scheduledTask(id);
    if (task == null) {
      throw AgentApiException(
        HttpStatus.notFound,
        'schedule_not_found',
        'schedule $id not found',
      );
    }
    _json(request.response, HttpStatus.ok, _taskJson(task));
  }

  Future<void> _schedules(HttpRequest request) async {
    final tasks = await _backend.schedules();
    _json(request.response, HttpStatus.ok, {
      'schedules': [for (final task in tasks) _taskJson(task)],
    });
  }

  Future<void> _schedule(HttpRequest request) async {
    final body = await _body(request);
    final dueAtRaw = _string(body, 'dueAt');
    final dueAt = DateTime.tryParse(dueAtRaw)?.toUtc();
    if (dueAt == null) {
      throw const AgentApiException(
        HttpStatus.badRequest,
        'bad_due_at',
        'dueAt must be an ISO-8601 date',
      );
    }
    final task = await _backend.schedule(
      chatId: _string(body, 'chatId'),
      prompt: _string(body, 'prompt'),
      dueAt: dueAt,
    );
    _json(request.response, HttpStatus.created, _taskJson(task));
  }

  /// SSE-поток всех событий или одного чата (`?chatId=`).
  Future<void> _events(HttpRequest request, {String? chatId}) async {
    final response = request.response;
    final filterChatId = chatId ?? request.uri.queryParameters['chatId'];
    if (filterChatId != null && await _backend.chat(filterChatId) == null) {
      throw AgentApiException(
        HttpStatus.notFound,
        'chat_not_found',
        'chat $filterChatId not found',
      );
    }
    response
      ..bufferOutput = false
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      )
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-cache')
      ..headers.set(HttpHeaders.connectionHeader, 'keep-alive');
    _clients.add(response);
    final subscription = _allEvents().listen((event) {
      if (!_matchesChat(event, filterChatId)) return;
      final encoded = _event(event);
      response.write(
        'event: ${encoded.$1}\ndata: ${jsonEncode(encoded.$2)}\n\n',
      );
    });
    response.write(': connected\n\n');
    await response.flush();
    final heartbeat = Timer.periodic(_eventHeartbeat, (_) {
      response.write(': ping\n\n');
    });
    try {
      await response.done;
    } on Object {
      // Клиент закрыл соединение.
    } finally {
      heartbeat.cancel();
      await subscription.cancel();
      _clients.remove(response);
    }
  }

  /// Склеивает журнал и карточки в один поток для SSE.
  Stream<Object> _allEvents() {
    final controller = StreamController<Object>();
    final subscriptions = <StreamSubscription<dynamic>>[
      _backend.events.listen(controller.add),
      _backend.approvals.listen(controller.add),
      _backend.questions.listen(controller.add),
      _backend.editChanges.listen(controller.add),
      _stateEvents.stream.listen(controller.add),
    ];
    controller.onCancel = () async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    };
    return controller.stream;
  }

  Future<Map<String, dynamic>> _body(HttpRequest request) async {
    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
      if (bytes.length > _maxBodyBytes) {
        throw const AgentApiException(
          HttpStatus.requestEntityTooLarge,
          'body_too_large',
          'request body is too large',
        );
      }
    }
    if (bytes.isEmpty) return const {};
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw const AgentApiException(
        HttpStatus.badRequest,
        'bad_json',
        'expected a JSON object',
      );
    }
    return Map<String, dynamic>.from(decoded);
  }

  bool _authorized(HttpRequest request) {
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    if (header == null || !header.startsWith('Bearer ')) return false;
    final value = header.replaceFirst('Bearer ', '');
    if (value.length != _token.length) return false;
    var different = 0;
    for (var i = 0; i < value.length; i++) {
      different |= value.codeUnitAt(i) ^ _token.codeUnitAt(i);
    }
    return different == 0;
  }

  static String _string(Map<String, dynamic> body, String key) {
    final value = body[key];
    if (value is String && value.isNotEmpty) return value;
    throw AgentApiException(
      HttpStatus.badRequest,
      'missing_field',
      'expected non-empty string field "$key"',
    );
  }

  static void _json(HttpResponse response, int status, Object body) {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    if (status != HttpStatus.noContent) response.write(jsonEncode(body));
  }

  static void _error(
    HttpResponse response,
    int status,
    String code,
    String message, {
    String? requestId,
  }) {
    _json(response, status, {
      'error': {'code': code, 'message': message},
      'requestId': ?requestId,
    });
  }
}

Project _projectFromJson(String id, Map<String, dynamic> json) {
  final now = DateTime.now();
  return Project(
    id: id,
    hostId: '${json['hostId'] ?? ''}',
    name: '${json['name'] ?? ''}',
    workspace: '${json['workspace'] ?? ''}',
    workspaceKey: '${json['workspaceKey'] ?? ''}',
    policyProfileId: json['policyProfileId'] as String?,
    trustAgentsMd: json['trustAgentsMd'] == true,
    skillsInitialized: json['skillsInitialized'] == true,
    archivedAt: _date(json['archivedAt']),
    createdAt: _date(json['createdAt']) ?? now,
    updatedAt: _date(json['updatedAt']) ?? now,
  );
}

ProjectFact _factFromJson(String projectId, Map<String, dynamic> json) =>
    ProjectFact(
      id: '${json['id'] ?? ''}',
      projectId: projectId,
      text: '${json['text'] ?? ''}',
      createdAt: _date(json['createdAt']) ?? DateTime.now(),
    );

Map<String, Object?> _factJson(ProjectFact fact) => {
  'id': fact.id,
  'projectId': fact.projectId,
  'text': fact.text,
  'createdAt': fact.createdAt.toUtc().toIso8601String(),
};

Map<String, Object?> _skillJson(ProjectSkill skill) => {
  'name': skill.name,
  'trusted': skill.trusted,
};

PolicyProfile _policyFromJson(String id, Map<String, dynamic> json) =>
    PolicyProfile(
      id: id,
      name: '${json['name'] ?? ''}',
      description: json['description'] as String?,
      profile: SecurityProfile.decode('${json['profile'] ?? '{}'}'),
      createdAt: _date(json['createdAt']) ?? DateTime.now(),
      updatedAt: _date(json['updatedAt']) ?? DateTime.now(),
    );

Map<String, Object?> _policyJson(PolicyProfile profile) => {
  'id': profile.id,
  'name': profile.name,
  'description': profile.description,
  'profile': profile.profile.encode(),
  'createdAt': profile.createdAt.toUtc().toIso8601String(),
  'updatedAt': profile.updatedAt.toUtc().toIso8601String(),
};

Map<String, Object?> _keyInfoJson(LlmKeyInfo info) => {
  'label': info.label,
  'usage': info.usage,
  'limit': info.limit,
  'limitRemaining': info.limitRemaining,
  'limitReset': info.limitReset,
  'isFreeTier': info.isFreeTier,
  'expiresAt': info.expiresAt?.toUtc().toIso8601String(),
};

Map<String, String>? _stringMap(Object? value) {
  if (value is! Map) return null;
  return {
    for (final entry in value.entries)
      if (entry.value is String) '${entry.key}': entry.value as String,
  };
}

Host _hostFromJson(String id, Map<String, dynamic> json) {
  final now = DateTime.now();
  return Host(
    id: id,
    name: '${json['name'] ?? ''}',
    kind: HostKind.values.byName('${json['kind'] ?? 'local'}'),
    address: json['address'] as String?,
    port: json['port'] is num ? (json['port'] as num).toInt() : 22,
    username: json['username'] as String?,
    authType: SshAuthType.values.byName('${json['authType'] ?? 'key'}'),
    keyPath: json['keyPath'] as String?,
    os: HostOs.values.byName('${json['os'] ?? 'posix'}'),
    defaultWorkspace: json['defaultWorkspace'] as String?,
    shellOverride: json['shellOverride'] as String?,
    notes: json['notes'] as String?,
    connectTimeoutSeconds: json['connectTimeoutSeconds'] is num
        ? (json['connectTimeoutSeconds'] as num).toInt()
        : null,
    hostKeyFingerprint: json['hostKeyFingerprint'] as String?,
    lastCheckAt: _date(json['lastCheckAt']),
    lastLatencyMs: json['lastLatencyMs'] is num
        ? (json['lastLatencyMs'] as num).toInt()
        : null,
    lastCheckError: json['lastCheckError'] as String?,
    createdAt: _date(json['createdAt']) ?? now,
    updatedAt: _date(json['updatedAt']) ?? now,
  );
}

Map<String, Object?> _hostJson(Host host) => {
  'id': host.id,
  'name': host.name,
  'kind': host.kind.name,
  'address': host.address,
  'port': host.port,
  'username': host.username,
  'authType': host.authType.name,
  'keyPath': host.keyPath,
  'hostKeyFingerprint': host.hostKeyFingerprint,
  'os': host.os.name,
  'defaultWorkspace': host.defaultWorkspace,
  'shellOverride': host.shellOverride,
  'notes': host.notes,
  'connectTimeoutSeconds': host.connectTimeoutSeconds,
  'lastCheckAt': host.lastCheckAt?.toUtc().toIso8601String(),
  'lastLatencyMs': host.lastLatencyMs,
  'lastCheckError': host.lastCheckError,
  'createdAt': host.createdAt.toUtc().toIso8601String(),
  'updatedAt': host.updatedAt.toUtc().toIso8601String(),
};

Map<String, Object?> _stepsJson(StepsDisplay steps) => {
  'group': steps.group,
  'expandWhileActive': steps.expandWhileActive,
  'thoughts': steps.thoughts.name,
  'tools': steps.tools.name,
};

Map<String, Object?> _projectJson(Project project) => {
  'id': project.id,
  'hostId': project.hostId,
  'name': project.name,
  'workspace': project.workspace,
  'workspaceKey': project.workspaceKey,
  'policyProfileId': project.policyProfileId,
  'trustAgentsMd': project.trustAgentsMd,
  'skillsInitialized': project.skillsInitialized,
  'archivedAt': project.archivedAt?.toUtc().toIso8601String(),
  'createdAt': project.createdAt.toUtc().toIso8601String(),
  'updatedAt': project.updatedAt.toUtc().toIso8601String(),
};

Map<String, Object?> _catalogJson(ModelCatalogState state) => {
  'models': [for (final model in state.models) _modelJson(model)],
  'saved': {
    for (final entry in state.saved.entries)
      entry.key: {
        'id': entry.value.id,
        'name': entry.value.name,
        'contextLength': entry.value.contextLength,
        'supportsTools': entry.value.supportsTools,
        'inputModalities': entry.value.inputModalities,
      },
  },
  'syncedAt': state.syncedAt?.toUtc().toIso8601String(),
  'loading': state.loading,
  'error': state.error,
};

Map<String, Object?> _modelJson(LlmModelInfo model) => {
  'id': model.id,
  'name': model.name,
  'contextLength': model.contextLength,
  'supportsTools': model.supportsTools,
  'promptPrice': model.promptPrice,
  'completionPrice': model.completionPrice,
  'created': model.created,
  'inputModalities': model.inputModalities,
};

List<AttachmentRef> _attachments(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final item in raw)
      if (item is Map)
        AttachmentRef(
          name: '${item['name'] ?? ''}',
          mode: AttachmentMode.values.byName('${item['mode'] ?? 'file'}'),
          content: item['content'] as String?,
          mimeType: item['mimeType'] as String?,
          sizeBytes: item['sizeBytes'] is num
              ? (item['sizeBytes'] as num).toInt()
              : 0,
          bytes: item['bytes'] is String
              ? Uint8List.fromList(base64Decode(item['bytes'] as String))
              : null,
        ),
  ];
}

Chat _chatFromJson(String id, Map<String, dynamic> json) {
  final now = DateTime.now();
  return Chat(
    id: id,
    hostId: '${json['hostId'] ?? ''}',
    projectId: json['projectId'] as String?,
    kind: ChatKind.values.byName('${json['kind'] ?? 'main'}'),
    parentChatId: json['parentChatId'] as String?,
    rootChatId: json['rootChatId'] as String?,
    depth: json['depth'] is num ? (json['depth'] as num).toInt() : 0,
    title: '${json['title'] ?? ''}',
    titleSource: ChatTitleSource.values.byName(
      '${json['titleSource'] ?? 'none'}',
    ),
    model: json['model'] as String?,
    policyMode: PolicyMode.values.byName('${json['policyMode'] ?? 'ask'}'),
    workspace: json['workspace'] as String?,
    lastPromptTokens: json['lastPromptTokens'] as int?,
    lastCompletionTokens: json['lastCompletionTokens'] as int?,
    contextLength: json['contextLength'] as int?,
    createdAt: _date(json['createdAt']) ?? now,
    updatedAt: _date(json['updatedAt']) ?? now,
  );
}

DateTime? _date(Object? value) => value is String && value.isNotEmpty
    ? DateTime.tryParse(value)?.toUtc()
    : null;

Map<String, Object?> _chatJson(
  Chat chat, {
  required bool running,
  required bool waiting,
}) => {
  'running': running,
  'waiting': waiting,
  'id': chat.id,
  'hostId': chat.hostId,
  'projectId': chat.projectId,
  'kind': chat.kind.name,
  'parentChatId': chat.parentChatId,
  'rootChatId': chat.rootChatId,
  'depth': chat.depth,
  'title': chat.title,
  'titleSource': chat.titleSource.name,
  'model': chat.model,
  'policyMode': chat.policyMode.name,
  'workspace': chat.workspace,
  'lastPromptTokens': chat.lastPromptTokens,
  'lastCompletionTokens': chat.lastCompletionTokens,
  'contextLength': chat.contextLength,
  'draft': _draftJson(chat.draft),
  'messageEdits': encodeMessageEdits(chat.messageEdits),
  'draftRevision': chat.draftRevision,
  'createdAt': chat.createdAt.toUtc().toIso8601String(),
  'updatedAt': chat.updatedAt.toUtc().toIso8601String(),
};

Map<String, Object?> _draftJson(ChatDraft draft) => {
  'text': draft.text,
  'attachments': [
    for (final attachment in draft.attachments)
      {
        'name': attachment.name,
        'mode': attachment.mode.name,
        'mimeType': attachment.mimeType,
        'sizeBytes': attachment.sizeBytes,
      },
  ],
};

Map<String, Object?> _messageJson(ChatMessage message) => {
  'id': message.id,
  'chatId': message.chatId,
  'seq': message.seq,
  'role': message.role.name,
  'text': message.text,
  'reasoning': message.reasoning,
  'toolCalls': [
    for (final call in message.toolCalls)
      {'id': call.id, 'name': call.name, 'arguments': call.arguments},
  ],
  'toolCallId': message.toolCallId,
  'attachments': [
    for (final attachment in message.attachments)
      {
        'name': attachment.name,
        'mode': attachment.mode.name,
        'mimeType': attachment.mimeType,
        'sizeBytes': attachment.sizeBytes,
      },
  ],
  'createdAt': message.createdAt.toUtc().toIso8601String(),
};

Map<String, Object?> _runJson(ToolRun run) => {
  'id': run.id,
  'chatId': run.chatId,
  'messageId': run.messageId,
  'toolName': run.toolName,
  'argsJson': run.argsJson,
  'command': run.command,
  'background': run.background,
  'status': run.status.name,
  'pid': run.pid,
  'exitCode': run.exitCode,
  'timedOut': run.timedOut,
  'outputText': run.outputText,
  'outputTruncated': run.outputTruncated,
  'resultPreview': run.resultPreview,
  'startedAt': run.startedAt.toUtc().toIso8601String(),
  'finishedAt': run.finishedAt?.toUtc().toIso8601String(),
  'toolCallId': run.toolCallId,
  'pendingCard': run.pendingCard == null ? null : jsonDecode(run.pendingCard!),
};

Map<String, Object?> _taskJson(ScheduledTask task) => {
  'id': task.id,
  'chatId': task.chatId,
  'prompt': task.prompt,
  'dueAt': task.dueAt.toUtc().toIso8601String(),
  'status': task.status.name,
  'error': task.error,
  'createdAt': task.createdAt.toUtc().toIso8601String(),
  'updatedAt': task.updatedAt.toUtc().toIso8601String(),
};

Map<String, Object?> _approvalJson(ApprovalRequest request) => {
  'id': request.id,
  'chatId': request.chatId,
  'toolName': request.toolName,
  'summary': request.summary,
  'reason': request.reason,
  'diff': request.diff,
  'turnId': request.turnId,
  'permissionKey': request.permissionKey,
  'grantable': request.grantable,
};

Map<String, Object?> _questionJson(UserQuestion question) => {
  'id': question.id,
  'chatId': question.chatId,
  'text': question.text,
};

Map<String, Object?> _editJson(EditFileChangesRequest request) => {
  'id': request.id,
  'chatId': request.chatId,
  'files': [
    for (final file in request.files)
      {'path': file.path, 'kind': file.kind.name},
  ],
  'shellMayHaveChangedFiles': request.shellMayHaveChangedFiles,
};

bool _matchesChat(Object event, String? chatId) {
  final eventChatId = switch (event) {
    AgentEvent value => value.chatId,
    ApprovalRequest value => value.chatId,
    UserQuestion value => value.chatId,
    EditFileChangesRequest value => value.chatId,
    _ => null,
  };
  return chatId == null || eventChatId == chatId;
}

(String, Map<String, Object?>) _event(Object event) => switch (event) {
  AgentTurnStarted value => ('turnStarted', {'chatId': value.chatId}),
  AgentTurnFinished value => (
    'turnFinished',
    {'chatId': value.chatId, 'end': value.end.name},
  ),
  AgentMessageAdded value => (
    'messageAdded',
    {'chatId': value.chatId, 'message': _messageJson(value.message)},
  ),
  AgentTextDelta value => (
    'textDelta',
    {'chatId': value.chatId, 'text': value.text, 'reset': value.reset},
  ),
  AgentReasoningDelta value => (
    'reasoningDelta',
    {'chatId': value.chatId, 'text': value.text, 'reset': value.reset},
  ),
  AgentRunChanged value => (
    'runChanged',
    {'chatId': value.chatId, 'run': _runJson(value.run)},
  ),
  AgentQueueChanged value => (
    'queueChanged',
    {'chatId': value.chatId, 'size': value.size},
  ),
  AgentFailureRaised value => (
    'failure',
    {'chatId': value.chatId, 'message': value.failure.message},
  ),
  AgentTrustNeeded value => (
    'trustNeeded',
    {'chatId': value.chatId, 'workspace': value.workspace},
  ),
  AgentUsageUpdated value => (
    'usage',
    {
      'chatId': value.chatId,
      'promptTokens': value.promptTokens,
      'limit': value.limit,
      'dailyCostUsd': value.dailyCostUsd,
      'dailyBudgetUsd': value.dailyBudgetUsd,
    },
  ),
  AgentStateChanged value => ('stateChanged', {'chatId': value.chatId}),
  ApprovalRequest value => ('approval', _approvalJson(value)),
  UserQuestion value => ('question', _questionJson(value)),
  EditFileChangesRequest value => ('editFileChanges', _editJson(value)),
  _StateChanged value => ('stateAreaChanged', {'area': value.area}),
  _DraftChanged value => (
    'draftChanged',
    {'chatId': value.chatId, 'revision': value.revision},
  ),
  _ => ('unknown', {'type': event.runtimeType.toString()}),
};

final class _StateChanged {
  const _StateChanged(this.area);

  final String area;
}

final class _DraftChanged {
  const _DraftChanged(this.chatId, this.revision);

  final String chatId;
  final int revision;
}

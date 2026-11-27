import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/agent_settings_api.dart';
import 'package:pw_agent/agent/api/attention_api.dart';
import 'package:pw_agent/agent/api/attention_digest_api.dart';
import 'package:pw_agent/agent/api/attention_pause_api.dart';
import 'package:pw_agent/agent/api/attention_snooze_api.dart';
import 'package:pw_agent/agent/api/chat_api.dart';
import 'package:pw_agent/agent/api/data_api.dart';
import 'package:pw_agent/agent/api/hosts_api.dart';
import 'package:pw_agent/agent/api/mcp_api.dart';
import 'package:pw_agent/agent/api/plugin_api.dart';
import 'package:pw_agent/agent/api/projects_api.dart';
import 'package:pw_agent/agent/api/push_api.dart';
import 'package:pw_agent/agent/api/security_audit_api.dart';
import 'package:pw_agent/agent/domain/attention_digest.dart';
import 'package:pw_agent/agent/domain/chat_attention.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/notification_pause.dart';
import 'package:pw_agent/agent/domain/project.dart';
import 'package:pw_agent/agent/domain/search.dart';
import 'package:pw_agent/agent/domain/steps_display.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/agent/loop/prompt_queue.dart';
import 'package:pw_agent/agent/policy/security_profile.dart';
import 'package:pw_agent/agent/state/domain_change_bus.dart';
import 'package:pw_agent/agent/state/shared_state.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/domain/mcp_server.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/core/logging/app_log.dart';
import 'package:pw_agent/core/security/security_audit.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/local_models.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';
import 'package:pw_agent/providers/ai/model_runtime.dart';
import 'package:pw_server/src/api/api_access_log.dart';
import 'package:pw_server/src/api/api_rate_limiter.dart';
import 'package:pw_server/src/api/api_token.dart';
import 'package:pw_server/src/api/client_session.dart';
import 'package:pw_server/src/web/static_web.dart';

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
    this.dataApi,
    HostsApi? hosts,
    ProjectsApi? projects,
    this.settingsApi,
    this.mcpApi,
    this.pluginApi,
    this.securityAuditApi,
    this.pushApi,
    this.accessLog,
    this.web,
    this.allowedOrigins = const {},
    this.requireSession = true,
    this.maxConcurrentRequests = 32,
    this.requestTimeout = const Duration(minutes: 5),
    ApiRateLimiter? rateLimiter,
    ClientSessionRegistry? clientSessions,
    this.domainChanges,
    String? instanceId,
  }) : _address = address ?? InternetAddress.loopbackIPv4,
       _chatApi = chat,
       _hostsApi = hosts,
       _projectsApi = projects,
       _rateLimiter = rateLimiter ?? ApiRateLimiter(),
       _clientSessions = clientSessions ?? ClientSessionRegistry(),
       instanceId = instanceId ?? ApiTokenStore.generateApiToken(),
       assert(maxConcurrentRequests > 0),
       assert(requestTimeout > Duration.zero) {
    // Одна подписка на весь сервер: иначе каждая SSE-подписка добавляла бы
    // своё событие в общий _stateEvents и N клиентов получали бы N^2 копий.
    _sessionChangesSub = _clientSessions.changes.listen((_) {
      if (!_stateEvents.isClosed) {
        // Снимок уходит вместе с событием: иначе каждое окно после смены
        // присутствия делало бы отдельный GET /client/sessions, и нагрузка
        // росла бы вместе с числом экранов.
        final at = _clientSessions.now;
        final attentionKey = _clientSessions.attentionDeviceKeyAt(at);
        _stateEvents.add(
          _ClientSessionsChanged([
            for (final session in _clientSessions.list())
              _clientSessionJson(
                session,
                current: false,
                now: at,
                attentionDeviceKey: attentionKey,
              ),
          ], _clientSessions.revision),
        );
      }
    });

    // Доменные сервисы публикуют изменения сами. Путь-`switch` больше не
    // решает, что синхронизировать: новый маршрут поверх сервиса получает
    // событие автоматически.
    _domainChangesSub = domainChanges?.changes.listen(
      (resource) => _emitState(resource.area),
    );
    // Настройки пишутся не только HTTP-маршрутами: агент меняет модели и
    // лимиты во время работы. Изменения kv-таблицы уже отфильтрованы от
    // счётчиков расхода, поэтому подписка не создаёт лишнего трафика.
    final settings = settingsApi;
    if (settings is SettingsChangeSource) {
      _settingsChangesSub = settings.settingsChanges.listen(
        (_) => _emitState(SharedResource.settings.area),
      );
    }
  }

  static const _maxBodyBytes = 8 << 20;
  static const _eventHeartbeat = Duration(seconds: 15);

  /// Версия протокола клиентских сессий. Одна на рукопожатие и проверку
  /// демона, чтобы клиент и сервер не разошлись в допущении.
  static const clientProtocol = 1;

  final AgentApi _backend;
  final ChatApi? _chatApi;
  final DataApi? dataApi;
  final HostsApi? _hostsApi;
  final ProjectsApi? _projectsApi;
  final AgentSettingsApi? settingsApi;
  final McpApi? mcpApi;
  final PluginApi? pluginApi;
  final SecurityAuditApi? securityAuditApi;
  final PushApi? pushApi;
  final ApiAccessLog? accessLog;

  /// Статическая web-сборка. null — сервер работает только как API.
  final StaticWeb? web;
  final String _token;
  final InternetAddress _address;
  final int _port;
  final Set<String> allowedOrigins;

  /// Требовать ли `X-Client-Session` для API, кроме health и handshake.
  ///
  /// Боевой демон работает с `true`: так сервер всегда знает, какое рабочее
  /// место сделало запрос. Тестовые фикстуры старых маршрутов могут явно
  /// отключить требование, но клиент всё равно шлёт сессию.
  final bool requireSession;

  /// Идентификатор этого запуска сервера. Новый процесс — новый id.
  ///
  /// Не переживает перезапуск: по нему клиент отличает «тот же экземпляр»
  /// от «сервер поднялся заново». Сессии живут только в памяти и связаны
  /// именно с этим запуском.
  final String instanceId;

  final ClientSessionRegistry _clientSessions;
  late final StreamSubscription<void> _sessionChangesSub;
  late final StreamSubscription<SharedResource>? _domainChangesSub;
  StreamSubscription<void>? _settingsChangesSub;

  /// Области, об изменении которых уже сообщили, но ещё не отправили событие.
  ///
  /// Всплеск `stateAreaChanged` склеивается: одно сообщение агента, смена
  /// заголовка и пересчёт проекта могут прийти почти одновременно, а окнам
  /// достаточно перечитать снимок один раз.
  final _pendingStateAreas = <String>{};

  /// Чаты, изменение которых уже случилось, но `chatChanged` ещё не отправлен.
  ///
  /// Копится в том же окне, что и [_pendingStateAreas], чтобы общий
  /// `stateAreaChanged` ушёл раньше: подписчики списков должны сначала
  /// увидеть изменение ресурса.
  final _pendingChatChanges = <String>{};
  Timer? _stateFlushTimer;

  /// Необязательный поток изменений доменных сервисов.
  ///
  /// В демоне это общий `DomainChangeBus`; тестовый сервер без него работает
  /// как раньше, а события `chatChanged`/`chatDeleted` по-прежнему приходят
  /// из конкретных маршрутов.
  final DomainChangeBus? domainChanges;

  /// Одновременные запросы ограничены, чтобы зависший backend не копил
  /// неограниченное число соединений.
  final int maxConcurrentRequests;

  /// Верхняя граница обработки одного запроса; SSE живёт по своему контракту.
  final Duration requestTimeout;

  final ApiRateLimiter _rateLimiter;
  var _activeRequests = 0;

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
    await _sessionChangesSub.cancel();
    await _domainChangesSub?.cancel();
    await _settingsChangesSub?.cancel();
    _stateFlushTimer?.cancel();
    _stateFlushTimer = null;
    _pendingStateAreas.clear();
    _pendingChatChanges.clear();
    _clientSessions.dispose();
    await _stateEvents.close();
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
    String? clientSession;
    String? errorCode;
    var sse = false;
    try {
      if (_applyCors(request, response)) {
        audit = false;
        return;
      }

      // Статика публичная и не должна расходовать API rate limit или слоты
      // одновременных запросов. API-пути остаются ниже, под токеном.
      if (web case final staticWeb? when !_isApiPath(request.uri.path)) {
        audit = false;
        await staticWeb.serve(request, response);
        return;
      }

      final remote = request.connectionInfo?.remoteAddress.address ?? 'unknown';
      final limit = _rateLimiter.consume(remote);
      if (!limit.allowed) {
        errorCode = 'rate_limited';
        _error(
          response,
          HttpStatus.tooManyRequests,
          'rate_limited',
          'too many requests',
          requestId: requestId,
          retryAfter: limit.retryAfter,
        );
        return;
      }

      if (request.method == 'GET' && request.uri.path == '/api/v1/health') {
        audit = false;
        _json(response, HttpStatus.ok, {
          'ok': true,
          'version': '1',
          'instanceId': instanceId,
        });
        return;
      }

      if (_activeRequests >= maxConcurrentRequests) {
        errorCode = 'server_busy';
        _error(
          response,
          HttpStatus.serviceUnavailable,
          'server_busy',
          'server is busy',
          requestId: requestId,
          retryAfter: const Duration(seconds: 1),
        );
        return;
      }

      _activeRequests++;
      try {
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
        final sessionHeader = request.headers.value(_clientSessionHeader);
        if (!_sessionExempt(request)) {
          if (sessionHeader == null || sessionHeader.isEmpty) {
            if (requireSession) {
              errorCode = 'session_required';
              _error(
                response,
                HttpStatus.badRequest,
                'session_required',
                'X-Client-Session is required',
                requestId: requestId,
              );
              return;
            }
          } else {
            final lookup = _clientSessions.touch(sessionHeader);
            if (lookup.session case final session?) {
              clientSession = session.id;
            } else {
              errorCode = 'session_expired';
              _error(
                response,
                HttpStatus.gone,
                errorCode,
                'session is unknown or expired',
                requestId: requestId,
              );
              return;
            }
          }
        }
        sse = request.method == 'GET' && request.uri.path == '/api/v1/events';
        if (sse) {
          _writeAccess(
            request,
            requestId: requestId,
            event: 'api.sse.open',
            auth: auth,
            token: token,
            clientSession: clientSession,
            status: HttpStatus.ok,
            durationMs: 0,
          );
        }
        await _routeWithTimeout(request, sse: sse);
      } finally {
        _activeRequests--;
      }
    } on TimeoutException {
      errorCode = 'request_timeout';
      _error(
        response,
        HttpStatus.gatewayTimeout,
        'request_timeout',
        'request timed out',
        requestId: requestId,
      );
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
    } on Object catch (error, stack) {
      errorCode = 'internal_error';
      AppLog.root.warning('API request failed: $error', error, stack);
      _error(
        response,
        HttpStatus.internalServerError,
        'internal_error',
        'internal server error',
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
          clientSession: clientSession,
          error: errorCode,
          status: response.statusCode,
          durationMs: stopwatch.elapsedMilliseconds,
        );
      }
    }
  }

  /// Выполняет маршрут под общим таймаутом. SSE не ограничивается: поток
  /// живёт до отключения клиента.
  Future<void> _routeWithTimeout(
    HttpRequest request, {
    required bool sse,
  }) async {
    final route = _route(request);
    if (sse) return route;
    try {
      await route.timeout(requestTimeout);
    } on TimeoutException {
      // Маршрут не отменяется силой: после ответа 504 его late-ошибка должна
      // попасть в лог, а не стать необработанным исключением.
      unawaited(
        route.catchError((Object error, StackTrace stack) {
          AppLog.root.warning('API route failed after timeout', error, stack);
        }),
      );
      rethrow;
    }
  }

  /// Ставит CORS-заголовки только для разрешённых origin. Preflight
  /// завершается здесь и не требует токена: браузер ещё не отправил его.
  bool _applyCors(HttpRequest request, HttpResponse response) {
    final origin = request.headers.value('origin');
    if (origin == null || !allowedOrigins.contains(origin)) return false;
    response.headers
      ..set('Access-Control-Allow-Origin', origin)
      ..set('Vary', 'Origin')
      ..set(
        'Access-Control-Allow-Methods',
        'GET, POST, PUT, PATCH, DELETE, OPTIONS',
      )
      ..set(
        'Access-Control-Allow-Headers',
        'Authorization, Content-Type, x-request-id, '
            'x-client-id, x-client-app, x-client-package, x-client-version, '
            'x-client-build, x-client-platform, x-client-session',
      )
      ..set('Access-Control-Max-Age', '600');
    if (request.method != 'OPTIONS') return false;
    response.statusCode = HttpStatus.noContent;
    return true;
  }

  static String _requestId(HttpRequest request) {
    final supplied = request.headers.value('x-request-id');
    if (supplied != null && _requestIdPattern.hasMatch(supplied)) {
      return supplied;
    }
    return _newRequestId();
  }

  /// Пути API никогда не отдаются статикой, даже если файл с таким именем
  /// случайно оказался в web-каталоге.
  static bool _isApiPath(String path) =>
      path == '/api' || path.startsWith('/api/');

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
    String? clientSession,
    String? error,
  }) {
    final log = accessLog;
    if (log == null) return;
    final clientId = _clientId(request);
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
      'instanceId': instanceId,
      'deviceId': _deviceId(request),
      'clientId': clientId.isEmpty ? null : ApiAccessLog.fingerprint(clientId),
      'clientSession': clientSession == null
          ? null
          : ApiAccessLog.fingerprint(clientSession),
      'auth': auth,
      'token': token,
      'error': error,
    });
  }

  static const _clientSessionHeader = 'x-client-session';

  /// Health, проверка демона и рукопожатие не могут требовать сессию:
  /// health открыт, probe и handshake работают по Bearer-токену.
  bool _sessionExempt(HttpRequest request) =>
      (request.method == 'GET' && request.uri.path == '/api/v1/health') ||
      (request.method == 'GET' && request.uri.path == '/api/v1/client/probe') ||
      (request.method == 'POST' &&
          request.uri.path == '/api/v1/client/handshake');

  /// Стабильный id установки из `X-Client-Id`.
  ///
  /// Заголовок необязателен: старый клиент присылает только отпечаток
  /// `X-Client-*`, и тогда группировка идёт по `deviceId`. Значение
  /// ограничиваем безопасным набором символов, чтобы оно не ломало JSON и
  /// подписи интерфейса.
  static String _clientId(HttpRequest request) {
    final raw = _clientHeader(request, 'x-client-id');
    if (raw == null) return '';
    final cleaned = raw.replaceAll(RegExp('[^A-Za-z0-9._-]'), '').trim();
    return cleaned.length <= 64
        ? cleaned
        : String.fromCharCodes(cleaned.codeUnits.take(64));
  }

  /// Короткий отпечаток `X-Client-*`.
  ///
  /// Это не стабильный идентификатор устройства: две вкладки одного браузера
  /// обычно дают один отпечаток, а обновление приложения его меняет. Нужен
  /// только для группировки сессий и журнала.
  static String _deviceId(HttpRequest request) {
    final parts = [
      _clientHeader(request, 'x-client-app') ?? '',
      _clientHeader(request, 'x-client-package') ?? '',
      _clientHeader(request, 'x-client-version') ?? '',
      _clientHeader(request, 'x-client-build') ?? '',
      _clientHeader(request, 'x-client-platform') ?? '',
    ];
    final digest = sha256.convert(utf8.encode(parts.join('\u001f')));
    return String.fromCharCodes(digest.toString().codeUnits.take(16));
  }

  static ClientSessionInfo _clientInfo(HttpRequest request) =>
      ClientSessionInfo(
        deviceId: _deviceId(request),
        clientId: _clientId(request),
        app: _clientHeader(request, 'x-client-app') ?? '',
        package: _clientHeader(request, 'x-client-package') ?? '',
        version: _clientHeader(request, 'x-client-version') ?? '',
        build: _clientHeader(request, 'x-client-build') ?? '',
        platform: _clientHeader(request, 'x-client-platform') ?? '',
      );

  /// Публикует изменение общей области, склеивая близкие всплески.
  ///
  /// Задержка в несколько десятков миллисекунд незаметна интерфейсу, но
  /// поток сообщений агента больше не заставляет каждое окно перечитывать
  /// список чатов на каждое сообщение.
  void _emitState(String area) {
    if (_stateEvents.isClosed) return;
    _pendingStateAreas.add(area);
    _scheduleStateFlush();
  }

  /// Запускает общее окно отправки областей и отложенных `chatChanged`.
  void _scheduleStateFlush() {
    _stateFlushTimer ??= Timer(
      const Duration(milliseconds: 50),
      _flushStateAreas,
    );
  }

  void _flushStateAreas() {
    _stateFlushTimer?.cancel();
    _stateFlushTimer = null;
    if (_stateEvents.isClosed) return;
    final areas = [..._pendingStateAreas];
    _pendingStateAreas.clear();
    for (final area in areas) {
      if (_stateEvents.isClosed) return;
      _stateEvents.add(_StateChanged(area));
    }
    // `chatChanged` идёт следом за областями: подписчики списков сначала
    // видят изменение ресурса, а затем уточнение по конкретному чату.
    final chatIds = [..._pendingChatChanges];
    _pendingChatChanges.clear();
    for (final chatId in chatIds) {
      if (_stateEvents.isClosed) return;
      _stateEvents.add(_ChatChanged(chatId));
    }
  }

  /// Сообщает всем клиентам, что чат удалён. Экран, где он был открыт,
  /// закрывает маршрут и очищает черновик, а не остаётся на пустой загрузке.
  void _emitChatDeleted(String chatId) {
    if (!_stateEvents.isClosed) _stateEvents.add(_ChatDeleted(chatId));
  }

  /// Откладывает `chatChanged` в то же окно, что и `stateAreaChanged`.
  ///
  /// Общий список чатов должен сначала увидеть изменение ресурса, поэтому
  /// `chatChanged` отправляется в конце окна, после областей. Микрозадача
  /// здесь не подходит: `_emitState` теперь откладывает области на таймер, и
  /// `chatChanged` обогнал бы их.
  void _scheduleChatChanged(String chatId) {
    if (_stateEvents.isClosed) return;
    _pendingChatChanges.add(chatId);
    _scheduleStateFlush();
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
        if (rest.length == 3 && rest[1] == 'secrets') {
          final id = rest.first;
          final name = rest[2];
          if (request.method == 'GET') {
            return _pluginSecretExists(request, id, name);
          }
          if (request.method == 'PUT') {
            return _savePluginSecret(request, id, name);
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
      case 'data':
        if (rest.length == 1 &&
            rest.first == 'usage' &&
            request.method == 'GET') {
          return _dataUsage(request);
        }
        if (rest.length == 2 &&
            rest.first == 'history' &&
            rest[1] == 'clear' &&
            request.method == 'POST') {
          return _clearHistory(request);
        }
        if (rest.length == 2 &&
            rest.first == 'settings' &&
            rest[1] == 'reset' &&
            request.method == 'POST') {
          return _resetSettings(request);
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
      case 'providers':
        if (rest.isEmpty && request.method == 'GET') {
          return _providerStatuses(request);
        }
        if (rest.length == 1 && request.method == 'GET') {
          return _providerStatus(request, rest.first);
        }
        if (rest.length == 1 && request.method == 'PUT') {
          return _saveProvider(request, rest.first);
        }
        if (rest.length == 2 &&
            rest[1] == 'check' &&
            request.method == 'POST') {
          return _checkProvider(request, rest.first);
        }
        if (rest.length == 2 && rest[1] == 'key' && request.method == 'POST') {
          return _saveProviderApiKey(request, rest.first);
        }
        if (rest.length == 2 &&
            rest[1] == 'key' &&
            request.method == 'DELETE') {
          await _requireSettingsApi().deleteProviderApiKey(rest.first);
          return _json(request.response, HttpStatus.noContent, {});
        }
      case 'models':
        if (rest.isEmpty && request.method == 'GET') return _models(request);
        if (rest.length == 1 &&
            rest.first == 'runtime' &&
            request.method == 'GET') {
          return _modelRuntime(request);
        }
        if (rest.length == 2 &&
            rest.first == 'runtime' &&
            (rest[1] == 'load' || rest[1] == 'unload') &&
            request.method == 'POST') {
          return _modelRuntimeAction(request, rest[1]);
        }
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
        if (rest.length == 1 &&
            rest.first == 'files' &&
            request.method == 'GET') {
          return _modelFiles(request);
        }
        if (rest.length == 2 && rest.first == 'files') {
          if (rest[1] == 'install' && request.method == 'POST') {
            return _installModelFile(request);
          }
          if (rest[1] == 'import' && request.method == 'POST') {
            return _importModelFile(request);
          }
          if (rest[1] == 'cancel' && request.method == 'POST') {
            return _cancelModelFile(request);
          }
          if (rest[1] == 'clear' && request.method == 'POST') {
            return _clearModelFiles(request);
          }
          if (rest[1] == 'auto-unload' && request.method == 'PUT') {
            return _saveModelAutoUnload(request);
          }
          if (request.method == 'PATCH') {
            return _updateModelFile(request, rest[1]);
          }
          if (request.method == 'DELETE') {
            return _deleteModelFile(request, rest[1]);
          }
        }
      case 'client':
        return _routeClient(request, rest);
      case 'search':
        if (rest.isEmpty && request.method == 'GET') return _search(request);
      case 'chats':
        return _routeChats(request, rest);
      case 'attention':
        return _routeAttention(request, rest);
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
      case 'events':
        if (rest.isEmpty && request.method == 'GET') return _events(request);
    }
    throw const AgentApiException(
      HttpStatus.notFound,
      'not_found',
      'unknown endpoint',
    );
  }

  Future<void> _routeClient(HttpRequest request, List<String> rest) async {
    if (rest.length == 1 && rest.first == 'probe' && request.method == 'GET') {
      return _probe(request);
    }
    if (rest.length == 1 &&
        rest.first == 'handshake' &&
        request.method == 'POST') {
      return _handshake(request);
    }
    if (rest.length == 1 &&
        rest.first == 'session' &&
        request.method == 'PUT') {
      return _heartbeat(request);
    }
    if (rest.length == 1 &&
        rest.first == 'session' &&
        request.method == 'DELETE') {
      return _deleteSession(request);
    }
    if (rest.length == 2 &&
        rest.first == 'sessions' &&
        request.method == 'DELETE') {
      return _deleteOtherSession(request, rest[1]);
    }
    if (rest.length == 1 &&
        rest.first == 'sessions' &&
        request.method == 'GET') {
      return _clientSessionList(request);
    }
    if (rest.length == 1 &&
        rest.first == 'subscriptions' &&
        request.method == 'PUT') {
      return _updateChatSubscriptions(request);
    }
    throw const AgentApiException(
      HttpStatus.notFound,
      'not_found',
      'unknown client endpoint',
    );
  }

  /// Проверка живого демона и токена без создания клиентской сессии.
  ///
  /// Нужна локальному GUI: discovery-файл подтверждает только адрес, а
  /// настоящий запрос к API без сессии получает `400 session_required`.
  /// Создавать сессию ради проверки и сразу удалять её — лишние события
  /// присутствия для остальных окон.
  Future<void> _probe(HttpRequest request) {
    _json(request.response, HttpStatus.ok, {
      'ok': true,
      'protocol': clientProtocol,
      'instanceId': instanceId,
    });
    return Future<void>.value();
  }

  /// Рукопожатие: сервер сам выдаёт сессию, клиент её только сохраняет.
  ///
  /// `previousSessionId` и `previousSessionSecret` — подсказка для
  /// непрерывности после reload, а не доказательство. Без секрета, выданного
  /// этой же сессии, id не переиспользуется: список сессий не должен
  /// позволять одному окну «усыновить» другое.
  Future<void> _handshake(HttpRequest request) async {
    final body = await _body(request);
    final protocol = body['protocol'] is num
        ? (body['protocol'] as num).toInt()
        : clientProtocol;
    if (protocol != clientProtocol) {
      throw const AgentApiException(
        HttpStatus.badRequest,
        'unsupported_protocol',
        'unsupported client protocol',
      );
    }
    final previous = body['previousSessionId'] is String
        ? body['previousSessionId'] as String
        : null;
    final previousSecret = body['previousSessionSecret'] is String
        ? body['previousSessionSecret'] as String
        : null;
    final session = _clientSessions.handshake(
      info: _clientInfo(request),
      previousSessionId: previous,
      previousSessionSecret: previousSecret,
    );
    _json(request.response, HttpStatus.ok, {
      'sessionId': session.id,
      // Секрет продолжения не попадает в список сессий: клиент хранит его
      // рядом с sessionId и присылает только в рукопожатии.
      'resumeSecret': session.resumeSecret,
      'instanceId': instanceId,
      'deviceId': session.deviceId,
      'clientId': session.clientId,
      'protocol': clientProtocol,
      'expiresAt': session.expiresAt.toUtc().toIso8601String(),
      'heartbeatIntervalMs': _clientSessions.heartbeatInterval.inMilliseconds,
      // Клиент продолжает нумерацию присутствия с этого значения. Без него
      // reload начинал бы ревизии заново, и сервер отклонял бы новые
      // обновления как устаревшие.
      'presenceRevision': session.presenceRevision,
    });
  }

  /// Heartbeat и необязательное присутствие: фокус и открытый чат.
  Future<void> _heartbeat(HttpRequest request) async {
    final sessionId = request.headers.value(_clientSessionHeader);
    if (sessionId == null || sessionId.isEmpty) {
      throw const AgentApiException(
        HttpStatus.gone,
        'session_expired',
        'session is unknown or expired',
      );
    }
    final body = await _body(request);
    // Браузер присылает closing из pagehide. Это не мгновенное удаление:
    // сессия закроется через closeGrace, если reload не успеет вернуться.
    if (body['closing'] == true) {
      final closing = _clientSessions.markClosing(sessionId);
      if (closing == null) {
        throw const AgentApiException(
          HttpStatus.gone,
          'session_expired',
          'session is unknown or expired',
        );
      }
      _json(request.response, HttpStatus.ok, {
        'expiresAt': closing.expiresAt.toUtc().toIso8601String(),
      });
      return;
    }
    final hasActiveChatId = body.containsKey('activeChatId');
    final focused = body['focused'];
    final revision = body['presenceRevision'];
    // Неизвестное значение не должно сделать устройство навсегда неактивным:
    // считаем его отсутствующим и сохраняем прежнее поведение по `focused`.
    final rawVisibility = body['visibility'];
    final visibility = switch (rawVisibility) {
      'foreground' || 'background' || 'locked' => rawVisibility as String,
      _ => null,
    };
    final hasVisibility = visibility != null;
    // Клиент присылает возраст последнего взаимодействия, а не абсолютное
    // время: часы устройства и сервера могут расходиться. Сервер переводит
    // возраст в свою отметку.
    final idleMs = body['idleMs'];
    final hasInteraction = idleMs is num && idleMs.isFinite && idleMs >= 0;
    DateTime? lastInteractionAt;
    if (hasInteraction) {
      // Ограничение защищает от абсурдного значения в теле и переполнения
      // Duration: для решения «активно или нет» достаточно суток.
      final idle = idleMs
          .toDouble()
          .clamp(0.0, const Duration(days: 1).inMilliseconds.toDouble())
          .toInt();
      lastInteractionAt = _clientSessions.now.subtract(
        Duration(milliseconds: idle),
      );
    }
    final atEnd = body['activeChatAtEnd'];
    final session = _clientSessions.updatePresence(
      sessionId,
      focused: focused is bool ? focused : null,
      activeChatId: hasActiveChatId && body['activeChatId'] is String
          ? body['activeChatId'] as String
          : null,
      activeChatIdSpecified: hasActiveChatId,
      visibility: visibility,
      visibilitySpecified: hasVisibility,
      lastInteractionAt: lastInteractionAt,
      interactionSpecified: hasInteraction,
      activeChatAtEnd: atEnd is bool ? atEnd : null,
      revision: revision is num && revision.isFinite ? revision.toInt() : null,
    );
    if (session == null) {
      throw const AgentApiException(
        HttpStatus.gone,
        'session_expired',
        'session is unknown or expired',
      );
    }
    _json(request.response, HttpStatus.ok, {
      'expiresAt': session.expiresAt.toUtc().toIso8601String(),
      // Принятая ревизия. Если клиент отстал (сессию делит другая вкладка),
      // его снимок отклонён как устаревший, и по этому значению он догоняет
      // сервер, а не остаётся незамеченным до перезагрузки.
      'presenceRevision': session.presenceRevision,
    });
  }

  Future<void> _deleteSession(HttpRequest request) {
    final sessionId = request.headers.value(_clientSessionHeader);
    if (sessionId != null && sessionId.isNotEmpty) {
      _clientSessions.remove(sessionId);
    }
    _json(request.response, HttpStatus.noContent, {});
    return Future<void>.value();
  }

  /// Убирает другое подключение по fingerprint из `GET /client/sessions`.
  ///
  /// Это не отзыв доступа: Bearer-токен и возможность пройти рукопожатие
  /// заново остаются. Действие нужно для зависших экранов, которые уже не
  /// держат SSE, но ещё видны в списке до истечения TTL. Сырой `sessionId` в
  /// списке не раскрывается, поэтому поиск идёт по тому же короткому
  /// fingerprint. Повторное удаление и несовпадение fingerprint безопасны:
  /// ответ всегда `204`, чтобы устаревший список не давал ошибку.
  Future<void> _deleteOtherSession(HttpRequest request, String fingerprint) {
    final at = _clientSessions.now;
    for (final session in _clientSessions.list()) {
      if (!session.isExpiredAt(at) &&
          ApiAccessLog.fingerprint(session.id) == fingerprint) {
        _clientSessions.remove(session.id);
        break;
      }
    }
    _json(request.response, HttpStatus.noContent, {});
    return Future<void>.value();
  }

  /// Снимок клиентских сессий для диагностики и UI.
  ///
  /// Сырой `sessionId` и `resumeSecret` наружу не отдаются: для списка
  /// достаточно fingerprint. Иначе соседнее окно могло бы попытаться
  /// продолжить чужую сессию, а для UI хватает короткой подписи.
  Future<void> _clientSessionList(HttpRequest request) {
    final current = request.headers.value(_clientSessionHeader);
    final at = _clientSessions.now;
    final sessions = _clientSessions.list();
    final attentionKey = _clientSessions.attentionDeviceKeyAt(at);
    _json(request.response, HttpStatus.ok, {
      'currentSessionId': current == null
          ? null
          : ApiAccessLog.fingerprint(current),
      'instanceId': instanceId,
      'presenceRevision': _clientSessions.revision,
      'sessions': [
        for (final session in sessions)
          _clientSessionJson(
            session,
            current: session.id == current,
            now: at,
            attentionDeviceKey: attentionKey,
          ),
      ],
    });
    return Future<void>.value();
  }

  /// Подписка экрана на тяжёлые события открытых чатов.
  ///
  /// Клиент присылает список при открытии и закрытии чата. Пока список не
  /// пришёл, сессия получает все события как старый клиент; после первого
  /// запроса сервер отдаёт дельты, очередь и сообщения только для указанных
  /// чатов. Карточки, удаление чата и присутствие остаются глобальными.
  Future<void> _updateChatSubscriptions(HttpRequest request) async {
    final body = await _body(request);
    final raw = body['chatIds'];
    final chatIds = <String>{};
    if (raw != null) {
      if (raw is! List) {
        throw const AgentApiException(
          HttpStatus.badRequest,
          'bad_subscriptions',
          'chatIds must be a list of strings',
        );
      }
      for (final item in raw) {
        if (item is String && item.isNotEmpty) chatIds.add(item);
      }
    }
    final sessionId = request.headers.value(_clientSessionHeader);
    if (sessionId != null && sessionId.isNotEmpty) {
      final session = _clientSessions.updateChatSubscriptions(
        sessionId,
        chatIds,
      );
      if (session == null) {
        throw const AgentApiException(
          HttpStatus.gone,
          'session_expired',
          'session is unknown or expired',
        );
      }
    }
    _json(request.response, HttpStatus.noContent, {});
  }

  Map<String, Object?> _clientSessionJson(
    ClientSession session, {
    required bool current,
    required DateTime now,
    required String? attentionDeviceKey,
  }) {
    final deviceKey = ClientSessionRegistry.deviceKeyOf(session);
    return {
      // Короткий fingerprint вместо сырого id: список нужен для группировки и
      // подписи, а не для продолжения сессии.
      'id': ApiAccessLog.fingerprint(session.id),
      'deviceId': session.deviceId,
      'clientId': session.clientId,
      'clientApp': session.clientApp,
      'clientPackage': session.clientPackage,
      'clientVersion': session.clientVersion,
      'clientBuild': session.clientBuild,
      'clientPlatform': session.clientPlatform,
      'createdAt': session.createdAt.toUtc().toIso8601String(),
      'lastSeenAt': session.lastSeenAt.toUtc().toIso8601String(),
      'expiresAt': session.expiresAt.toUtc().toIso8601String(),
      'focused': session.focused,
      'visibility': session.visibility,
      'lastInteractionAt': session.lastInteractionAt?.toUtc().toIso8601String(),
      'activeChatId': session.activeChatId,
      'activeChatAtEnd': session.activeChatAtEnd,
      // Именно экран, а не всё устройство: фоновое окно того же клиента не
      // должно выглядеть как «пользователь здесь» и глушить уведомления.
      'active': session.isPresentAt(now, _clientSessions.activeTimeout),
      'attention': deviceKey == attentionDeviceKey,
      'presenceRevision': session.presenceRevision,
      'online': !session.isExpiredAt(now),
      'current': current,
    };
  }

  /// Входящие: сводный снимок и ручное скрытие проблемы.
  ///
  /// Отдельный маршрут, а не поле в `GET /chats`: старый клиент не должен
  /// получать тяжёлые карточки, а новый экран — перечитывать весь список
  /// чатов ради одного счётчика.
  Future<void> _routeAttention(HttpRequest request, List<String> rest) async {
    if (rest.length == 1 && rest.first == 'digest' && request.method == 'GET') {
      final api = _requireAttentionDigestApi();
      final digest = await api.attentionDigest();
      return _json(
        request.response,
        HttpStatus.ok,
        _attentionDigestJson(digest),
      );
    }
    final api = _requireAttentionApi();
    if (rest.isEmpty && request.method == 'GET') {
      final snapshot = await api.attention();
      return _json(request.response, HttpStatus.ok, _attentionJson(snapshot));
    }
    // Общая пауза уведомлений. Срок и причину выбирает клиент: «до утра» —
    // это утро в его часовом поясе.
    if (rest.length == 1 && rest.first == 'pause') {
      final pauseApi = _requireAttentionPauseApi();
      if (request.method == 'PUT') {
        final body = await _body(request);
        await pauseApi.pauseNotifications(
          _utcDeadline(body),
          reason: _pauseReason(body['reason']),
        );
        return _json(request.response, HttpStatus.noContent, {});
      }
      if (request.method == 'DELETE') {
        await pauseApi.resumeNotifications();
        return _json(request.response, HttpStatus.noContent, {});
      }
    }
    // Напоминание о чате. `rest.first` — chatId; срок приходит в теле, чтобы
    // клиент сам выбрал «через час» или «завтра утром» и не зависел от часов
    // сервера.
    if (rest.length == 2 && rest.last == 'snooze') {
      final snoozeApi = _requireAttentionSnoozeApi();
      if (request.method == 'PUT') {
        final body = await _body(request);
        await snoozeApi.snoozeAttention(rest.first, _utcDeadline(body));
        return _json(request.response, HttpStatus.noContent, {});
      }
      if (request.method == 'DELETE') {
        await snoozeApi.unsnoozeAttention(rest.first);
        return _json(request.response, HttpStatus.noContent, {});
      }
    }
    if (rest.length == 1 && request.method == 'DELETE') {
      await api.dismissAttention(rest.first);
      return _json(request.response, HttpStatus.noContent, {});
    }
    throw const AgentApiException(
      HttpStatus.notFound,
      'not_found',
      'unknown attention endpoint',
    );
  }

  /// Срок из тела `PUT /attention/{chatId}/snooze` и `PUT /attention/pause`.
  ///
  /// Принимается ISO-8601 с часовым поясом или без: без пояса время считается
  /// UTC, чтобы одинаковый запрос из разных часовых поясов не сдвигал срок.
  static DateTime _utcDeadline(Map<String, dynamic> body) {
    final raw = _string(body, 'until');
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) {
      throw const AgentApiException(
        HttpStatus.badRequest,
        'bad_field',
        'expected ISO-8601 date field "until"',
      );
    }
    if (parsed.isUtc) return parsed;
    // `DateTime.parse` без пояса возвращает локальное время. Для контракта
    // такие поля — UTC, поэтому берём те же календарные значения как UTC.
    return DateTime.utc(
      parsed.year,
      parsed.month,
      parsed.day,
      parsed.hour,
      parsed.minute,
      parsed.second,
      parsed.millisecond,
      parsed.microsecond,
    );
  }

  /// Причина паузы из тела запроса. Неизвестное значение — ошибка, а не тихая
  /// подмена: клиент и сервер должны одинаково понимать подпись.
  static NotificationPauseReason _pauseReason(Object? raw) {
    if (raw == null) return NotificationPauseReason.focus;
    if (raw is String) {
      for (final reason in NotificationPauseReason.values) {
        if (reason.name == raw) return reason;
      }
    }
    throw const AgentApiException(
      HttpStatus.badRequest,
      'bad_field',
      'unknown notification pause reason',
    );
  }

  AttentionApi _requireAttentionApi() {
    final Object backend = _backend;
    if (backend is AttentionApi) return backend;
    throw const AgentApiException(
      HttpStatus.notImplemented,
      'not_supported',
      'attention API is not available',
    );
  }

  AttentionSnoozeApi _requireAttentionSnoozeApi() {
    final Object backend = _backend;
    if (backend is AttentionSnoozeApi) return backend;
    throw const AgentApiException(
      HttpStatus.notImplemented,
      'not_supported',
      'attention snooze API is not available',
    );
  }

  AttentionPauseApi _requireAttentionPauseApi() {
    final Object backend = _backend;
    if (backend is AttentionPauseApi) return backend;
    throw const AgentApiException(
      HttpStatus.notImplemented,
      'not_supported',
      'attention pause API is not available',
    );
  }

  AttentionDigestApi _requireAttentionDigestApi() {
    final Object backend = _backend;
    if (backend is AttentionDigestApi) return backend;
    throw const AgentApiException(
      HttpStatus.notImplemented,
      'not_supported',
      'attention digest API is not available',
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
        final deleted = await _backend.deleteChat(id);
        // Бэкенд отдаёт и субагентов, удалённых каскадом. Пустой ответ
        // означает старый/внешний бэкенд: корневой чат всё равно закрываем.
        final ids = deleted.isEmpty ? [id] : deleted;
        for (final chatId in ids) {
          _emitChatDeleted(chatId);
        }
        return _json(request.response, HttpStatus.ok, {'chatIds': ids});
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
        case 'read':
          if (rest.length == 2 && request.method == 'PUT') {
            return _markChatRead(request, chatId);
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
        case 'scheduled-tasks':
          if (rest.length == 2 && request.method == 'GET') {
            return _scheduledTaskCount(request, chatId);
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
            return _removeQueued(request, chatId, rest[2]);
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

  Future<void> _search(HttpRequest request) async {
    final text = request.uri.queryParameters['q']?.trim() ?? '';
    if (text.isEmpty) {
      return _json(request.response, HttpStatus.ok, {'hits': []});
    }
    final scopeName = request.uri.queryParameters['scope'] ?? 'all';
    final scope = SearchScope.values.asNameMap()[scopeName] ?? SearchScope.all;
    final limit =
        (int.tryParse(request.uri.queryParameters['limit'] ?? '') ?? 20).clamp(
          1,
          50,
        );
    final hits = await _backend.search(
      SearchQuery(
        text: text,
        scope: scope,
        projectId: request.uri.queryParameters['projectId'],
        chatId: request.uri.queryParameters['chatId'],
        limit: limit,
      ),
    );
    return _json(request.response, HttpStatus.ok, {
      'hits': [for (final hit in hits) _searchHitJson(hit)],
    });
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
    // Поиск существующего проекта для нового чата: без создания и без обхода
    // файлов. Сканирование начинается только после /projects/{id}/mentions.
    if (rest.length == 1 && rest.first == 'lookup' && request.method == 'GET') {
      final hostId = request.uri.queryParameters['hostId'] ?? '';
      final workspace = request.uri.queryParameters['workspace'] ?? '';
      final project = await api.find(hostId: hostId, workspace: workspace);
      return _json(request.response, HttpStatus.ok, {
        'project': project == null ? null : _projectJson(project),
      });
    }
    if (rest.length == 2 && rest[1] == 'mentions' && request.method == 'GET') {
      final query = request.uri.queryParameters['q'] ?? '';
      final entries = await api.searchMentions(rest.first, query);
      return _json(request.response, HttpStatus.ok, {
        'entries': [for (final entry in entries) entry.toJson()],
      });
    }
    if (rest.length == 1) {
      final id = rest.first;
      if (request.method == 'PUT' || request.method == 'PATCH') {
        final body = await _body(request);
        await api.saveProject(
          _projectFromJson(id, body),
          expectedRevision: _expectedRevisionOf(body),
        );
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
      if (rest[1] == 'memory' && request.method == 'GET') {
        final memory = await api.watchMemory(id).first;
        return _json(request.response, HttpStatus.ok, {
          'memory': memory == null ? null : _memoryJson(memory),
        });
      }
      if (rest[1] == 'skills' && request.method == 'GET') {
        final skills = await api.watchSkills(id).first;
        return _json(request.response, HttpStatus.ok, {
          'skills': [for (final skill in skills) _skillJson(skill)],
        });
      }
      if (rest[1] == 'memory' && request.method == 'POST') {
        final body = await _body(request);
        final instruction = '${body['instruction'] ?? ''}'.trim();
        if (instruction.isEmpty) {
          throw const AgentApiException(
            HttpStatus.badRequest,
            'invalid_memory_instruction',
            'memory instruction is empty',
          );
        }
        await api.reviseMemory(id, instruction);
        final memory = await api.watchMemory(id).first;
        return _json(request.response, HttpStatus.ok, {
          'memory': memory == null ? null : _memoryJson(memory),
        });
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
    await _requireMcpApi().save(
      mcpServerFromJson(id, body),
      expectedRevision: _expectedRevisionOf(body),
    );
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
    await _requirePluginApi().setEnabled(
      {
        for (final id in rawIds)
          if (id is String) id,
      },
      enabled: enabled,
      expectedRevision: _revisionOf(body),
    );
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

  Future<void> _pluginSecretExists(
    HttpRequest request,
    String id,
    String name,
  ) async {
    final exists = await _requirePluginApi().settingsFor(id).hasSecret(name);
    _json(request.response, HttpStatus.ok, {'exists': exists});
  }

  Future<void> _savePluginSecret(
    HttpRequest request,
    String id,
    String name,
  ) async {
    final body = await _body(request);
    final value = body['value'];
    if (value != null && value is! String) {
      throw const AgentApiException(
        HttpStatus.badRequest,
        'bad_secret',
        'value must be a string or null',
      );
    }
    await _requirePluginApi()
        .settingsFor(id)
        .writeSecret(name, value as String?);
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
      'revision': settings.revision,
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
      expectedRevision: _revisionOf(body),
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
      expectedRevision: _expectedRevisionOf(body),
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
    _scheduleChatChanged(id);
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
    final reasoning = body['reasoning'] is String
        ? ReasoningPreference.parse(body['reasoning'] as String?)
        : null;
    final chatApi = _chatApi;
    if (chatApi != null) {
      await chatApi.chatStore.updateChat(
        id,
        title: body['title'] is String ? body['title'] as String : null,
        model: body['model'] is String ? body['model'] as String : null,
        reasoning: reasoning,
        policyMode: policy,
        workspace: body['workspace'] is String
            ? body['workspace'] as String
            : null,
        workspaceSpecified: body['workspaceSpecified'] == true,
        expectedRevision: _revisionOf(body),
      );
    } else {
      // Тестовый backend без ChatApi: сохраняем прежний путь обновления.
      await _backend.updateChat(
        id,
        title: body['title'] is String ? body['title'] as String : null,
        model: body['model'] is String ? body['model'] as String : null,
        reasoning: reasoning,
        policyMode: policy,
        workspace: body['workspace'] is String
            ? body['workspace'] as String
            : null,
        workspaceSpecified: body['workspaceSpecified'] == true,
      );
    }
    _scheduleChatChanged(id);
    _json(request.response, HttpStatus.noContent, {});
  }

  /// Сколько отложенных задач чата ещё не сработало. Клиент спрашивает это
  /// перед форком, чтобы не показывать вопрос впустую.
  Future<void> _scheduledTaskCount(HttpRequest request, String chatId) async {
    final count = await _backend.pendingScheduledTasks(
      chatId,
      untilMessageId: request.uri.queryParameters['untilMessageId'],
    );
    _json(request.response, HttpStatus.ok, {'count': count});
  }

  Future<void> _forkChat(HttpRequest request, String chatId) async {
    final body = await _body(request);
    final chat = await _backend.forkChat(
      chatId,
      title: body['title'] is String ? body['title'] as String : null,
      untilMessageId: body['untilMessageId'] is String
          ? body['untilMessageId'] as String
          : null,
      copyPendingTasks: body['copyPendingTasks'] == true,
    );
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

  DataApi _requireDataApi() {
    final data = dataApi;
    if (data == null) {
      throw const AgentApiException(
        HttpStatus.notImplemented,
        'not_supported',
        'data API is not available',
      );
    }
    return data;
  }

  Future<void> _dataUsage(HttpRequest request) async {
    final usage = await _requireDataApi().usage();
    _json(request.response, HttpStatus.ok, usage.toJson());
  }

  Future<void> _clearHistory(HttpRequest request) async {
    final body = await _body(request);
    final raw = body['olderThanDays'];
    final int? olderThanDays;
    if (raw == null) {
      olderThanDays = null;
    } else if (raw is num && raw.isFinite && raw >= 1 && raw % 1 == 0) {
      olderThanDays = raw.toInt();
    } else {
      throw const AgentApiException(
        HttpStatus.badRequest,
        'bad_request',
        'olderThanDays must be a positive number',
      );
    }
    final result = await _requireDataApi().clearHistory(
      olderThanDays: olderThanDays,
    );
    // Очистка удаляет чаты каскадом, а не через DELETE /chats/{id}. Без
    // отдельного события открытые экраны этих чатов остались бы в других окнах.
    for (final chatId in result.deletedChatIds) {
      _emitChatDeleted(chatId);
    }
    _json(request.response, HttpStatus.ok, result.toJson());
  }

  Future<void> _resetSettings(HttpRequest request) async {
    await _requireDataApi().resetSettings();
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _settings(HttpRequest request) async {
    final snapshot = await _requireSettingsApi().load();
    _json(request.response, HttpStatus.ok, {
      'defaultModel': snapshot.defaultModel,
      'titleModel': snapshot.titleModel,
      'memoryModel': snapshot.memoryModel,
      'subagentModel': snapshot.subagentModel,
      'fallbackModel': snapshot.fallbackModel,
      'defaultReasoning': snapshot.defaultReasoning.name,
      'memoryReasoning': snapshot.memoryReasoning.name,
      'subagentReasoning': snapshot.subagentReasoning.name,
      'fallbackReasoning': snapshot.fallbackReasoning.name,
      'defaultPolicy': snapshot.defaultPolicy,
      'denylist': snapshot.denylist,
      'securityProfile': snapshot.securityProfile.encode(),
      'limits': snapshot.limits.toMap(),
      'pinnedModels': snapshot.pinnedModels,
      'steps': _stepsJson(snapshot.stepsDisplay),
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

  Future<void> _providerStatuses(HttpRequest request) async {
    final statuses = await _requireSettingsApi().providerStatuses();
    _json(request.response, HttpStatus.ok, {
      'providers': [for (final status in statuses) _providerStatusJson(status)],
    });
  }

  Future<void> _providerStatus(HttpRequest request, String providerId) async {
    final statuses = await _requireSettingsApi().providerStatuses();
    for (final status in statuses) {
      if (status.id == providerId) {
        return _json(
          request.response,
          HttpStatus.ok,
          _providerStatusJson(status),
        );
      }
    }
    throw AgentApiException(
      HttpStatus.notFound,
      'provider_not_found',
      'AI provider $providerId is not registered',
    );
  }

  Future<void> _saveProvider(HttpRequest request, String providerId) async {
    await _ensureProvider(providerId);
    final body = await _body(request);
    if (!body.containsKey('enabled') && !body.containsKey('baseUrl')) {
      throw const AgentApiException(
        HttpStatus.badRequest,
        'bad_provider_settings',
        'enabled or baseUrl is required',
      );
    }
    final api = _requireSettingsApi();
    if (body.containsKey('enabled')) {
      await api.setProviderEnabled(providerId, body['enabled'] == true);
    }
    if (body.containsKey('baseUrl')) {
      final value = body['baseUrl'];
      await api.saveProviderBaseUrl(providerId, value is String ? value : null);
    }
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _saveProviderApiKey(
    HttpRequest request,
    String providerId,
  ) async {
    await _ensureProvider(providerId);
    final body = await _body(request);
    try {
      final status = await _requireSettingsApi().saveProviderApiKey(
        providerId,
        _string(body, 'key'),
      );
      _json(request.response, HttpStatus.ok, _providerStatusJson(status));
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(
        AgentApiException(HttpStatus.badRequest, 'api_key_rejected', '$error'),
        stackTrace,
      );
    }
  }

  Future<void> _checkProvider(HttpRequest request, String providerId) async {
    await _ensureProvider(providerId);
    final status = await _requireSettingsApi().checkProvider(providerId);
    _json(request.response, HttpStatus.ok, _providerStatusJson(status));
  }

  /// Проверяет, что провайдер зарегистрирован. Иначе 404, а не 500
  /// из недр локального адаптера.
  Future<void> _ensureProvider(String providerId) async {
    final statuses = await _requireSettingsApi().providerStatuses();
    if (statuses.any((status) => status.id == providerId)) return;
    throw AgentApiException(
      HttpStatus.notFound,
      'provider_not_found',
      'AI provider $providerId is not registered',
    );
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

  Future<void> _modelRuntime(HttpRequest request) {
    final runtime = _requireSettingsApi().modelRuntime;
    _json(request.response, HttpStatus.ok, runtime.runtime.toJson());
    return Future<void>.value();
  }

  Future<void> _modelRuntimeAction(HttpRequest request, String action) async {
    final body = await _body(request);
    final model = _string(body, 'model');
    final runtime = _requireSettingsApi().modelRuntime;
    try {
      if (action == 'load') {
        await runtime.loadModel(model);
      } else {
        await runtime.unloadModel(model);
      }
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(
        AgentApiException(
          HttpStatus.badRequest,
          'model_runtime_failed',
          '$error',
        ),
        stackTrace,
      );
    }
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _modelFiles(HttpRequest request) {
    final models = _requireSettingsApi().localModels;
    _json(request.response, HttpStatus.ok, models.state.toJson());
    return Future<void>.value();
  }

  Future<void> _installModelFile(HttpRequest request) async {
    final body = await _body(request);
    final source = _string(body, 'source');
    try {
      final id = await _requireSettingsApi().localModels.startInstall(
        source,
        name: _optionalString(body, 'name'),
        sha256: _optionalString(body, 'sha256'),
      );
      _json(request.response, HttpStatus.ok, {'id': id});
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(_localModelsFailure(error), stackTrace);
    }
  }

  Future<void> _importModelFile(HttpRequest request) async {
    final body = await _body(request);
    final path = _string(body, 'path');
    try {
      final id = await _requireSettingsApi().localModels.importPath(
        path,
        name: _optionalString(body, 'name'),
      );
      _json(request.response, HttpStatus.ok, {'id': id});
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(_localModelsFailure(error), stackTrace);
    }
  }

  Future<void> _cancelModelFile(HttpRequest request) async {
    final body = await _body(request);
    await _requireSettingsApi().localModels.cancelInstall(_string(body, 'id'));
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _clearModelFiles(HttpRequest request) async {
    try {
      await _requireSettingsApi().localModels.clearCache();
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(_localModelsFailure(error), stackTrace);
    }
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _saveModelAutoUnload(HttpRequest request) async {
    final body = await _body(request);
    final minutes = body['minutes'];
    if (minutes is! int || minutes < 0) {
      throw const AgentApiException(
        HttpStatus.badRequest,
        'bad_minutes',
        'minutes must be a non-negative integer',
      );
    }
    await _requireSettingsApi().localModels.saveAutoUnload(minutes);
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _updateModelFile(HttpRequest request, String id) async {
    final body = await _body(request);
    final settings = LocalModelSettings.fromJson(body['settings']);
    try {
      await _requireSettingsApi().localModels.updateSettings(id, settings);
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(_localModelsFailure(error), stackTrace);
    }
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _deleteModelFile(HttpRequest request, String id) async {
    try {
      await _requireSettingsApi().localModels.delete(id);
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(_localModelsFailure(error), stackTrace);
    }
    _json(request.response, HttpStatus.noContent, {});
  }

  /// Ошибка среды выполнения → 400 с текстом причины.
  static AgentApiException _localModelsFailure(Object error) =>
      AgentApiException(
        HttpStatus.badRequest,
        'local_models_failed',
        error is AppFailure ? error.message : '$error',
      );

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
        mentions: _mentions(body['mentions']),
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
          mentions: entry.value is Map
              ? _mentions(entry.value['mentions'])
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

  /// Двигает общий курсор прочтения чата.
  ///
  /// `seq` — последнее сообщение, которое устройство действительно видело.
  /// Сервер сам ограничивает его последним записанным сообщением и не
  /// двигает курсор назад. `chatReadChanged` нужен остальным окнам: список
  /// чатов уменьшает unread, а позиция прокрутки у каждого устройства своя.
  Future<void> _markChatRead(HttpRequest request, String chatId) async {
    final body = await _body(request);
    final raw = body['seq'];
    if (raw is! num || !raw.isFinite) {
      throw const AgentApiException(
        HttpStatus.badRequest,
        'bad_seq',
        'seq must be a number',
      );
    }
    final seq = raw.toInt();
    if (seq < 0) {
      throw const AgentApiException(
        HttpStatus.badRequest,
        'bad_seq',
        'seq must not be negative',
      );
    }
    final chat = await _backend.markChatRead(
      chatId,
      seq: seq,
      expectedRevision: _expectedRevisionOf(body),
    );
    _emitState(SharedResource.chats.area);
    if (!_stateEvents.isClosed) {
      _stateEvents.add(
        _ChatReadChanged(
          chatId,
          lastReadSeq: chat.lastReadSeq,
          lastMessageSeq: chat.lastMessageSeq,
          unreadCount: chat.unreadCount,
          readRevision: chat.readRevision,
        ),
      );
    }
    _json(
      request.response,
      HttpStatus.ok,
      _chatJson(
        chat,
        running: _backend.runningChatIds.contains(chat.id),
        waiting: _backend.waitingChatIds.contains(chat.id),
      ),
    );
  }

  int? _revisionOf(Map<String, dynamic> body) {
    final raw = body['expectedRevision'] ?? body['revision'];
    return raw is num ? raw.toInt() : null;
  }

  /// Ревизия, на которой основана форма полного объекта (хост, проект,
  /// MCP-сервер). Отсутствие `expectedRevision` — старый клиент или служебная
  /// запись: проверка не выполняется, иначе такая запись не смогла бы
  /// сохранить уже существующий объект.
  int? _expectedRevisionOf(Map<String, dynamic> body) {
    final raw = body['expectedRevision'];
    return raw is num ? raw.toInt() : null;
  }

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
      'queueRevision': session.queueRevision,
      'queue': [for (final item in session.queue) _queueJson(item)],
      'turnSnapshot': _turnSnapshotJson(session.turnSnapshot),
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
      final accepted = await _session(chatId).editUserMessage(
        messageId,
        _string(body, 'text'),
        attachments: body['attachments'] == null
            ? null
            : _attachments(body['attachments']),
        mentions: body['mentions'] == null ? null : _mentions(body['mentions']),
      );
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
    String itemId,
  ) async {
    final body = await _body(request);
    if (body['position'] != null && body['position'] != 0) {
      throw const AgentApiException(
        HttpStatus.badRequest,
        'bad_position',
        'only position 0 is supported',
      );
    }
    final revision = _revisionOf(body);
    if (revision == null) {
      throw const AgentApiException(
        HttpStatus.badRequest,
        'revision_required',
        'expectedRevision is required',
      );
    }
    final applied = await _session(chatId)
        .promoteQueued(itemId, expectedRevision: revision);
    if (!applied) throw _queueConflict();
    _json(request.response, HttpStatus.noContent, {});
  }

  Future<void> _removeQueued(
    HttpRequest request,
    String chatId,
    String itemId,
  ) async {
    final revision = int.tryParse(
      request.uri.queryParameters['expectedRevision'] ?? '',
    );
    if (revision == null) {
      throw const AgentApiException(
        HttpStatus.badRequest,
        'revision_required',
        'expectedRevision is required',
      );
    }
    final item = await _session(chatId)
        .takeQueued(itemId, expectedRevision: revision);
    if (item == null) throw _queueConflict();
    _json(request.response, HttpStatus.noContent, {});
  }

  /// Действие с очередью основано на устаревшем снимке.
  ///
  /// Клиент перечитывает очередь и повторяет действие только осознанно:
  /// сервер не подставляет элемент по позиции.
  AgentApiException _queueConflict() => const AgentApiException(
    HttpStatus.conflict,
    'queue_conflict',
    'queue changed; reload the queue',
  );

  Future<void> _send(HttpRequest request, String chatId) async {
    final body = await _body(request);
    final text = body['text'] is String ? body['text'] as String : '';
    final attachments = _attachments(body['attachments']);
    final clientMessageId = body['clientMessageId'] is String
        ? body['clientMessageId'] as String
        : null;
    await _backend.send(
      chatId,
      text,
      sendNow: body['sendNow'] == true,
      attachments: attachments,
      mentions: _mentions(body['mentions']),
      clientMessageId: clientMessageId,
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
    final answerId = body['answerId'] is String
        ? body['answerId'] as String
        : null;
    // Ключ идемпотентности приходит только из действий уведомлений.
    // Обычный ответ из карточки обходится без него.
    await _backend.answerQuestion(
      id,
      value is String ? value : null,
      answerId: answerId,
    );
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

  /// SSE-поток всех событий или одного чата (`?chatId=`).
  Future<void> _events(HttpRequest request, {String? chatId}) async {
    final response = request.response;
    final sessionId = request.headers.value(_clientSessionHeader);
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
    if (sessionId != null && sessionId.isNotEmpty) {
      _clientSessions.attach(sessionId, response);
    }
    response.write(': connected\n\n');
    await response.flush();
    final currentSessionFingerprint = sessionId == null || sessionId.isEmpty
        ? null
        : ApiAccessLog.fingerprint(sessionId);

    /// Тяжёлые события нужны только открытым чатам этого экрана.
    ///
    /// `null` — ограничения нет: старый клиент без подписок или явный
    /// чат-фильтр в URL. Список читается на каждое событие, а не один раз при
    /// подключении: клиент может открыть чат уже после установки SSE.
    Set<String>? subscriptions() {
      if (filterChatId != null) return null;
      if (sessionId == null || sessionId.isEmpty) return null;
      return _clientSessions.byId(sessionId)?.chatSubscriptions;
    }

    void writeEvent(Object event) {
      final encoded = _event(
        event,
        currentSessionFingerprint: currentSessionFingerprint,
      );
      try {
        response.write(
          'event: ${encoded.$1}\ndata: ${jsonEncode(encoded.$2)}\n\n',
        );
      } on Object {
        // DELETE сессии или обрыв клиента уже закрыли ответ. Новые события
        // этому потоку не нужны, но общий поток не должен падать.
      }
    }

    // Дельты одного вида и чата склеиваются на коротком окне. Один токен —
    // одно SSE-сообщение слишком дорого: заголовки события и JSON больше
    // самого текста, а UI всё равно перерисовывается кадрами.
    final pendingDeltas = <String, _PendingDelta>{};
    Timer? deltaTimer;
    void flushDeltas() {
      deltaTimer?.cancel();
      deltaTimer = null;
      if (pendingDeltas.isEmpty) return;
      final deltas = [...pendingDeltas.values];
      pendingDeltas.clear();
      for (final delta in deltas) {
        try {
          response.write(
            'event: ${delta.event}\n'
            'data: ${jsonEncode({'chatId': delta.chatId, 'text': delta.text.toString(), 'reset': delta.reset})}\n\n',
          );
        } on Object {
          // Соединение закрыто: остальные дельты тоже не нужны.
        }
      }
    }

    void scheduleDeltaFlush() {
      deltaTimer ??= Timer(const Duration(milliseconds: 40), flushDeltas);
    }

    // Сообщение чужого чата не отправляем, но списку чатов нужно знать, что
    // оно появилось. Одно лёгкое событие на всплеск вместо полного текста.
    Timer? chatListTimer;
    void scheduleChatListChanged() {
      chatListTimer ??= Timer(const Duration(milliseconds: 50), () {
        chatListTimer = null;
        writeEvent(_StateChanged(SharedResource.chats.area));
      });
    }

    // Подписку ставим после flush: runtime может прислать снимок сразу,
    // а запись в ответ во время flush недопустима.
    final subscription = _allEvents().listen((event) {
      if (!_matchesChat(event, filterChatId)) return;
      final subscribed = subscriptions();
      if (event is AgentMessageAdded &&
          subscribed != null &&
          !subscribed.contains(event.chatId)) {
        scheduleChatListChanged();
        return;
      }
      if (subscribed != null && _isHeavyChatEvent(event)) {
        final eventChatId = _eventChatId(event);
        if (eventChatId == null || !subscribed.contains(eventChatId)) return;
      }
      switch (event) {
        case AgentTextDelta():
          final key = 'textDelta:${event.chatId}';
          final current = pendingDeltas[key];
          if (current == null || event.reset) {
            pendingDeltas[key] = _PendingDelta(
              'textDelta',
              event.chatId,
              event.reset,
              StringBuffer(event.text),
            );
          } else {
            current.text.write(event.text);
          }
          scheduleDeltaFlush();
          return;
        case AgentReasoningDelta():
          final key = 'reasoningDelta:${event.chatId}';
          final current = pendingDeltas[key];
          if (current == null || event.reset) {
            pendingDeltas[key] = _PendingDelta(
              'reasoningDelta',
              event.chatId,
              event.reset,
              StringBuffer(event.text),
            );
          } else {
            current.text.write(event.text);
          }
          scheduleDeltaFlush();
          return;
        default:
          // Всё, что идёт после дельт, должно попасть в поток после них.
          flushDeltas();
          writeEvent(event);
      }
    });
    // Клиент, подключившийся посреди ответа, не получит уже отправленные
    // дельты. Сразу отдаём снимок текущего шага.
    final subscribedNow = subscriptions();
    final snapshotChats = filterChatId != null
        ? {filterChatId}
        : subscribedNow == null
        ? _backend.runningChatIds
        : _backend.runningChatIds.where(subscribedNow.contains).toSet();
    for (final snapshotChatId in snapshotChats) {
      final session = _chatApi?.session(snapshotChatId);
      final snapshot = session?.turnSnapshot;
      if (snapshot == null || !snapshot.isRunning) continue;
      try {
        response.write(
          'event: turnSnapshot\n'
          'data: ${jsonEncode({'chatId': snapshotChatId, ..._turnSnapshotJson(snapshot)})}\n\n',
        );
      } on Object {
        // Соединение уже закрыто.
      }
    }
    var pinging = false;
    Future<void> ping() async {
      if (pinging) return;
      pinging = true;
      try {
        response.write(': ping\n\n');
        await response.flush();
        // Поток жив: продлеваем сессию даже если heartbeat клиента
        // заторможен браузером в фоновой вкладке.
        if (sessionId != null && sessionId.isNotEmpty) {
          _clientSessions.keepAlive(sessionId);
        }
      } on Object {
        // Ответ закрыт: окончательную очистку сделает response.done.
      } finally {
        pinging = false;
      }
    }

    final heartbeat = Timer.periodic(_eventHeartbeat, (_) => unawaited(ping()));
    try {
      await response.done;
    } on Object {
      // Клиент закрыл соединение.
    } finally {
      heartbeat.cancel();
      deltaTimer?.cancel();
      chatListTimer?.cancel();
      await subscription.cancel();
      _clients.remove(response);
      if (sessionId != null && sessionId.isNotEmpty) {
        _clientSessions.detach(sessionId, response);
      }
    }
  }

  /// Склеивает журнал и карточки в один поток для SSE.
  Stream<Object> _allEvents() {
    final controller = StreamController<Object>();
    // Object, а не AgentApi: статический тип не знает о необязательном
    // интерфейсе, который реализует локальный адаптер.
    final Object backend = _backend;
    final subscriptions = <StreamSubscription<dynamic>>[
      _backend.events.listen(controller.add),
      _backend.approvals.listen(controller.add),
      _backend.questions.listen(controller.add),
      _backend.editChanges.listen(controller.add),
      if (backend is InteractionEventsApi)
        backend.resolutions.listen(controller.add),
      if (backend is AttentionApi)
        backend.attentionChanges.listen(controller.add),
      if (backend is AttentionSnoozeApi)
        backend.attentionDue
            .map<_AttentionDue>(_AttentionDue.new)
            .listen(controller.add),
      if (backend is AttentionPauseApi)
        backend.pauseDigestDue
            .map<_NotificationDigestDue>(_NotificationDigestDue.new)
            .listen(controller.add),
      _stateEvents.stream.listen(controller.add),
      if (settingsApi case final api?) ...[
        api.modelRuntime.watchRuntime().listen(controller.add),
        api.localModels.watch().listen(controller.add),
      ],
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

  /// Необязательное строковое поле: пустая строка считается отсутствующей.
  static String? _optionalString(Map<String, dynamic> body, String key) {
    final value = body[key];
    if (value == null) return null;
    if (value is! String) {
      throw AgentApiException(
        HttpStatus.badRequest,
        'bad_field',
        'expected string field "$key"',
      );
    }
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
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
    Duration? retryAfter,
  }) {
    if (retryAfter != null) {
      response.headers.set(
        HttpHeaders.retryAfterHeader,
        '${retryAfterSeconds(retryAfter)}',
      );
    }
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
    revision: json['revision'] is num ? (json['revision'] as num).toInt() : 0,
    createdAt: _date(json['createdAt']) ?? now,
    updatedAt: _date(json['updatedAt']) ?? now,
  );
}

Map<String, Object?> _memoryJson(ProjectMemory memory) => {
  'projectId': memory.projectId,
  'summary': memory.summary,
  'updatedAt': memory.updatedAt.toUtc().toIso8601String(),
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
    revision: json['revision'] is num ? (json['revision'] as num).toInt() : 0,
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
  'systemLabel': host.systemLabel,
  'defaultWorkspace': host.defaultWorkspace,
  'shellOverride': host.shellOverride,
  'notes': host.notes,
  'connectTimeoutSeconds': host.connectTimeoutSeconds,
  'lastCheckAt': host.lastCheckAt?.toUtc().toIso8601String(),
  'lastLatencyMs': host.lastLatencyMs,
  'lastCheckError': host.lastCheckError,
  'revision': host.revision,
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
  'revision': project.revision,
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
        'reasoning': entry.value.reasoning?.toJson(),
      },
  },
  'syncedAt': state.syncedAt?.toUtc().toIso8601String(),
  'loading': state.loading,
  'error': state.error,
  'providers': [for (final item in state.providers) _descriptorJson(item)],
  'providerStatuses': {
    for (final entry in state.providerStatuses.entries)
      entry.key: _providerStatusJson(entry.value),
  },
};

/// Дескриптор провайдера в JSON-ответе.
Map<String, Object?> _descriptorJson(LlmProviderDescriptor descriptor) => {
  'id': descriptor.id,
  'label': descriptor.label,
  'modelPrefix': descriptor.modelPrefix,
  'defaultBaseUrl': descriptor.defaultBaseUrl,
  'requiresApiKey': descriptor.requiresApiKey,
  'supportsApiKey': descriptor.supportsApiKey,
  'supportsBaseUrl': descriptor.supportsBaseUrl,
  'supportsEnabledToggle': descriptor.supportsEnabledToggle,
  'supportsKeyInfo': descriptor.supportsKeyInfo,
  'apiKeyExample': descriptor.apiKeyExample,
};

/// Статус провайдера в JSON-ответе. Ключ не передаётся: только признак и маска.
Map<String, Object?> _providerStatusJson(LlmProviderStatus status) => {
  'id': status.id,
  'enabled': status.enabled,
  'baseUrl': status.baseUrl,
  'apiKeySet': status.apiKeySet,
  'apiKeyTail': status.apiKeyTail,
  'available': status.available,
  'modelCount': status.modelCount,
  'error': status.error,
  'checkedAt': status.checkedAt?.toUtc().toIso8601String(),
  'keyInfo': status.keyInfo == null ? null : _keyInfoJson(status.keyInfo!),
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
  'reasoning': model.reasoning?.toJson(),
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

List<MentionRef> _mentions(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final item in raw)
      if (item is Map) MentionRef.fromJson(Map<String, dynamic>.from(item)),
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
    reasoning: ReasoningPreference.parse(
      json['reasoning'] as String?,
      fallback: ReasoningPreference.inherit,
    ),
    policyMode: PolicyMode.values.byName('${json['policyMode'] ?? 'ask'}'),
    workspace: json['workspace'] as String?,
    lastPromptTokens: json['lastPromptTokens'] as int?,
    lastCompletionTokens: json['lastCompletionTokens'] as int?,
    contextLength: json['contextLength'] as int?,
    lastReadSeq: json['lastReadSeq'] is num
        ? (json['lastReadSeq'] as num).toInt()
        : 0,
    readRevision: json['readRevision'] is num
        ? (json['readRevision'] as num).toInt()
        : 0,
    lastMessageSeq: json['lastMessageSeq'] is num
        ? (json['lastMessageSeq'] as num).toInt()
        : 0,
    unreadCount: json['unreadCount'] is num
        ? (json['unreadCount'] as num).toInt()
        : 0,
    createdAt: _date(json['createdAt']) ?? now,
    updatedAt: _date(json['updatedAt']) ?? now,
  );
}

DateTime? _date(Object? value) => value is String && value.isNotEmpty
    ? DateTime.tryParse(value)?.toUtc()
    : null;

Map<String, Object?> _searchHitJson(SearchHit hit) => {
  'kind': hit.kind.name,
  'title': hit.title,
  'score': hit.score,
  'chatId': hit.chatId,
  'chatTitle': hit.chatTitle,
  'projectId': hit.projectId,
  'messageId': hit.messageId,
  'seq': hit.seq,
  'snippet': hit.snippet,
};

/// Снимок входящих. Карточки сериализуются теми же помощниками, что и
/// события `approval`/`question`/`editFileChanges`: форма одна, чтобы окно
/// не разбирало один и тот же объект двумя способами.
Map<String, Object?> _attentionJson(AttentionSnapshot snapshot) => {
  'revision': snapshot.revision,
  'items': [
    for (final item in snapshot.items)
      {
        'chatId': item.chatId,
        'hostId': item.hostId,
        'projectId': item.projectId,
        'title': item.title,
        'reasons': [for (final reason in item.reasons) reason.name],
        'approvals': [
          for (final request in item.approvals) _approvalJson(request),
        ],
        'questions': [
          for (final question in item.questions) _questionJson(question),
        ],
        'editFileChanges': [
          for (final request in item.editFileChanges) _editJson(request),
        ],
        'unreadCount': item.unreadCount,
        'lastReadSeq': item.lastReadSeq,
        'lastMessageSeq': item.lastMessageSeq,
        'running': item.running,
        'turnAt': item.turnAt?.toUtc().toIso8601String(),
        'updatedAt': item.updatedAt.toUtc().toIso8601String(),
      },
  ],
  // Общая пауза уведомлений. Поле присутствует всегда, даже с null: по нему
  // новый клиент отличает сервер с поддержкой паузы от старого.
  'pause': snapshot.pause == null
      ? null
      : {
          'until': snapshot.pause!.until.toUtc().toIso8601String(),
          'reason': snapshot.pause!.reason.name,
          'revision': snapshot.pause!.revision,
        },
  // Отложенные чаты в `items` отсутствуют, но окно должно показать срок и
  // предложить вернуть чат раньше. Один снимок — один момент времени, поэтому
  // срок не расходится между устройствами.
  'snoozed': [
    for (final snooze in snapshot.snoozed)
      {
        'chatId': snooze.chatId,
        'until': snooze.until.toUtc().toIso8601String(),
        'revision': snooze.revision,
      },
  ],
};

/// Сроки напоминаний, которые только что наступили.
///
/// Отдельно от `chatStatusChanged`: снимок уже вернул чат во входящие, а это
/// событие позволяет окну показать системное напоминание и объяснить, почему
/// чат снова здесь. Необязательно для старых клиентов: они увидят только
/// возвращённый чат.
Map<String, Object?> _attentionDueJson(String chatId) => {'chatId': chatId};

/// Дайджест «пока вас не было».
///
/// Итоговые счётчики дублируют суммы по `items`: их может использовать
/// клиент, который не разбирает разбивку по чатам. Текущий клиент считает
/// итоги по `items`, чтобы раскрытый список и сводка совпадали.
Map<String, Object?> _attentionDigestJson(AttentionDigest digest) => {
  'newMessages': digest.newMessages,
  'finishedTurns': digest.finishedTurns,
  'approvals': digest.approvals,
  'questions': digest.questions,
  'editFileChanges': digest.editFileChanges,
  'problems': digest.problems,
  'items': [
    for (final item in digest.items)
      {
        'chatId': item.chatId,
        'hostId': item.hostId,
        'projectId': item.projectId,
        'title': item.title,
        'unreadMessages': item.unreadMessages,
        'finishedTurns': item.finishedTurns,
        'approvals': item.approvals,
        'questions': item.questions,
        'editFileChanges': item.editFileChanges,
        'problems': item.problems,
      },
  ],
};

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
  'reasoning': chat.reasoning.name,
  'policyMode': chat.policyMode.name,
  'workspace': chat.workspace,
  'lastPromptTokens': chat.lastPromptTokens,
  'lastCompletionTokens': chat.lastCompletionTokens,
  'contextLength': chat.contextLength,
  'draft': _draftJson(chat.draft),
  'messageEdits': encodeMessageEdits(chat.messageEdits),
  'draftRevision': chat.draftRevision,
  'messageEditsRevision': chat.messageEditsRevision,
  'revision': chat.revision,
  'lastReadSeq': chat.lastReadSeq,
  'readRevision': chat.readRevision,
  'lastMessageSeq': chat.lastMessageSeq,
  'unreadCount': chat.unreadCount,
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
  'mentions': [for (final mention in draft.mentions) mention.toJson()],
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
  'mentions': [for (final mention in message.mentions) mention.toJson()],
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
  'resultError': run.resultError,
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

Map<String, Object?> _turnSnapshotJson(TurnSnapshot snapshot) => {
  'text': snapshot.text,
  'reasoning': snapshot.reasoning,
  'isRunning': snapshot.isRunning,
};

Map<String, Object?> _queueJson(QueuedPrompt item) => {
  'id': item.id,
  'text': item.text,
  'isEvent': item.isEvent,
  'note': item.note,
  'attachments': [
    for (final attachment in item.attachments)
      {
        'name': attachment.name,
        'mode': attachment.mode.name,
        'mimeType': attachment.mimeType,
        'sizeBytes': attachment.sizeBytes,
      },
  ],
  'mentions': [for (final mention in item.mentions) mention.toJson()],
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
  'scheduledTasks': request.scheduledTasks,
};

bool _matchesChat(Object event, String? chatId) {
  // Runtime, файлы моделей, снимок входящих и дайджест после паузы —
  // глобальное состояние, а не событие конкретного чата.
  if (event is ModelRuntimeState ||
      event is LocalModelsState ||
      event is AttentionSnapshot ||
      event is _ClientSessionsChanged ||
      event is _NotificationDigestDue) {
    return true;
  }
  final eventChatId = _eventChatId(event);
  return chatId == null || eventChatId == chatId;
}

/// Тяжёлые события открытого чата: их не нужно рассылать во все окна.
///
/// Карточки (`approval`, `question`, `editFileChanges`), завершение хода,
/// удаление чата и `stateChanged` остаются глобальными: они нужны бейджам,
/// уведомлениям и закрытию экрана даже там, где чат не открыт.
bool _isHeavyChatEvent(Object event) =>
    event is AgentTextDelta ||
    event is AgentReasoningDelta ||
    event is AgentMessageAdded ||
    event is AgentTurnSnapshot ||
    event is AgentRunChanged ||
    event is AgentUsageUpdated ||
    event is AgentQueueChanged;

String? _eventChatId(Object event) => switch (event) {
  AgentEvent value => value.chatId,
  ApprovalRequest value => value.chatId,
  UserQuestion value => value.chatId,
  EditFileChangesRequest value => value.chatId,
  InteractionResolution value => value.chatId,
  _ChatChanged value => value.chatId,
  _ChatDeleted value => value.chatId,
  _ChatReadChanged value => value.chatId,
  _DraftChanged value => value.chatId,
  _AttentionDue value => value.chatId,
  _ => null,
};

(String, Map<String, Object?>) _event(
  Object event, {
  String? currentSessionFingerprint,
}) => switch (event) {
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
  AgentTurnSnapshot value => (
    'turnSnapshot',
    {
      'chatId': value.chatId,
      'text': value.text,
      'reasoning': value.reasoning,
      'isRunning': value.isRunning,
    },
  ),
  AgentRunChanged value => (
    'runChanged',
    {'chatId': value.chatId, 'run': _runJson(value.run)},
  ),
  AgentQueueChanged value => (
    'queueChanged',
    {
      'chatId': value.chatId,
      'size': value.size,
      'queueRevision': value.revision,
      'items': [for (final item in value.queue) _queueJson(item)],
    },
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
      'estimated': value.estimated,
      'contextWindowKnown': value.contextWindowKnown,
      'dailyCostUsd': value.dailyCostUsd,
      'dailyBudgetUsd': value.dailyBudgetUsd,
    },
  ),
  AgentStateChanged value => ('stateChanged', {'chatId': value.chatId}),
  AgentChatDeleted value => ('chatDeleted', {'chatId': value.chatId}),
  ApprovalRequest value => ('approval', _approvalJson(value)),
  UserQuestion value => ('question', _questionJson(value)),
  EditFileChangesRequest value => ('editFileChanges', _editJson(value)),
  ApprovalResolved value => (
    'approvalResolved',
    {'chatId': value.chatId, 'requestId': value.requestId},
  ),
  QuestionResolved value => (
    'questionResolved',
    {'chatId': value.chatId, 'questionId': value.questionId},
  ),
  EditFileChangesResolved value => (
    'editFileChangesResolved',
    {'chatId': value.chatId, 'requestId': value.requestId},
  ),
  ModelRuntimeState value => ('modelRuntime', {'runtime': value.toJson()}),
  LocalModelsState value => ('localModels', value.toJson()),
  _ChatChanged value => ('chatChanged', {'chatId': value.chatId}),
  _ChatDeleted value => ('chatDeleted', {'chatId': value.chatId}),
  _ChatReadChanged value => (
    'chatReadChanged',
    {
      'chatId': value.chatId,
      'lastReadSeq': value.lastReadSeq,
      'lastMessageSeq': value.lastMessageSeq,
      'unreadCount': value.unreadCount,
      'readRevision': value.readRevision,
    },
  ),
  _ClientSessionsChanged value => (
    'clientSessionsChanged',
    {
      'currentSessionId': currentSessionFingerprint,
      'presenceRevision': value.revision,
      'sessions': [
        for (final session in value.sessions)
          {...session, 'current': session['id'] == currentSessionFingerprint},
      ],
    },
  ),
  AttentionSnapshot value => ('chatStatusChanged', _attentionJson(value)),
  _AttentionDue value => ('attentionDue', _attentionDueJson(value.chatId)),
  _NotificationDigestDue value => (
    'notificationDigestDue',
    _attentionDigestJson(value.digest),
  ),
  _StateChanged value => ('stateAreaChanged', {'area': value.area}),
  _DraftChanged value => (
    'draftChanged',
    {'chatId': value.chatId, 'revision': value.revision},
  ),
  _ => ('unknown', {'type': event.runtimeType.toString()}),
};

final class _ChatChanged {
  const _ChatChanged(this.chatId);

  final String chatId;
}

/// Чат удалён. Отдельный тип, а не признак в `_ChatChanged`: клиент не должен
/// перечитывать запись, которой уже нет, и показывать бесконечную загрузку.
final class _ChatDeleted {
  const _ChatDeleted(this.chatId);

  final String chatId;
}

/// Курсор прочтения сдвинулся. Событие несёт готовый счётчик, чтобы окна
/// могли обновить бейдж, не дожидаясь перечитывания списка.
final class _ChatReadChanged {
  const _ChatReadChanged(
    this.chatId, {
    required this.lastReadSeq,
    required this.lastMessageSeq,
    required this.unreadCount,
    required this.readRevision,
  });

  final String chatId;
  final int lastReadSeq;
  final int lastMessageSeq;
  final int unreadCount;
  final int readRevision;
}

/// Снимок присутствия вместе с событием: окнам не нужен отдельный GET.
///
/// `current` выставляется при отправке конкретному соединению, потому что
/// одно и то же событие получают все клиенты, а «текущая» сессия у каждого
/// своя.
final class _ClientSessionsChanged {
  const _ClientSessionsChanged(this.sessions, this.revision);

  final List<Map<String, Object?>> sessions;
  final int revision;
}

final class _StateChanged {
  const _StateChanged(this.area);

  final String area;
}

final class _DraftChanged {
  const _DraftChanged(this.chatId, this.revision);

  final String chatId;
  final int revision;
}

/// Наступил срок «напомнить позже». Отдельный тип, потому что поток сервиса
/// внимания отдаёт только id чата, а SSE нужно и имя события, и фильтр по
/// открытому чату.
final class _AttentionDue {
  const _AttentionDue(this.chatId);

  final String chatId;
}

/// Дайджест после окончания общей паузы уведомлений.
///
/// Отдельный тип, а не часть снимка входящих: снимок уже показывает снятую
/// паузу, а это событие объясняет, что накопилось, и позволяет показать одно
/// уведомление вместо пачки запоздавших.
final class _NotificationDigestDue {
  const _NotificationDigestDue(this.digest);

  final AttentionDigest digest;
}

/// Накопленная дельта ответа до ближайшего flush.
final class _PendingDelta {
  _PendingDelta(this.event, this.chatId, this.reset, this.text);

  /// Имя SSE-события: `textDelta` или `reasoningDelta`.
  final String event;
  final String chatId;
  final bool reset;
  final StringBuffer text;
}

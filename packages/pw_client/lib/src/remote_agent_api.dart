import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:plugin_api/plugin_api.dart' as plugins;
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/agent_settings_api.dart';
import 'package:pw_agent/agent/api/attention_api.dart';
import 'package:pw_agent/agent/api/attention_digest_api.dart';
import 'package:pw_agent/agent/api/attention_pause_api.dart';
import 'package:pw_agent/agent/api/attention_snooze_api.dart';
import 'package:pw_agent/agent/api/chat_api.dart';
import 'package:pw_agent/agent/api/client_session_api.dart';
import 'package:pw_agent/agent/api/data_api.dart';
import 'package:pw_agent/agent/api/hosts_api.dart';
import 'package:pw_agent/agent/api/mcp_api.dart';
import 'package:pw_agent/agent/api/plugin_api.dart';
import 'package:pw_agent/agent/api/projects_api.dart';
import 'package:pw_agent/agent/api/push_api.dart';
import 'package:pw_agent/agent/api/security_audit_api.dart';
import 'package:pw_agent/agent/api/state_events_api.dart';
import 'package:pw_agent/agent/domain/attention_digest.dart';
import 'package:pw_agent/agent/domain/chat_attention.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/chat_snooze.dart';
import 'package:pw_agent/agent/domain/notification_pause.dart';
import 'package:pw_agent/agent/domain/project.dart';
import 'package:pw_agent/agent/domain/search.dart';
import 'package:pw_agent/agent/domain/steps_display.dart';
import 'package:pw_agent/agent/domain/workspace_entry.dart';
import 'package:pw_agent/agent/exec/active_exec_registry.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/agent/loop/prompt_queue.dart';
import 'package:pw_agent/agent/mcp/mcp_types.dart';
import 'package:pw_agent/agent/policy/security_profile.dart';
import 'package:pw_agent/agent/state/shared_state.dart';
import 'package:pw_agent/agent/turn/turn_file_kind.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/domain/chat_usage.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/domain/mcp_server.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/core/security/security_audit.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/local_models.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';
import 'package:pw_agent/providers/ai/model_runtime.dart';
import 'package:pw_client/src/client_session.dart';
import 'package:uuid/uuid.dart';

/// [AgentApi] поверх HTTP/SSE.
///
/// Используется для удалённых профилей. Локальный профиль работает через
/// `LocalAgentApi` без транспорта.
class RemoteAgentApi
    implements
        AgentApi,
        ChatApi,
        DataApi,
        HostsApi,
        ProjectsApi,
        AgentSettingsApi,
        SettingsChangeSource,
        ChatReconnectApi,
        McpApi,
        PluginApi,
        SecurityAuditApi,
        PushApi,
        InteractionEventsApi,
        StateEventsApi,
        ClientSessionApi,
        AttentionApi,
        AttentionDigestApi,
        AttentionSnoozeApi,
        AttentionPauseApi {
  RemoteAgentApi({
    required this.baseUri,
    required this.token,
    http.Client? client,
    this.clientHeaders = const {},
    this.timeout = const Duration(seconds: 30),
    this.reconnectBaseDelay = const Duration(seconds: 3),
    this.reconnectMaxDelay = const Duration(seconds: 60),
    this.reconnectJitter = 0.2,
    ClientSessionStore? sessionStore,
    ClientSessionChannel? sessionChannel,
    this.sessionKey = 'default',
  }) : _client = client ?? http.Client(),
       _sessionStore = sessionStore ?? MemoryClientSessionStore(),
       _sessionChannel = sessionChannel ?? const NoopClientSessionChannel() {
    assert(
      reconnectBaseDelay > Duration.zero,
      'reconnectBaseDelay must be positive',
    );
    assert(
      reconnectMaxDelay >= reconnectBaseDelay,
      'reconnectMaxDelay must not be shorter than reconnectBaseDelay',
    );
    assert(
      reconnectJitter >= 0 && reconnectJitter <= 1,
      'reconnectJitter must be between 0 and 1',
    );
    _reconnectDelay = reconnectBaseDelay;
  }

  /// Корень сервера, например `http://127.0.0.1:7787`.
  final Uri baseUri;
  final String token;

  /// Заголовки с информацией о клиенте: приложение, версия, сборка, платформа.
  final Map<String, String> clientHeaders;
  final Duration timeout;

  /// Начальная и максимальная пауза перед повторным открытием SSE.
  ///
  /// Параметры нужны тестам и профилям с медленной сетью: боевые значения
  /// не должны превращаться в бесконечный поток запросов к недоступному
  /// серверу.
  final Duration reconnectBaseDelay;
  final Duration reconnectMaxDelay;

  /// Доля случайной добавки к паузе, чтобы клиенты не переподключались
  /// одновременно.
  final double reconnectJitter;

  final http.Client _client;
  final _random = Random();

  /// Ключ профиля в [ClientSessionStore]. По нему один профиль не путает
  /// свою сессию с сессией другого сервера.
  final String sessionKey;
  final ClientSessionStore _sessionStore;
  final ClientSessionChannel _sessionChannel;

  /// Секрет продолжения сессии лежит рядом с id, но под отдельным ключом.
  /// Так существующие хранилища со старым значением id читаются как раньше,
  /// а список сессий и соседние окна секрета не видят.
  String get _resumeSecretKey => '$sessionKey.resume';

  String? _sessionId;
  String? _instanceId;
  Future<void>? _sessionInFlight;
  Timer? _heartbeatTimer;
  Duration _heartbeatInterval = const Duration(seconds: 20);
  bool _focused = false;
  String? _activeChatId;

  /// Видимость приложения из последнего обновления. `null` — старый клиент
  /// без поля: сервер тогда довольствуется одним `focused`.
  ClientVisibility? _visibility;

  /// Открытый чат находится у нижней границы ленты. Для старого сервера поле
  /// просто игнорируется.
  bool _activeChatAtEnd = true;

  /// Время последнего взаимодействия. Уходит на сервер как возраст, чтобы
  /// расхождение часов не решало, какое устройство активно.
  DateTime? _lastInteractionAt;

  /// Когда взаимодействие в последний раз отправлялось отдельным heartbeat.
  /// Ограничивает сеть при непрерывной прокрутке или наборе текста.
  DateTime? _lastInteractionPublishedAt;

  static const _interactionPublishInterval = Duration(seconds: 15);

  /// Монотонный номер состояния присутствия.
  ///
  /// Назначается каждой отправке и всегда растёт. Рукопожатие может вернуть
  /// ревизию переиспользованной сессии: клиент берёт максимум из локальной и
  /// серверной, поэтому reload не начинает нумерацию заново. Сервер применяет
  /// запрос, лишь если ревизия больше последней принятой: иначе периодический
  /// heartbeat, ушедший раньше, мог бы прийти позже свежего запроса и вернуть
  /// presence назад.
  int _presenceRevision = 0;

  /// Очередь отправки присутствия: одновременно выполняется не больше одного
  /// запроса, а накопленные изменения схлопываются в последнее состояние.
  Future<void>? _presenceInFlight;
  bool _presenceDirty = false;

  /// Чаты, тяжёлые события которых нужны открытым экранам этого клиента.
  ///
  /// Счётчик, а не множество: один чат может слушать несколько подписчиков,
  /// и событие перестаёт быть нужным только после последнего. Сервер отдаёт
  /// дельты, очередь и сообщения лишь для этих чатов, а глобальный поток
  /// остаётся лёгким.
  final _chatSubscriptions = <String, int>{};
  Future<void>? _subscriptionsInFlight;
  bool _subscriptionsDirty = false;

  static const _clientSessionHeader = 'x-client-session';

  /// Сессия текущего клиента. null — рукопожатие ещё не выполнено.
  String? get sessionId => _sessionId;

  /// Идентификатор запущенного сервера из последнего `/health` или handshake.
  String? get instanceId => _instanceId;

  /// Обновляет присутствие и сразу отправляет его вместе со списком экранов.
  @override
  void setPresence({
    bool? focused,
    String? activeChatId,
    bool clearActiveChat = false,
    ClientVisibility? visibility,
    bool? activeChatAtEnd,
  }) {
    if (visibility != null) {
      _visibility = visibility;
      // Видимость и фокус описывают одно состояние. Держим `focused` в
      // согласии, чтобы старый сервер без `visibility` вёл себя как раньше.
      _focused = visibility == ClientVisibility.foreground;
    } else if (focused != null) {
      _focused = focused;
      // Сервер предпочитает `visibility`, поэтому обновление только `focused`
      // потерялось бы, если видимость уже отправлялась. Синхронизируем поле,
      // не затирая неизвестное клиенту `locked`.
      if (_visibility != null && _visibility != ClientVisibility.locked) {
        _visibility = focused
            ? ClientVisibility.foreground
            : ClientVisibility.background;
      }
    }
    if (activeChatAtEnd != null) _activeChatAtEnd = activeChatAtEnd;
    if (clearActiveChat) {
      _activeChatId = null;
    } else if (activeChatId != null) {
      _activeChatId = activeChatId;
    }
    if (!_disposed) unawaited(_publishPresence());
  }

  @override
  void noteInteraction([DateTime? at]) {
    if (_disposed) return;
    final now = at ?? DateTime.now();
    final previous = _lastInteractionAt;
    _lastInteractionAt = now;
    // До рукопожатия отдельный запрос не нужен: первый heartbeat отправит
    // отметку вместе с остальным присутствием.
    if (_sessionId == null) return;
    // Первое взаимодействие после простоя публикуем сразу: иначе ушедший в
    // фон компьютер ещё несколько секунд считался бы активным. При
    // непрерывном вводе ограничиваемся редкими heartbeat.
    final published = _lastInteractionPublishedAt;
    if (published != null &&
        now.difference(published) < _interactionPublishInterval) {
      return;
    }
    if (previous != null &&
        now.difference(previous) < _interactionPublishInterval) {
      return;
    }
    _lastInteractionPublishedAt = now;
    unawaited(_sendHeartbeat());
  }

  /// Отправляет актуальное присутствие и сразу перечитывает список экранов.
  ///
  /// После долгой фоновой вкладки heartbeat мог не дойти, и сессия успела
  /// истечь. Успешный heartbeat после возврата фокуса восстанавливает её, а
  /// повторное чтение снимает устаревший список, в котором текущего экрана нет.
  Future<void> _publishPresence() async {
    await _sendHeartbeat();
    if (!_disposed) await _refreshClientSessionsQuietly();
  }

  /// Ставит присутствие в очередь и отправляет самое свежее состояние.
  ///
  /// Параллельные вызовы не создают несколько запросов: если отправка уже
  /// идёт, новое состояние лишь помечается грязным, и текущий цикл отправит
  /// его следующим. Так порядок ревизий совпадает с порядком запросов, даже
  /// когда периодический heartbeat совпал с ручным изменением.
  Future<void> _flushPresence() {
    _presenceDirty = true;
    final inFlight = _presenceInFlight;
    if (inFlight != null) return inFlight;
    final done = Completer<void>();
    _presenceInFlight = done.future;
    unawaited(_drainPresence(done));
    return done.future;
  }

  Future<void> _drainPresence(Completer<void> done) async {
    try {
      while (_presenceDirty && !_disposed) {
        _presenceDirty = false;
        await _sendPresence();
      }
    } finally {
      _presenceInFlight = null;
      if (!done.isCompleted) done.complete();
    }
  }

  /// Текущая пауза перед следующей попыткой; после успеха сбрасывается.
  late Duration _reconnectDelay;

  final _statusChanges = StreamController<AgentStatus>.broadcast();
  var _status = AgentStatus.connecting;
  final _running = <String>{};
  final _waiting = <String>{};
  final _approvalChats = <String, String>{};
  final _questionChats = <String, String>{};
  final _editChats = <String, String>{};
  final _queues = <String, List<QueuedPrompt>>{};
  final _queueRevisions = <String, int>{};
  final _turnSnapshots = <String, TurnSnapshot>{};
  Map<String, dynamic>? _globalSettings;
  Future<void>? _settingsLoading;
  final _usageByChat = <String, Map<String, dynamic>>{};
  final _projectsByChat = <String, Project?>{};
  ModelCatalogState? _catalog;
  ModelRuntimeState? _runtime;
  LocalModelsState? _localModels;
  final _approvalsById = <String, ApprovalRequest>{};
  final _questionsById = <String, UserQuestion>{};
  final _editsById = <String, EditFileChangesRequest>{};
  final _events = StreamController<AgentEvent>.broadcast();
  final _approvals = StreamController<ApprovalRequest>.broadcast();
  final _questions = StreamController<UserQuestion>.broadcast();
  final _editChanges = StreamController<EditFileChangesRequest>.broadcast();
  final _resolutions = StreamController<InteractionResolution>.broadcast();
  final _clientSessionChanges =
      StreamController<List<ClientSessionView>>.broadcast();
  final _attentionChanges = StreamController<AttentionSnapshot>.broadcast();
  AttentionSnapshot _attentionSnapshot = AttentionSnapshot.empty;

  /// Поддерживает ли подключённый сервер отложенные напоминания.
  ///
  /// Старый демон не присылает в снимке входящих поле `snoozed`, поэтому до
  /// первого снимка действие «Напомнить позже» скрыто. Новый сервер присылает
  /// поле всегда, даже с пустым списком.
  bool _supportsSnooze = false;

  /// Сроки напоминаний, о которых сообщил сервер.
  ///
  /// Отдельный поток от снимка: возвращение чата во входящие уже видно по
  /// `chatStatusChanged`, а это событие объясняет, почему чат вернулся, и
  /// позволяет показать системное напоминание.
  final _attentionDue = StreamController<String>.broadcast();
  final _pauseDigestDue = StreamController<AttentionDigest>.broadcast();

  /// Поддерживает ли подключённый сервер общую паузу уведомлений.
  ///
  /// Признак — поле `pause` в снимке входящих: новый сервер присылает его
  /// даже со значением null, старый не присылает вовсе.
  bool _supportsPause = false;

  final _reconnects = StreamController<void>.broadcast();
  bool _reconnectPending = false;

  /// SSE-поток оборвался и ещё не восстановлен.
  ///
  /// Пока флаг поднят, успешный REST-ответ не переводит статус в
  /// [AgentStatus.online]: события всё ещё не доставляются, и UI не должен
  /// показывать «на связи» до нового потока. Снимается только при получении
  /// очередного SSE-ответа со статусом 200.
  bool _streamBroken = false;

  /// Номер последнего запроса списка сессий. Ответы старых запросов не должны
  /// перезаписывать более новый снимок.
  int _clientSessionsRefreshSequence = 0;

  /// Последняя применённая ревизия снимка присутствия.
  ///
  /// Событие `clientSessionsChanged` несёт снимок целиком, но HTTP-ответ
  /// мог быть отправлен раньше события. Сравнение ревизий не даёт старому
  /// ответу перезаписать свежий снимок и наоборот.
  int _clientSessionsRevision = -1;

  /// Последний принятый снимок списка сессий.
  ///
  /// Хранится отдельно, потому что отклонённый устаревший ответ нельзя отдавать
  /// вызывающему: иначе вызывающий применил бы его к своему состоянию в обход
  /// защиты от гонки.
  List<ClientSessionView> _clientSessions = const [];
  final _catalogChanges = StreamController<ModelCatalogState>.broadcast();
  final _runtimeChanges = StreamController<ModelRuntimeState>.broadcast();
  final _localModelsChanges = StreamController<LocalModelsState>.broadcast();
  final _pinnedChanges = StreamController<List<String>>.broadcast();
  final _settingsChanges = StreamController<void>.broadcast();
  final _mcpStateChanges = StreamController<McpServerState>.broadcast();
  final _stateChanges = StreamController<String>.broadcast();
  final _draftChanges = StreamController<String>.broadcast();

  /// Области, о которых уже сообщили, но ещё не отдали подписчикам.
  ///
  /// Всплеск `stateAreaChanged` или несколько сообщений подряд приходят
  /// почти одновременно. Склейка не даёт списку чатов перечитываться на
  /// каждое событие, а подписчикам — получать промежуточные снимки.
  final _pendingStateAreas = <String>{};
  Timer? _stateFlushTimer;
  McpSnapshot? _mcpSnapshot;

  static const _uuid = Uuid();

  var _eventsStarted = false;
  var _disposed = false;
  final _eventsReady = Completer<void>();

  @override
  AgentStatus get status => _status;

  @override
  Stream<AgentStatus> get statusChanges => _statusChanges.stream;

  @override
  Future<bool> checkConnection() async {
    try {
      final response = await _client
          .get(
            _url('/health'),
            headers: {...clientHeaders, 'x-request-id': _uuid.v4()},
          )
          .timeout(const Duration(seconds: 5));
      final online = response.statusCode == 200;
      if (online && response.body.isNotEmpty) {
        try {
          final body = jsonDecode(response.body);
          if (body is Map && body['instanceId'] is String) {
            _trackInstance(body['instanceId'] as String);
          }
        } on FormatException {
          // Health может быть от старого сервера без instanceId.
        }
      }
      _setStatus(
        online && !_streamBroken ? AgentStatus.online : AgentStatus.offline,
      );
      return online;
    } on Object {
      _setStatus(AgentStatus.offline);
      return false;
    }
  }

  @override
  Set<String> get runningChatIds => Set.unmodifiable(_running);

  @override
  Set<String> get waitingChatIds => Set.unmodifiable(_waiting);

  @override
  Future<AttentionSnapshot> attention() async {
    final json = await _get('/attention');
    // Наличие поля, а не пустота списка: старый сервер его не присылает вовсе.
    _supportsSnooze = json.containsKey('snoozed');
    _supportsPause = json.containsKey('pause');
    final snapshot = _attentionSnapshotFrom(json);
    _applyAttention(snapshot);
    return snapshot;
  }

  @override
  bool get supportsSnooze => _supportsSnooze;

  @override
  Stream<AttentionSnapshot> get attentionChanges => _attentionChanges.stream;

  @override
  Future<void> dismissAttention(String chatId) async {
    await _send('DELETE', '/attention/$chatId');
  }

  @override
  Future<AttentionDigest> attentionDigest() async {
    final json = await _get('/attention/digest');
    return _attentionDigestFrom(json);
  }

  @override
  Future<void> snoozeAttention(String chatId, DateTime until) async {
    try {
      await _send(
        'PUT',
        '/attention/$chatId/snooze',
        body: {'until': until.toUtc().toIso8601String()},
      );
      _supportsSnooze = true;
    } on AgentApiException catch (error) {
      // Сервер без маршрута: интерфейс должен убрать действие, а не повторять
      // заведомо неуспешный запрос.
      if (_isMissingSnoozeRoute(error)) _supportsSnooze = false;
      rethrow;
    }
  }

  @override
  Future<void> unsnoozeAttention(String chatId) async {
    try {
      await _send('DELETE', '/attention/$chatId/snooze');
      _supportsSnooze = true;
    } on AgentApiException catch (error) {
      if (_isMissingSnoozeRoute(error)) _supportsSnooze = false;
      rethrow;
    }
  }

  /// Ошибка означает, что подключённый сервер не знает маршрут напоминаний.
  ///
  /// `404 chat_not_found` сюда не входит: это ответ нового сервера на
  /// откладывание несуществующего чата, и он не должен скрывать действие.
  static bool _isMissingSnoozeRoute(AgentApiException error) =>
      error.code == 'not_supported' ||
      (error.status == 404 && error.code == 'not_found');

  @override
  Stream<String> get attentionDue => _attentionDue.stream;

  @override
  bool get supportsPause => _supportsPause;

  @override
  Future<void> pauseNotifications(
    DateTime until, {
    NotificationPauseReason reason = NotificationPauseReason.focus,
  }) async {
    try {
      await _send(
        'PUT',
        '/attention/pause',
        body: {'until': until.toUtc().toIso8601String(), 'reason': reason.name},
      );
      _supportsPause = true;
    } on AgentApiException catch (error) {
      if (_isMissingPauseRoute(error)) _supportsPause = false;
      rethrow;
    }
  }

  @override
  Future<void> resumeNotifications() async {
    try {
      await _send('DELETE', '/attention/pause');
      _supportsPause = true;
    } on AgentApiException catch (error) {
      if (_isMissingPauseRoute(error)) _supportsPause = false;
      rethrow;
    }
  }

  @override
  Stream<AttentionDigest> get pauseDigestDue => _pauseDigestDue.stream;

  /// Ошибка означает, что подключённый сервер не знает маршрут паузы.
  static bool _isMissingPauseRoute(AgentApiException error) =>
      error.code == 'not_supported' ||
      (error.status == 404 && error.code == 'not_found');

  /// Применяет снимок, только если он не старше уже показанного.
  ///
  /// Ответ `GET /attention` мог прийти после SSE-события: без проверки
  /// ревизии старый снимок вернул бы уже закрытую карточку.
  void _applyAttention(AttentionSnapshot snapshot) {
    if (snapshot.revision < _attentionSnapshot.revision) return;
    _attentionSnapshot = snapshot;
    if (!_attentionChanges.isClosed) _attentionChanges.add(snapshot);
  }

  @override
  Stream<AgentEvent> get events => _events.stream;

  /// Поток событий одного чата и подписка на его тяжёлые SSE-события.
  ///
  /// Поток широковещательный, как и у локальной сессии: несколько слушателей
  /// получают одни и те же события. Пока поток слушают, чат входит в набор
  /// подписок сервера: только для него приходят дельты ответа, полная очередь
  /// и сообщения. После последнего слушателя набор сжимается, и окно
  /// перестаёт получать чужой трафик.
  Stream<AgentEvent> _chatEvents(String chatId) {
    late StreamController<AgentEvent> controller;
    StreamSubscription<AgentEvent>? upstream;

    void subscribe() {
      _chatSubscriptions.update(
        chatId,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
      unawaited(_syncChatSubscriptions());
      upstream = _events.stream
          .where((event) => event.chatId == chatId)
          .listen(
            controller.add,
            onError: (Object error, StackTrace stack) =>
                controller.addError(error, stack),
            onDone: () => unawaited(controller.close()),
          );
    }

    void unsubscribe() {
      // Захватываем подписку до нового onListen: широковещательный поток
      // можно слушать повторно, и старый onCancel не должен отменить новый.
      final current = upstream;
      upstream = null;
      final remaining = (_chatSubscriptions[chatId] ?? 1) - 1;
      if (remaining <= 0) {
        _chatSubscriptions.remove(chatId);
      } else {
        _chatSubscriptions[chatId] = remaining;
      }
      unawaited(_syncChatSubscriptions());
      unawaited(current?.cancel());
    }

    controller = StreamController<AgentEvent>.broadcast(
      onListen: subscribe,
      onCancel: unsubscribe,
    );
    return controller.stream;
  }

  /// Отправляет серверу актуальный набор открытых чатов.
  ///
  /// Запросы сериализуются: если набор изменился во время отправки, уходит
  /// последнее состояние, а не накопленная очередь. Так сервер не получает
  /// промежуточный набор после свежего из-за перестановки сети.
  Future<void> _syncChatSubscriptions() {
    if (_disposed) return Future<void>.value();
    _subscriptionsDirty = true;
    final inFlight = _subscriptionsInFlight;
    if (inFlight != null) return inFlight;
    final done = Completer<void>();
    _subscriptionsInFlight = done.future;
    unawaited(_drainChatSubscriptions(done));
    return done.future;
  }

  /// Завершается, когда сервер получил актуальный набор открытых чатов.
  ///
  /// Обычно ждать не нужно: снимок чата читается после подписки. Метод нужен
  /// сценариям и тестам, где важно не потерять самое первое тяжёлое событие,
  /// пришедшее сразу после открытия потока.
  Future<void> syncChatSubscriptions() => _syncChatSubscriptions();

  Future<void> _drainChatSubscriptions(Completer<void> done) async {
    try {
      while (_subscriptionsDirty && !_disposed) {
        _subscriptionsDirty = false;
        final chatIds = _chatSubscriptions.keys.toList()..sort();
        try {
          await _send(
            'PUT',
            '/client/subscriptions',
            body: {'chatIds': chatIds},
          );
        } on Object {
          // Старый сервер не знает маршрут, а сеть может быть недоступна.
          // Следующее открытие чата или переподключение повторит попытку.
          break;
        }
      }
    } finally {
      _subscriptionsInFlight = null;
      if (!done.isCompleted) done.complete();
    }
  }

  @override
  Stream<ApprovalRequest> get approvals => _approvals.stream;

  @override
  Stream<UserQuestion> get questions => _questions.stream;

  @override
  Stream<EditFileChangesRequest> get editChanges => _editChanges.stream;

  @override
  Stream<InteractionResolution> get resolutions => _resolutions.stream;

  @override
  Stream<List<ClientSessionView>> get clientSessions =>
      _clientSessionChanges.stream;

  @override
  Stream<SharedResource> get sharedStateChanges =>
      _stateChanges.stream.expand((area) {
        // После обрыва перечитываем все ресурсы: часть событий могла не дойти.
        if (area == 'reconnect') return SharedResource.values;
        final resource = SharedResource.fromArea(area);
        return resource == null ? const <SharedResource>[] : [resource];
      });

  /// Поток оборвался или восстановился, либо сервер перезапустился.
  ///
  /// Подписчики перечитывают снимки в обоих случаях: после обрыва часть
  /// событий могла не дойти, а после восстановления нужен ещё один снимок,
  /// чтобы догнать то, что случилось до нового потока.
  @override
  Stream<void> get reconnects => _reconnects.stream;

  /// Изменения настроек, включая пришедшие из другого окна.
  @override
  Stream<void> get settingsChanges => _settingsChanges.stream;

  Future<void> _refreshClientSessionsQuietly() async {
    try {
      await refreshClientSessions();
    } on Object {
      // Следующее событие или открытие чата попробует снова.
    }
  }

  /// Читает список сессий.
  ///
  /// Снимок — это состояние на момент ответа. Если два запроса уйдут
  /// одновременно, более старый ответ может прийти позже и перезаписать
  /// свежий: один экран покажет трёх клиентов, другой двух. Поэтому ответ
  /// применяется, только если после его отправки не начался более новый запрос.
  ///
  /// Возвращается последний принятый снимок. Устаревший ответ не отдаётся
  /// вызывающему даже как результат: применять его к своему состоянию нельзя.
  /// Снимок с уже применённой ревизией тоже не публикуется в
  /// [clientSessions]: подписчик, который сам запросил обновление, иначе
  /// получал бы событие на каждый свой запрос и мог зациклиться.
  @override
  Future<List<ClientSessionView>> refreshClientSessions() async {
    final sequence = ++_clientSessionsRefreshSequence;
    final json = await _get('/client/sessions');
    final sessions = _clientSessionsFrom(json);
    if (sequence != _clientSessionsRefreshSequence) return _clientSessions;
    final revision = json['presenceRevision'];
    if (revision is num && revision.toInt() < _clientSessionsRevision) {
      return _clientSessions;
    }
    var announced = true;
    if (revision is num) {
      final value = revision.toInt();
      // Одинаковая ревизия — тот же снимок. Повторная отправка в поток
      // заставила бы подписчиков, которые сами же запросили обновление
      // (например, ProfileNoticeBridge), бесконечно его пересматривать.
      announced = value > _clientSessionsRevision;
      _clientSessionsRevision = value;
    }
    _clientSessions = sessions;
    if (announced && !_clientSessionChanges.isClosed) {
      _clientSessionChanges.add(sessions);
    }
    return sessions;
  }

  /// Закрывает другое подключение по fingerprint из списка экранов.
  ///
  /// Сырой `sessionId` клиенту неизвестен, поэтому маршрут принимает тот же
  /// короткий fingerprint, который отдаёт `GET /client/sessions`. Сервер
  /// отвечает `204` и для уже исчезнувшей сессии: устаревший список не должен
  /// превращать уборку в ошибку. Список перечитывается сразу, чтобы диалог
  /// обновился даже без живого SSE.
  @override
  Future<void> closeClientSession(String id) async {
    await _send('DELETE', '/client/sessions/${Uri.encodeComponent(id)}');
    await _refreshClientSessionsQuietly();
  }

  /// Применяет снимок присутствия из события, не делая отдельный запрос.
  ///
  /// Устаревший снимок отбрасывается по монотонной ревизии: событие и
  /// HTTP-ответ могут прийти в любом порядке.
  void _applyClientSessions(Map<String, dynamic> json) {
    final revision = json['presenceRevision'];
    if (revision is num) {
      final value = revision.toInt();
      if (value < _clientSessionsRevision) return;
      _clientSessionsRevision = value;
    }
    final sessions = _clientSessionsFrom(json);
    // Событие уже новее любого запроса, начатого до него. Увеличиваем номер,
    // чтобы запоздавший ответ не перезаписал этот снимок.
    _clientSessionsRefreshSequence++;
    _clientSessions = sessions;
    if (!_clientSessionChanges.isClosed) {
      _clientSessionChanges.add(sessions);
    }
  }

  @override
  late final ChatStore chatStore = _RemoteChatStore(this);

  @override
  late final SettingsStore settings = _RemoteSettings(this);

  @override
  late final ProjectStore projectStore = _RemoteProjectStore(this);

  @override
  late final ProjectsStore projects = _RemoteProjects(this);

  @override
  late final ModelStore models = _RemoteModels(this);

  @override
  ModelRuntimeSource get modelRuntime => models;

  @override
  late final LocalModelsSource localModels = _RemoteLocalModels(this);

  @override
  late final HostStore hostStore = _RemoteHosts(this);

  @override
  late final ExecStore registry = const _RemoteExec();

  @override
  late final InteractionsStore broker = _RemoteInteractions(this);

  @override
  ChatSessionApi session(String chatId) => _RemoteChatSession(this, chatId);

  @override
  Future<AppLimits> limits() async => const AppLimits();

  @override
  Chat draftChat({required String hostId, Host? host}) {
    final now = DateTime.now();
    final policyName = settings.cached(SettingsRepository.keyDefaultPolicy);
    return Chat(
      id: _uuid.v4(),
      hostId: hostId,
      workspace: host?.defaultWorkspace,
      title: '',
      createdAt: now,
      updatedAt: now,
      policyMode:
          PolicyMode.values.asNameMap()[policyName ?? ''] ?? PolicyMode.ask,
    );
  }

  /// Завершается после установки первого SSE-соединения.
  Future<void> get eventsReady => _eventsReady.future;

  /// Открывает SSE-подписку. Вызывает менеджер профилей, а не сам конструктор:
  /// клиент может быть создан для проверки соединения без живого потока.
  Future<void> startEvents() async {
    if (_eventsStarted || _disposed) return;
    _eventsStarted = true;
    _setStatus(AgentStatus.connecting);
    unawaited(_listen());
  }

  Future<void> dispose() async {
    _disposed = true;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _stateFlushTimer?.cancel();
    _stateFlushTimer = null;
    _pendingStateAreas.clear();
    _chatSubscriptions.clear();
    final session = _sessionId;
    if (session != null) {
      try {
        // Явное закрытие не обязательно: TTL всё равно уберёт сессию. Но
        // при штатном выходе не оставляем её висеть до минуты.
        await _sendRaw(
          'DELETE',
          '/client/session',
          session: session,
        ).timeout(const Duration(seconds: 2));
      } on Object {
        // Сеть уже недоступна — сессия истечёт по TTL.
      }
      _sessionId = null;
      // Соседний экземпляр того же профиля мог за время ожидания пройти
      // рукопожатие и записать свой id. Стираем только свой.
      if (_sessionStore.read(sessionKey) == session) {
        _sessionStore.delete(sessionKey);
        _sessionStore.delete(_resumeSecretKey);
      }
    }
    await _statusChanges.close();
    await _events.close();
    await _approvals.close();
    await _questions.close();
    await _editChanges.close();
    await _resolutions.close();
    await _clientSessionChanges.close();
    await _attentionChanges.close();
    await _attentionDue.close();
    await _pauseDigestDue.close();
    await _reconnects.close();
    await _catalogChanges.close();
    await _runtimeChanges.close();
    await _localModelsChanges.close();
    await _pinnedChanges.close();
    await _settingsChanges.close();
    await _mcpStateChanges.close();
    await _stateChanges.close();
    await _draftChanges.close();
    _client.close();
  }

  @override
  Future<void> saveHost(
    Host host, {
    String? secret,
    String? privateKeyPem,
    Map<String, String>? environment,
    int? expectedRevision,
  }) async {
    await _send(
      'PUT',
      '/hosts/${host.id}',
      body: {
        ..._hostBody(host),
        'secret': ?secret,
        'privateKeyPem': ?privateKeyPem,
        'environment': ?environment,
        'expectedRevision': ?expectedRevision,
      },
    );
  }

  @override
  Future<void> deleteHost(String id) async {
    await _send('DELETE', '/hosts/$id');
  }

  @override
  Future<void> testHost(Host host) async {
    await _send('POST', '/hosts/${host.id}/test', body: _hostBody(host));
  }

  @override
  Future<List<Host>> hosts() async {
    final json = await _get('/hosts');
    return [
      for (final item in (json['hosts'] as List? ?? const []))
        _host(Map<String, dynamic>.from(item as Map)),
    ];
  }

  @override
  Stream<List<Chat>> watchChats() =>
      _watchStateList(load: chats, relevant: (area) => area == 'chats');

  @override
  Stream<List<Host>> watchHosts() =>
      _watchStateList(load: hosts, relevant: (area) => area == 'hosts');

  @override
  Future<List<Chat>> chats() async {
    final json = await _get('/chats');
    final chats = <Chat>[];
    for (final item in (json['chats'] as List? ?? const [])) {
      final map = Map<String, dynamic>.from(item as Map);
      final chat = _chat(map);
      chats.add(chat);
      _trackChatState(chat.id, map);
    }
    return chats;
  }

  @override
  Future<Chat?> chat(String id) async {
    try {
      final json = await _get('/chats/$id');
      final map = Map<String, dynamic>.from(json['chat'] as Map);
      final chat = _chat(map);
      _trackChatState(chat.id, map);
      _syncCards(chat.id, json);
      await _loadGlobalSettings();
      await _loadChatState(chat.id);
      await _loadModels();
      return chat;
    } on AgentApiException catch (error) {
      if (error.status == 404) return null;
      rethrow;
    }
  }

  @override
  Future<Chat> createChat(String hostId) async {
    final json = await _send('POST', '/chats', body: {'hostId': hostId});
    final map = Map<String, dynamic>.from(json as Map);
    final chat = _chat(map);
    _trackChatState(chat.id, map);
    return chat;
  }

  @override
  @override
  Future<void> saveChat(Chat chat) async {
    await _send('PUT', '/chats/${chat.id}', body: _chatBody(chat));
  }

  @override
  Future<void> renameChat(String chatId, String title) =>
      updateChat(chatId, title: title);

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
    await _send(
      'PATCH',
      '/chats/$chatId',
      body: {
        'title': ?title,
        'model': ?model,
        'reasoning': ?reasoning?.name,
        'policyMode': ?policyMode?.name,
        'workspace': ?workspace,
        if (workspaceSpecified) 'workspaceSpecified': true,
      },
    );
  }

  @override
  Future<Chat> markChatRead(
    String chatId, {
    required int seq,
    int? expectedRevision,
  }) =>
      chatStore.markRead(chatId, seq: seq, expectedRevision: expectedRevision);

  @override
  Future<int> pendingScheduledTasks(
    String chatId, {
    String? untilMessageId,
  }) async {
    final suffix = untilMessageId == null
        ? ''
        : '?${Uri(queryParameters: {'untilMessageId': untilMessageId}).query}';
    final json = await _get('/chats/$chatId/scheduled-tasks$suffix');
    return (json['count'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<Chat?> forkChat(
    String chatId, {
    String? title,
    String? untilMessageId,
    bool copyPendingTasks = false,
  }) async {
    try {
      final json = await _send(
        'POST',
        '/chats/$chatId/forks',
        body: {
          'title': ?title,
          'untilMessageId': ?untilMessageId,
          if (copyPendingTasks) 'copyPendingTasks': true,
        },
      );
      final map = Map<String, dynamic>.from(json as Map);
      final chat = _chat(map);
      _trackChatState(chat.id, map);
      return chat;
    } on AgentApiException catch (error) {
      if (error.status == 404) return null;
      rethrow;
    }
  }

  @override
  Future<List<String>> deleteChat(String chatId) async {
    final json = await _send('DELETE', '/chats/$chatId');
    _running.remove(chatId);
    _waiting.remove(chatId);
    final ids = json is Map
        ? [
            for (final id in json['chatIds'] as List? ?? const [])
              if (id is String) id,
          ]
        : const <String>[];
    // Старый сервер отвечал 204 без тела: открытый экран всё равно нужно
    // закрыть, поэтому корневой id подставляем сами.
    return ids.isEmpty ? [chatId] : ids;
  }

  @override
  Future<List<ChatMessage>> messages(String chatId) async {
    final json = await _get('/chats/$chatId/messages');
    return [
      for (final item in (json['messages'] as List? ?? const []))
        _message(Map<String, dynamic>.from(item as Map)),
    ];
  }

  @override
  Future<List<ToolRun>> runs(String chatId) async {
    final json = await _get('/chats/$chatId/runs');
    return [
      for (final item in (json['runs'] as List? ?? const []))
        _run(Map<String, dynamic>.from(item as Map)),
    ];
  }

  @override
  Future<List<SearchHit>> search(SearchQuery query) async {
    final params = {
      'q': query.text,
      'scope': query.scope.name,
      'limit': '${query.limit}',
      if (query.projectId != null) 'projectId': query.projectId!,
      if (query.chatId != null) 'chatId': query.chatId!,
    };
    final suffix = Uri(queryParameters: params).query;
    final json = await _get('/search?$suffix');
    return [
      for (final item in (json['hits'] as List? ?? const []))
        if (item is Map) _searchHit(Map<String, dynamic>.from(item)),
    ];
  }

  @override
  Future<void> openChat(String chatId) async {
    await _send('PUT', '/chats/$chatId/presence');
    await _trySyncSession(chatId);
    await _loadGlobalSettings();
    await _loadChatState(chatId);
    await _loadModels();
  }

  Future<void> _loadGlobalSettings() {
    if (_globalSettings != null) return Future<void>.value();
    return _settingsLoading ??= _fetchGlobalSettings().whenComplete(
      () => _settingsLoading = null,
    );
  }

  Future<void> _fetchGlobalSettings() async {
    try {
      _globalSettings = await _get('/settings');
      if (!_settingsChanges.isClosed) _settingsChanges.add(null);
    } on AgentApiException {
      // Настройки не критичны для чтения чата.
    }
  }

  /// Перечитывает настройки после изменения в другом клиенте. Событие
  /// отдаётся подписчикам только после успешного ответа: иначе UI увидел бы
  /// null вместо прежнего значения при временной ошибке.
  Future<void> _refreshSettingsFromRemote() async {
    try {
      final json = await _get('/settings');
      _globalSettings = json;
      final snapshot = _snapshotFrom(json);
      _snapshot = snapshot;
      _publishCatalog(snapshot.catalog);
      if (!_pinnedChanges.isClosed) _pinnedChanges.add(snapshot.pinnedModels);
      if (!_settingsChanges.isClosed) _settingsChanges.add(null);
    } on Object {
      // Следующее событие или открытие настроек попробует снова.
    }
  }

  Future<void> _refreshModelsFromRemote() async {
    try {
      await _loadModels();
      await _loadRuntime();
    } on Object {
      // Следующее событие или открытие моделей попробует снова.
    }
  }

  void _publishSettings([Map<String, dynamic>? patch]) {
    if (patch != null) {
      _globalSettings = {...?_globalSettings, ...patch};
    }
    if (!_settingsChanges.isClosed) _settingsChanges.add(null);
  }

  Future<void> _loadChatState(String chatId) async {
    try {
      final usage = await _get('/chats/$chatId/usage');
      _usageByChat[chatId] = usage;
      final project = await _get('/chats/$chatId/project');
      final raw = project['project'];
      _projectsByChat[chatId] = raw is Map
          ? _project(Map<String, dynamic>.from(raw))
          : null;
    } on AgentApiException {
      // Чат всё равно можно открыть.
    }
  }

  Future<void> _loadModels() async {
    try {
      _publishCatalog(_catalogFrom(await _get('/models')));
    } on AgentApiException {
      // Каталог не критичен для журнала.
    }
  }

  Future<void> _loadRuntime() async {
    try {
      _publishRuntime(
        ModelRuntimeState.fromJson(await _get('/models/runtime')),
      );
    } on AgentApiException {
      // Runtime не критичен для журнала: провайдер мог быть без него.
    }
  }

  void _publishRuntime(ModelRuntimeState runtime) {
    _runtime = runtime;
    if (!_runtimeChanges.isClosed) _runtimeChanges.add(runtime);
  }

  Future<void> _loadLocalModels() async {
    try {
      _publishLocalModels(
        LocalModelsState.fromJson(await _get('/models/files')),
      );
    } on AgentApiException {
      // Старый демон не умеет локальные модели: раздел просто скрыт.
      _publishLocalModels(const LocalModelsState(supported: false));
    }
  }

  void _publishLocalModels(LocalModelsState state) {
    _localModels = state;
    if (!_localModelsChanges.isClosed) _localModelsChanges.add(state);
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
    await _send(
      'POST',
      '/chats/$chatId/messages',
      body: {
        'text': text,
        'sendNow': sendNow,
        'attachments': [
          for (final attachment in attachments) _attachmentBody(attachment),
        ],
        'mentions': [for (final mention in mentions) mention.toJson()],
        // Идентификатор создаётся здесь, если вызывающий не сохранил свой.
        // Повтор того же тела запроса (например, после обновления сессии)
        // несёт тот же id, и сервер не создаёт второе сообщение.
        'clientMessageId': clientMessageId ?? _uuid.v4(),
      },
    );
    await _trySyncSession(chatId);
  }

  Future<void> _trySyncSession(String chatId) async {
    try {
      await _syncSession(chatId);
    } on Object {
      // Очередь — дополнительная информация; без неё чат всё равно работает.
    }
  }

  Future<void> _syncSession(String chatId) async {
    final json = await _get('/chats/$chatId/session');
    final revision = _int(json, 'queueRevision');
    final current = _queueRevisions[chatId] ?? 0;
    if (revision < current) return;
    _queueRevisions[chatId] = revision;
    _queues[chatId] = [
      for (final item in (json['queue'] as List? ?? const []))
        if (item is Map) _queuedPrompt(Map<String, dynamic>.from(item)),
    ];
    if (json['isRunning'] == true) {
      _running.add(chatId);
    } else {
      _running.remove(chatId);
    }
    final turn = json['turnSnapshot'];
    if (turn is Map) {
      _turnSnapshots[chatId] = _turnSnapshot(Map<String, dynamic>.from(turn));
    } else if (json['isRunning'] != true) {
      _turnSnapshots.remove(chatId);
    }
  }

  @override
  Future<void> stop(String chatId, {String? reason}) async {
    final query = reason == null || reason.isEmpty
        ? ''
        : '?reason=${Uri.encodeQueryComponent(reason)}';
    await _send('DELETE', '/chats/$chatId/turn$query');
  }

  @override
  Future<void> resolveApproval(
    String id,
    ApprovalAction action, {
    String? reason,
  }) async {
    final body = <String, Object?>{'action': action.name};
    if (reason != null) body['reason'] = reason;
    await _send('PUT', '/approvals/$id/decision', body: body);
    _approvalsById.remove(id);
    final chatId = _approvalChats.remove(id);
    if (chatId != null && !_hasPending(chatId)) _waiting.remove(chatId);
  }

  /// [answerId] приходит из действия системного уведомления; сервер по нему
  /// отличает повторную доставку от нового ответа.
  @override
  Future<void> answerQuestion(
    String id,
    String? text, {
    String? answerId,
  }) async {
    await _send(
      'PUT',
      '/questions/$id/answer',
      body: {'answer': text, 'answerId': answerId},
    );
    _questionsById.remove(id);
    final chatId = _questionChats.remove(id);
    if (chatId != null && !_hasPending(chatId)) _waiting.remove(chatId);
  }

  @override
  Future<void> resolveEditFileChanges(
    String id,
    EditFileChangesChoice choice,
  ) async {
    await _send(
      'PUT',
      '/edit-file-changes/$id/decision',
      body: {'choice': choice.name},
    );
    _editsById.remove(id);
    final chatId = _editChats.remove(id);
    if (chatId != null && !_hasPending(chatId)) _waiting.remove(chatId);
  }

  @override
  Future<List<ApprovalRequest>> pendingApprovals(String chatId) async {
    await _syncCardsFromServer(chatId);
    return pendingApprovalsSync(chatId);
  }

  @override
  Future<List<UserQuestion>> pendingQuestions(String chatId) async {
    await _syncCardsFromServer(chatId);
    return pendingQuestionsSync(chatId);
  }

  @override
  Future<List<EditFileChangesRequest>> pendingEditFileChanges(
    String chatId,
  ) async {
    await _syncCardsFromServer(chatId);
    return pendingEditFileChangesSync(chatId);
  }

  List<ApprovalRequest> pendingApprovalsSync(String chatId) => [
    for (final value in _approvalsById.values)
      if (value.chatId == chatId) value,
  ];

  List<UserQuestion> pendingQuestionsSync(String chatId) => [
    for (final value in _questionsById.values)
      if (value.chatId == chatId) value,
  ];

  List<EditFileChangesRequest> pendingEditFileChangesSync(String chatId) => [
    for (final value in _editsById.values)
      if (value.chatId == chatId) value,
  ];

  Future<void> _syncCardsFromServer(String chatId) async {
    final json = await _get('/chats/$chatId');
    _syncCards(chatId, json);
  }

  void _syncCards(String chatId, Map<String, dynamic> json) {
    _approvalsById.removeWhere((_, value) => value.chatId == chatId);
    _questionsById.removeWhere((_, value) => value.chatId == chatId);
    _editsById.removeWhere((_, value) => value.chatId == chatId);
    // Карты для _hasPending хранят id, а не объекты. Если событие закрытия
    // потерялось при обрыве, без этой чистки бейдж ожидания останется навсегда.
    _approvalChats.removeWhere((_, value) => value == chatId);
    _questionChats.removeWhere((_, value) => value == chatId);
    _editChats.removeWhere((_, value) => value == chatId);
    for (final item in (json['approvals'] as List? ?? const [])) {
      final request = _approval(Map<String, dynamic>.from(item as Map));
      _approvalsById[request.id] = request;
      _approvalChats[request.id] = request.chatId;
    }
    for (final item in (json['questions'] as List? ?? const [])) {
      final question = _question(Map<String, dynamic>.from(item as Map));
      _questionsById[question.id] = question;
      _questionChats[question.id] = question.chatId;
    }
    for (final item in (json['editFileChanges'] as List? ?? const [])) {
      final request = _editChangesRequest(
        Map<String, dynamic>.from(item as Map),
      );
      _editsById[request.id] = request;
      _editChats[request.id] = request.chatId;
    }
    _waiting.removeWhere((id) => id == chatId && !_hasPending(chatId));
    if (_hasPending(chatId)) _waiting.add(chatId);
  }

  @override
  Future<void> resumeAfterRestart() => Future<void>.value();

  AgentSettingsSnapshot? _snapshot;

  @override
  Future<AgentSettingsSnapshot> load() async {
    final json = await _get('/settings');
    // Тот же ответ питает синхронный кэш `settings.cached`: новый чат строит
    // первый кадр до любых await и должен видеть модель по умолчанию.
    _globalSettings = json;
    _snapshot = _snapshotFrom(json);
    _publishCatalog(_snapshot!.catalog);
    return _snapshot!;
  }

  void _publishCatalog(ModelCatalogState catalog) {
    _catalog = catalog;
    if (!_catalogChanges.isClosed) _catalogChanges.add(catalog);
  }

  @override
  Stream<ModelCatalogState> watchCatalog() async* {
    if (_snapshot == null) {
      try {
        await load();
      } on AgentApiException {
        // Каталог обновится при следующем открытии или запросе.
      }
    }
    yield _catalog ?? const ModelCatalogState();
    yield* _catalogChanges.stream;
  }

  @override
  Stream<List<String>> watchPinnedModels() async* {
    if (_snapshot == null) {
      try {
        await load();
      } on AgentApiException {
        // Закрепления обновятся при следующем открытии или запросе.
      }
    }
    yield _snapshot?.pinnedModels ?? const [];
    yield* _pinnedChanges.stream;
  }

  @override
  Future<void> writeSetting(String key, String? value) async {
    await _send('PUT', '/settings/$key', body: {'value': value});
    _publishSettings({key: value});
  }

  @override
  Future<void> saveStepsDisplay(StepsDisplay value) async {
    final json = {
      'group': value.group,
      'expandWhileActive': value.expandWhileActive,
      'thoughts': value.thoughts.name,
      'tools': value.tools.name,
    };
    await _send('PUT', '/settings/steps', body: json);
    _publishSettings({'steps': json});
  }

  @override
  Future<void> savePinnedModels(List<String> ids) async {
    await _send('PUT', '/settings/pinned', body: {'pinnedModels': ids});
    _publishSettings({'pinnedModels': ids});
    if (!_pinnedChanges.isClosed) _pinnedChanges.add(ids);
  }

  @override
  Future<void> saveDenylist(List<String> patterns) async {
    await _send('PUT', '/settings/denylist', body: {'denylist': patterns});
    _publishSettings({'denylist': patterns});
  }

  @override
  Future<void> saveSecurityProfile(SecurityProfile profile) async {
    final encoded = profile.encode();
    await _send(
      'PUT',
      '/settings/security-profile',
      body: {'profile': encoded},
    );
    _publishSettings({'securityProfile': encoded});
  }

  @override
  Future<void> saveLimits(AppLimits limits) async {
    final json = limits.toMap();
    await _send('PUT', '/settings/limits', body: {'limits': json});
    _publishSettings({'limits': json});
  }

  @override
  Future<void> refreshModels() async {
    await _send('POST', '/models/refresh');
    await _loadModels();
  }

  @override
  Future<void> rememberModels(List<String> ids) async {
    await _send('POST', '/models/remember', body: {'ids': ids});
  }

  @override
  Future<List<LlmProviderStatus>> providerStatuses() async {
    final json = await _get('/providers');
    return _providerStatusesFrom(json);
  }

  @override
  Future<LlmProviderStatus> checkProvider(String providerId) async {
    final json = await _send('POST', '/providers/$providerId/check');
    return _providerStatusFrom(Map<String, dynamic>.from(json as Map));
  }

  @override
  Future<void> saveProviderBaseUrl(String providerId, String? baseUrl) async {
    await _send('PUT', '/providers/$providerId', body: {'baseUrl': baseUrl});
  }

  @override
  Future<LlmProviderStatus> saveProviderApiKey(
    String providerId,
    String key,
  ) async {
    final json = await _send(
      'POST',
      '/providers/$providerId/key',
      body: {'key': key},
    );
    return _providerStatusFrom(Map<String, dynamic>.from(json as Map));
  }

  @override
  Future<void> deleteProviderApiKey(String providerId) async {
    await _send('DELETE', '/providers/$providerId/key');
  }

  @override
  Future<void> setProviderEnabled(String providerId, bool enabled) async {
    await _send('PUT', '/providers/$providerId', body: {'enabled': enabled});
  }

  @override
  Future<McpSnapshot> mcpSnapshot() async {
    final snapshot = mcpSnapshotFromJson(await _get('/mcp'));
    _mcpSnapshot = snapshot;
    for (final state in snapshot.states.values) {
      if (!_mcpStateChanges.isClosed) _mcpStateChanges.add(state);
    }
    return snapshot;
  }

  @override
  Stream<McpServerState> watchStates() async* {
    final snapshot = _mcpSnapshot;
    if (snapshot != null) yield* Stream.fromIterable(snapshot.states.values);
    yield* _mcpStateChanges.stream;
  }

  @override
  Future<void> ensureReady() async {
    await _send('POST', '/mcp/ready');
  }

  @override
  Future<void> save(McpServerConfig server, {int? expectedRevision}) async {
    await _send(
      'PUT',
      '/mcp/servers/${server.id}',
      body: {...mcpServerToJson(server), 'expectedRevision': ?expectedRevision},
    );
  }

  @override
  Future<void> delete(McpServerConfig server) async {
    await _send('DELETE', '/mcp/servers/${server.id}');
  }

  @override
  Future<void> restart(McpServerConfig server) async {
    await _send('POST', '/mcp/servers/${server.id}/restart');
  }

  @override
  Future<void> refreshTools(McpServerConfig server) async {
    await _send('POST', '/mcp/servers/${server.id}/tools/refresh');
  }

  @override
  Future<McpImportResult> importConfig() async {
    final json = await _send('POST', '/mcp/import', body: const {});
    return mcpImportFromJson(Map<String, dynamic>.from(json as Map));
  }

  @override
  Future<McpImportResult> importConfigText(
    String raw, {
    String? sourcePath,
  }) async {
    final json = await _send(
      'POST',
      '/mcp/import',
      body: {'text': raw, 'sourcePath': ?sourcePath},
    );
    return mcpImportFromJson(Map<String, dynamic>.from(json as Map));
  }

  @override
  Future<String> exportConfig() async {
    final json = await _get('/mcp/export');
    return '${json['text'] ?? ''}';
  }

  @override
  Future<PluginSnapshot> pluginSnapshot() async =>
      pluginSnapshotFromJson(await _get('/plugins'));

  @override
  Future<Set<String>> missingDependencies(String id) async {
    final json = await _get('/plugins/$id/missing-dependencies');
    return _ids(json);
  }

  @override
  Future<Set<String>> dependents(String id) async {
    final json = await _get('/plugins/$id/dependents');
    return _ids(json);
  }

  @override
  Future<void> setEnabled(
    Set<String> ids, {
    required bool enabled,
    int? expectedRevision,
  }) async {
    await _send(
      'PUT',
      '/plugins/enabled',
      body: {
        'ids': ids.toList()..sort(),
        'enabled': enabled,
        'expectedRevision': ?expectedRevision,
      },
    );
  }

  @override
  plugins.PluginSettings settingsFor(String id) =>
      _RemotePluginSettings(this, id);

  @override
  Future<void> refresh() async {
    await _send('POST', '/plugins/refresh');
  }

  @override
  Future<SecurityReport> run({
    SecurityRunMode mode = SecurityRunMode.gui,
  }) async => securityReportFromJson(await _get('/security/audit'));

  @override
  Future<PushSettings> pushSettings() async {
    final json = await _get('/push');
    return PushSettings(
      enabled: json['enabled'] == true,
      relayUrl: '${json['relayUrl'] ?? ''}',
      hasToken: json['hasToken'] == true,
      revision: json['revision'] is num ? (json['revision'] as num).toInt() : 0,
    );
  }

  @override
  Future<void> savePush(
    PushSettings settings, {
    String? token,
    bool clearToken = false,
    int? expectedRevision,
  }) async {
    await _send(
      'PUT',
      '/push',
      body: {
        'enabled': settings.enabled,
        'relayUrl': settings.relayUrl,
        'token': ?token,
        'clearToken': clearToken,
        'expectedRevision': ?expectedRevision,
      },
    );
  }

  @override
  Future<void> testPush() async {
    await _send('POST', '/push/test');
  }

  @override
  Future<Project?> find({required String hostId, required String workspace}) =>
      projects.find(hostId: hostId, workspace: workspace);

  @override
  Future<List<WorkspaceEntry>> searchMentions(String projectId, String query) =>
      projects.searchMentions(projectId, query);

  @override
  Stream<List<Project>> watchProjects() => _watchStateList(
    load: () async {
      final json = await _get('/projects');
      return [
        for (final item in (json['projects'] as List? ?? const []))
          if (item is Map) _project(Map<String, dynamic>.from(item)),
      ];
    },
    relevant: _projectListChanged,
  );

  @override
  Stream<Map<String, int>> watchChatCounts() => _watchStateList(
    load: () async {
      final json = await _get('/projects/counts');
      return {
        for (final entry in (json['counts'] as Map? ?? const {}).entries)
          '${entry.key}': entry.value is num ? (entry.value as num).toInt() : 0,
      };
    },
    relevant: _projectListChanged,
  );

  @override
  Stream<List<PolicyProfile>> watchPolicyProfiles() => _watchStateList(
    load: () async {
      final json = await _get('/policy-profiles');
      return [
        for (final item in (json['profiles'] as List? ?? const []))
          if (item is Map) _policy(Map<String, dynamic>.from(item)),
      ];
    },
    relevant: (area) => area == 'projects',
  );

  @override
  Stream<ProjectMemory?> watchMemory(String projectId) => _watchStateList(
    load: () async {
      final json = await _get('/projects/$projectId/memory');
      final item = json['memory'];
      return item is Map ? _memory(Map<String, dynamic>.from(item)) : null;
    },
    relevant: _projectListChanged,
  );

  @override
  Stream<List<ProjectSkill>> watchSkills(String projectId) => _watchStateList(
    load: () async {
      final json = await _get('/projects/$projectId/skills');
      return [
        for (final item in (json['skills'] as List? ?? const []))
          if (item is Map) _skill(Map<String, dynamic>.from(item)),
      ];
    },
    relevant: (area) => area == 'projects',
  );

  @override
  Stream<List<Chat>> watchProjectChats(String projectId) => _watchStateList(
    load: () async {
      final json = await _get('/projects/$projectId/chats');
      return [
        for (final item in (json['chats'] as List? ?? const []))
          if (item is Map) _chat(Map<String, dynamic>.from(item)),
      ];
    },
    relevant: _projectListChanged,
  );

  @override
  Future<void> saveProject(Project project, {int? expectedRevision}) async {
    await _send(
      'PUT',
      '/projects/${project.id}',
      body: {..._projectBody(project), 'expectedRevision': ?expectedRevision},
    );
  }

  @override
  Future<void> deleteProject(String id) async {
    await _send('DELETE', '/projects/$id');
  }

  @override
  Future<void> setTrustAgentsMd(String projectId, bool trusted) async {
    final project = await _projectById(projectId);
    await saveProject(
      project.copyWith(trustAgentsMd: trusted),
      expectedRevision: project.revision,
    );
  }

  @override
  Future<void> setSkillTrusted(
    String projectId,
    String name, {
    required bool trusted,
  }) async {
    await _send(
      'PUT',
      '/projects/$projectId/skills/$name',
      body: {'trusted': trusted},
    );
  }

  @override
  Future<void> trustWorkspace(String projectId) async {
    await _send('POST', '/projects/$projectId/trust');
  }

  @override
  Future<void> reviseMemory(String projectId, String instruction) async {
    await _send(
      'POST',
      '/projects/$projectId/memory',
      body: {'instruction': instruction},
    );
  }

  @override
  Future<void> savePolicyProfile(PolicyProfile profile) async {
    await _send(
      'PUT',
      '/policy-profiles/${profile.id}',
      body: _policyBody(profile),
    );
  }

  @override
  Future<void> deletePolicyProfile(String id) async {
    await _send('DELETE', '/policy-profiles/$id');
  }

  @override
  Future<List<String>> readDenylist() async {
    await _loadGlobalSettings();
    return [
      for (final item in (_globalSettings?['denylist'] as List? ?? const []))
        if (item is String) item,
    ];
  }

  @override
  Future<SecurityProfile> readSecurityProfile() async {
    await _loadGlobalSettings();
    final raw = _globalSettings?['securityProfile'];
    return raw is String
        ? SecurityProfile.decode(raw)
        : const SecurityProfile();
  }

  Future<Project> _projectById(String id) async {
    final json = await _get('/projects');
    for (final item in (json['projects'] as List? ?? const [])) {
      if (item is Map && item['id'] == id) {
        return _project(Map<String, dynamic>.from(item));
      }
    }
    throw AgentApiException(404, 'project_not_found', 'project $id not found');
  }

  bool _projectListChanged(String area) => area == 'projects';

  /// Начальное значение и обновления после SSE `stateAreaChanged`.
  Stream<T> _watchStateList<T>({
    required Future<T> Function() load,
    required bool Function(String area) relevant,
  }) async* {
    try {
      yield await load();
    } on Object {
      // Сервер недоступен: оставляем список пустым, статус уйдёт в offline.
      // SSE-переподключение или следующее state-событие попробует снова.
    }
    yield* _stateChanges.stream
        .where((area) => area == 'reconnect' || relevant(area))
        .asyncExpand((_) async* {
          try {
            yield await load();
          } on Object {
            // Следующее событие попробует снова.
          }
        });
  }

  void _publishState(String area) {
    if (_stateChanges.isClosed) return;
    _pendingStateAreas.add(area);
    _stateFlushTimer ??= Timer(
      const Duration(milliseconds: 30),
      _flushStateAreas,
    );
  }

  void _flushStateAreas() {
    _stateFlushTimer?.cancel();
    _stateFlushTimer = null;
    if (_stateChanges.isClosed || _pendingStateAreas.isEmpty) return;
    final areas = [..._pendingStateAreas];
    _pendingStateAreas.clear();
    for (final area in areas) {
      if (_stateChanges.isClosed) return;
      _stateChanges.add(area);
    }
  }

  @override
  Future<DataUsage> usage() async =>
      DataUsage.fromJson(await _get('/data/usage'));

  @override
  Future<HistoryClearResult> clearHistory({int? olderThanDays}) async {
    final json = await _send(
      'POST',
      '/data/history/clear',
      body: {'olderThanDays': ?olderThanDays},
    );
    return HistoryClearResult.fromJson(_asMap(json));
  }

  @override
  Future<void> resetSettings() async {
    await _send('POST', '/data/settings/reset', body: const {});
  }

  Future<Map<String, dynamic>> _get(String path) async =>
      _asMap(await _send('GET', path));

  Future<Object?> _send(String method, String path, {Object? body}) async {
    await _ensureSession();
    final session = _sessionId;
    if (session == null) {
      throw const AgentApiException(
        503,
        'session_unavailable',
        'client session is not available',
      );
    }
    try {
      return await _sendRaw(method, path, body: body, session: session);
    } on AgentApiException catch (error) {
      // Оба кода сервер возвращает до маршрута: запрос не выполнен, повтор
      // безопасен. session_required может появиться из-за гонки с другим
      // запросом, который уже сбросил сессию.
      if (error.code != 'session_expired' && error.code != 'session_required') {
        rethrow;
      }
      if (_sessionId == session) _sessionId = null;
      await _ensureSession();
      final next = _sessionId;
      if (next == null) {
        return Future<Object?>.error(
          const AgentApiException(
            503,
            'session_unavailable',
            'client session is not available',
          ),
        );
      }
      return _sendRaw(method, path, body: body, session: next);
    }
  }

  Future<Object?> _sendRaw(
    String method,
    String path, {
    Object? body,
    required String? session,
  }) async {
    final request = http.Request(method, _url(path));
    request.headers['Authorization'] = 'Bearer $token';
    request.headers['Accept'] = 'application/json';
    for (final entry in clientHeaders.entries) {
      request.headers[entry.key] = entry.value;
    }
    if (session != null) {
      request.headers[_clientSessionHeader] = session;
    }
    request.headers['x-request-id'] = _uuid.v4();
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final http.Response response;
    try {
      final streamed = await _client.send(request).timeout(timeout);
      // Таймаут покрывает и тело ответа: сеть может отдать заголовки и
      // замолчать. Иначе зависший запрос остаётся в единственной очереди
      // присутствия навсегда, и смена экрана больше не доходит до сервера.
      response = await http.Response.fromStream(streamed).timeout(timeout);
    } on http.ClientException {
      _setStatus(AgentStatus.offline);
      rethrow;
    } on TimeoutException {
      _setStatus(AgentStatus.offline);
      rethrow;
    }
    // Пока SSE-поток не восстановлен, REST-ответ не делает клиент online:
    // события всё ещё не доставляются, и UI не должен показывать «на связи».
    _setStatus(
      response.statusCode == 401 || _streamBroken
          ? AgentStatus.offline
          : AgentStatus.online,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _error(response);
    }
    if (response.body.isEmpty) return null;
    return jsonDecode(response.body);
  }

  /// Рукопожатие ровно один раз на клиент, даже при параллельных запросах.
  Future<void> _ensureSession() {
    if (_disposed) return Future<void>.value();
    if (_sessionId != null) return Future<void>.value();
    return _sessionInFlight ??= _handshake().whenComplete(
      () => _sessionInFlight = null,
    );
  }

  Future<void> _handshake() async {
    var previous = _sessionStore.read(sessionKey);
    var previousSecret = _sessionStore.read(_resumeSecretKey);
    if (previous != null && previous.isNotEmpty) {
      var active = false;
      try {
        active = await _sessionChannel.isActive(previous);
      } on Object {
        // Хранилище вкладок необязательно: сервер всё равно проверит id.
      }
      if (active) {
        _sessionStore.delete(sessionKey);
        _sessionStore.delete(_resumeSecretKey);
        previous = null;
        previousSecret = null;
      }
    }
    final json = await _sendRaw(
      'POST',
      '/client/handshake',
      body: {
        'protocol': 1,
        'previousSessionId': ?previous,
        'previousSessionSecret': ?previousSecret,
      },
      session: null,
    );
    if (_disposed) return;
    final map = _asMap(json);
    final sessionId = map['sessionId'];
    if (sessionId is! String || sessionId.isEmpty) {
      throw const AgentApiException(
        500,
        'bad_response',
        'sessionId is missing in handshake response',
      );
    }
    _sessionId = sessionId;
    _sessionStore.write(sessionKey, sessionId);
    final resumeSecret = map['resumeSecret'];
    if (resumeSecret is String && resumeSecret.isNotEmpty) {
      _sessionStore.write(_resumeSecretKey, resumeSecret);
    } else {
      // Старый сервер секрет не выдаёт: не оставляем чужой секрет рядом с
      // новым id, иначе следующее рукопожатие отправит его впустую.
      _sessionStore.delete(_resumeSecretKey);
    }
    if (map['instanceId'] is String) {
      _trackInstance(map['instanceId'] as String);
    }
    // Продолжаем нумерацию присутствия с серверного значения, чтобы reload
    // не начинал ревизии заново и не получал отказ от собственной сессии.
    final revision = map['presenceRevision'];
    if (revision is num && revision.isFinite) {
      _presenceRevision = max(_presenceRevision, revision.toInt());
    }
    final heartbeat = map['heartbeatIntervalMs'];
    if (heartbeat is num && heartbeat > 0) {
      _heartbeatInterval = Duration(
        milliseconds: heartbeat.clamp(5000, 60000).toInt(),
      );
    }
    _startHeartbeat();
  }

  /// Запоминает instanceId и сбрасывает runtime-снимки при смене экземпляра.
  void _trackInstance(String instanceId) {
    if (instanceId.isEmpty) return;
    final changed = _instanceId != null && _instanceId != instanceId;
    _instanceId = instanceId;
    if (!changed) return;
    // Сервер перезапустился: ревизии очереди и снимки шага относятся к
    // прошлому экземпляру и не должны перетирать новые данные.
    _running.clear();
    _waiting.clear();
    _queues.clear();
    _queueRevisions.clear();
    _turnSnapshots.clear();
    _approvalsById.clear();
    _approvalChats.clear();
    _questionsById.clear();
    _questionChats.clear();
    _editsById.clear();
    _editChats.clear();
    // Снимок присутствия тоже принадлежит прошлому экземпляру: сервер
    // начинает нумерацию ревизий заново, и без сброса все новые события
    // выглядели бы устаревшими, а список экранов застыл бы на старых данных.
    _clientSessionsRevision = -1;
    // Внимание устроено так же: ревизия живёт в сервисе нового сервера и
    // начинается с нуля. Без сброса запоздавший high-water mark отбрасывал бы
    // каждый свежий `chatStatusChanged`, и входящие застыли бы до тех пор,
    // пока новая ревизия не перегонит старую.
    _attentionSnapshot = AttentionSnapshot.empty;
    // Возможность откладывать относится к прошлому экземпляру: новый сервер
    // может быть старой версии, поэтому до первого снимка действие скрыто.
    _supportsSnooze = false;
    _supportsPause = false;
    _notifyReconnect();
  }

  void _startHeartbeat() {
    if (_disposed) return;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      unawaited(_sendHeartbeat());
    });
  }

  Future<void> _sendHeartbeat() => _flushPresence();

  /// Отправляет один снимок присутствия.
  ///
  /// Ревизия назначается после рукопожатия, перед самой отправкой: сервер
  /// мог вернуть более высокую ревизию переиспользованной сессии, и снимок
  /// обязан быть новее неё, иначе сервер отклонил бы изменившееся присутствие
  /// как устаревшее.
  ///
  /// Ответ несёт принятую сервером ревизию. Если наша отстала (например,
  /// сессию делит другая вкладка), запрос отклонён как устаревший, но мы
  /// догоняем сервер и отправляем следующее состояние уже с принятым номером,
  /// а не остаёмся незамеченными до перезагрузки.
  Future<void> _sendPresence() async {
    if (_disposed) return;
    try {
      // Присутствие должно дойти до сервера сразу, а не только со следующим
      // периодическим heartbeat: иначе push может уйти в уже открытый чат.
      await _ensureSession();
      if (_disposed || _sessionId == null) return;
      final revision = ++_presenceRevision;
      final interaction = _lastInteractionAt;
      final json = await _send(
        'PUT',
        '/client/session',
        body: {
          'focused': _focused,
          'activeChatId': _activeChatId,
          // Новые поля отправляем только когда клиент ими пользуется:
          // старый сервер их проигнорирует, а старые тесты и клиенты не
          // получают лишних изменений протокола.
          if (_visibility case final visibility?) 'visibility': visibility.name,
          if (interaction != null)
            'idleMs': max(
              0,
              DateTime.now().difference(interaction).inMilliseconds,
            ),
          if (_visibility != null) 'activeChatAtEnd': _activeChatAtEnd,
          'presenceRevision': revision,
        },
      );
      if (json is Map) {
        final accepted = json['presenceRevision'];
        if (accepted is num && accepted.isFinite) {
          _presenceRevision = max(_presenceRevision, accepted.toInt());
        }
      }
    } on Object {
      // Следующий запрос или SSE-переподключение восстановит сессию.
    }
  }

  Future<Map<String, dynamic>> getJson(String path) => _get(path);

  Future<Object?> sendJson(String method, String path, {Object? body}) =>
      _send(method, path, body: body);

  Map<String, dynamic> _asMap(Object? value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    throw const AgentApiException(500, 'bad_response', 'expected JSON object');
  }

  AgentApiException _error(http.Response response) {
    final requestId =
        response.headers['x-request-id'] ?? _requestIdFromBody(response.body);
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['error'] is Map) {
        final error = decoded['error'] as Map;
        return AgentApiException(
          response.statusCode,
          '${error['code'] ?? 'http_error'}',
          '${error['message'] ?? response.reasonPhrase ?? 'HTTP error'}',
          requestId: requestId,
        );
      }
    } on FormatException {
      // Ниже отдаём общий ответ.
    }
    return AgentApiException(
      response.statusCode,
      'http_${response.statusCode}',
      response.reasonPhrase ?? 'HTTP ${response.statusCode}',
      requestId: requestId,
    );
  }

  static String? _requestIdFromBody(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['requestId'] is String) {
        return decoded['requestId'] as String;
      }
    } on FormatException {
      // Не JSON — заголовок остаётся единственным источником.
    }
    return null;
  }

  Uri _url(String path) => baseUri.resolve('/api/v1$path');

  void _setStatus(AgentStatus status) {
    if (_disposed || _status == status) return;
    final wasOffline = _status == AgentStatus.offline;
    _status = status;
    if (!_statusChanges.isClosed) _statusChanges.add(status);
    // После offline списки могли быть очищены. Просим подписчиков
    // перечитать их, когда связь вернулась.
    if (status == AgentStatus.online && wasOffline) _notifyReconnect();
  }

  /// Сообщает подписчикам, что нужно сверить снимки: связь восстановилась,
  /// экземпляр сервера сменился или SSE-поток оборвался.
  ///
  /// Один переход может быть замечен несколькими путями сразу (успешный запрос
  /// поднимает статус, повторное рукопожатие меняет `instanceId`, новый поток
  /// продолжает прерванный). Уведомление откладывается на микрозадачу и
  /// схлопывается, иначе подписчики получили бы два одинаковых обновления.
  void _notifyReconnect() {
    if (_disposed || _reconnectPending) return;
    _reconnectPending = true;
    scheduleMicrotask(() {
      _reconnectPending = false;
      if (_disposed) return;
      _flushStateAreas();
      if (!_stateChanges.isClosed) _stateChanges.add('reconnect');
      if (!_reconnects.isClosed) _reconnects.add(null);
      if (_sessionId == null) return;
      unawaited(_refreshSettingsFromRemote());
      unawaited(_refreshModelsFromRemote());
      unawaited(_refreshClientSessionsQuietly());
      unawaited(_loadRuntimeQuietly());
      unawaited(_loadLocalModelsQuietly());
    });
  }

  /// Читает runtime, не выпуская сетевую ошибку наружу.
  ///
  /// Вызывается из уведомления о сверке, где сервер может быть уже недоступен:
  /// необработанная ошибка `unawaited`-футуры попала бы в зону приложения.
  Future<void> _loadRuntimeQuietly() async {
    try {
      await _loadRuntime();
    } on Object {
      // Следующее событие или переподключение повторит чтение.
    }
  }

  /// Читает файлы локальных моделей, не выпуская сетевую ошибку наружу.
  ///
  /// Отличается от публичного `refresh` у `LocalModelsSource`: там ошибка
  /// нужна вызывающему, а здесь это фоновая сверка после обрыва.
  Future<void> _loadLocalModelsQuietly() async {
    try {
      await _loadLocalModels();
    } on Object {
      // Следующее событие или переподключение повторит чтение.
    }
  }

  /// Фиксирует обрыв SSE-потока, даже если он завершился «нормально».
  ///
  /// Обычные HTTP-запросы в этот момент могут продолжать работать, поэтому
  /// восстановление не откладывается до следующего подключения: статус сразу
  /// переводится в [AgentStatus.offline], а снимки настроек, присутствия,
  /// моделей и состояния ходов перечитываются немедленно. Пока поток не
  /// вернётся, [_streamBroken] держит статус offline, чтобы REST-ответы не
  /// выдавали себя за восстановление. События, пришедшие между этим снимком и
  /// повторным подключением, догоняются вторым уведомлением при установке
  /// нового потока.
  ///
  /// Повторные неудачные попытки переподключения не шлют сверку заново:
  /// подписчиков будит только первый переход в разрыв.
  void _markStreamBroken() {
    final wasBroken = _streamBroken;
    _streamBroken = true;
    _setStatus(AgentStatus.offline);
    if (!wasBroken) _notifyReconnect();
  }

  Future<void> _listen() async {
    while (!_disposed) {
      try {
        await _ensureSession();
        // Набор открытых чатов живёт на сессии и теряется при её истечении.
        // Повторяем его при каждом подключении, но не ждём: недоступный
        // сервер не должен задерживать сам SSE на таймаут REST-запроса.
        unawaited(_syncChatSubscriptions());
        final session = _sessionId;
        if (session == null) {
          throw const AgentApiException(
            502,
            'session_unavailable',
            'client session is not available',
          );
        }
        final request = http.Request('GET', _url('/events'));
        request.headers['Authorization'] = 'Bearer $token';
        request.headers['Accept'] = 'text/event-stream';
        for (final entry in clientHeaders.entries) {
          request.headers[entry.key] = entry.value;
        }
        request.headers[_clientSessionHeader] = session;
        request.headers['x-request-id'] = _uuid.v4();
        final response = await _client.send(request);
        if (response.statusCode == 401) {
          // Неверный токен не станет верным от повторного запроса: останавливаем
          // цикл, иначе клиент будет долбить сервер каждые несколько секунд.
          await _discardResponse(response);
          _markStreamBroken();
          return;
        }
        if (response.statusCode == 410 && _sessionId == session) {
          // Сессия истекла или сервер перезапустился. Следующая попытка
          // сначала пройдёт рукопожатие; повтор запроса безопасен. Если
          // параллельный запрос уже получил новую сессию, её не трогаем.
          _sessionId = null;
        }
        if (response.statusCode != 200) {
          final status = response.statusCode;
          await _discardResponse(response);
          throw AgentApiException(
            status,
            'events_failed',
            'SSE connection failed',
          );
        }
        // Новый поток снимает запрет на online и сам сообщает о сверке:
        // статус мог остаться offline, а события между последним снимком и
        // этим потоком уже потеряны.
        final recovered = _streamBroken;
        _streamBroken = false;
        _setStatus(AgentStatus.online);
        if (recovered) _notifyReconnect();
        _reconnectDelay = reconnectBaseDelay;
        if (!_eventsReady.isCompleted) _eventsReady.complete();
        await _consume(response.stream);
        // Поток мог закончиться без исключения: сервер закрыл соединение,
        // прокси срезал его по таймауту простоя или сеть закрылась по FIN.
        // Для клиента это такой же разрыв, как и ошибка: за время потока
        // события `messageAdded`/`chatChanged` могли не дойти, instanceId
        // остался прежним, и статус `online` вводил бы UI в заблуждение.
        _markStreamBroken();
      } on AgentApiException catch (error) {
        _markStreamBroken();
        if (error.status == 401) return;
      } on Object {
        _markStreamBroken();
        // Ниже пауза и повторное подключение.
      }
      if (_disposed) break;
      await Future<void>.delayed(_nextReconnectDelay());
    }
  }

  /// Дочитывает тело неуспешного SSE-ответа, чтобы освободить соединение.
  ///
  /// `HttpClient` держит сокет, пока поток ответа не прочитан до конца.
  /// Раньше при повторяющихся `410`/`5xx` тело бросали как есть, и каждый
  /// такой ответ оставлял соединение висеть. Ошибка чтения не важна:
  /// соединение уже непригодно, а следующий цикл откроет новое. Ожидание
  /// ограничено: сервер или прокси, который отдал ошибку с бесконечным телом,
  /// не должен останавливать переподключение.
  Future<void> _discardResponse(http.StreamedResponse response) async {
    final finished = Completer<void>();
    final subscription = response.stream.listen(
      // ignore: no-empty-block, тело неуспешного ответа не нужно, важно дочитать его
      (_) {},
      onDone: () {
        if (!finished.isCompleted) finished.complete();
      },
      onError: (Object _) {
        if (!finished.isCompleted) finished.complete();
      },
      cancelOnError: true,
    );
    try {
      await finished.future.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // Тело не закончилось: отменяем чтение и освобождаем соединение.
      await subscription.cancel();
    }
  }

  /// Следующая пауза: экспоненциальный рост до [reconnectMaxDelay] плюс
  /// случайная добавка, чтобы несколько клиентов не били сервер синхронно.
  Duration _nextReconnectDelay() {
    final delay = _reconnectDelay;
    final doubled = delay * 2;
    _reconnectDelay = doubled > reconnectMaxDelay ? reconnectMaxDelay : doubled;
    final maxJitterMs = (delay.inMilliseconds * reconnectJitter).round();
    final jitter = maxJitterMs <= 0 ? 0 : _random.nextInt(maxJitterMs + 1);
    return delay + Duration(milliseconds: jitter);
  }

  Future<void> _consume(Stream<List<int>> stream) async {
    String? event;
    final data = StringBuffer();
    final lines = stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (line.isEmpty) {
        if (event != null && data.isNotEmpty) {
          _dispatch(event, data.toString());
        }
        event = null;
        data.clear();
        continue;
      }
      if (line.startsWith(':')) continue;
      if (line.startsWith('event:')) {
        event = line.replaceFirst('event:', '').trim();
      } else if (line.startsWith('data:')) {
        data.writeln(line.replaceFirst('data:', '').trimLeft());
      }
    }
  }

  void _trackChatState(String chatId, Map<String, dynamic> json) {
    if (json['running'] == true) {
      _running.add(chatId);
    } else {
      _running.remove(chatId);
    }
    if (json['waiting'] == true) {
      _waiting.add(chatId);
    } else {
      _waiting.remove(chatId);
    }
  }

  bool _hasPending(String chatId) =>
      _approvalChats.containsValue(chatId) ||
      _questionChats.containsValue(chatId) ||
      _editChats.containsValue(chatId);

  void _dispatch(String event, String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return;
    final json = Map<String, dynamic>.from(decoded);
    switch (event) {
      case 'approval':
        final request = _approval(json);
        _approvalChats[request.id] = request.chatId;
        _approvalsById[request.id] = request;
        _waiting.add(request.chatId);
        _approvals.add(request);
      case 'question':
        final question = _question(json);
        _questionChats[question.id] = question.chatId;
        _questionsById[question.id] = question;
        _waiting.add(question.chatId);
        _questions.add(question);
      case 'editFileChanges':
        final request = _editChangesRequest(json);
        _editChats[request.id] = request.chatId;
        _editsById[request.id] = request;
        _waiting.add(request.chatId);
        _editChanges.add(request);
      case 'approvalResolved':
        final chatId = _string(json, 'chatId');
        final id = _string(json, 'requestId');
        _approvalChats.remove(id);
        _approvalsById.remove(id);
        if (!_hasPending(chatId)) _waiting.remove(chatId);
        _resolutions.add(ApprovalResolved(chatId: chatId, requestId: id));
      case 'questionResolved':
        final chatId = _string(json, 'chatId');
        final id = _string(json, 'questionId');
        _questionChats.remove(id);
        _questionsById.remove(id);
        if (!_hasPending(chatId)) _waiting.remove(chatId);
        _resolutions.add(QuestionResolved(chatId: chatId, questionId: id));
      case 'editFileChangesResolved':
        final chatId = _string(json, 'chatId');
        final id = _string(json, 'requestId');
        _editChats.remove(id);
        _editsById.remove(id);
        if (!_hasPending(chatId)) _waiting.remove(chatId);
        _resolutions.add(
          EditFileChangesResolved(chatId: chatId, requestId: id),
        );
      case 'clientSessionsChanged':
        if (json['sessions'] is List) {
          _applyClientSessions(json);
        } else {
          // Старый сервер присылал пустое событие: снимок читается запросом.
          unawaited(_refreshClientSessionsQuietly());
        }
      case 'chatStatusChanged':
        // Новый сервер присылает `snoozed` в каждом снимке. Отсутствие поля
        // у старого демона не должно сбрасывать уже известную возможность:
        // после обновления демона снимок снова придёт с пустым списком.
        if (json.containsKey('snoozed')) _supportsSnooze = true;
        if (json.containsKey('pause')) _supportsPause = true;
        _applyAttention(_attentionSnapshotFrom(json));
      case 'notificationDigestDue':
        if (!_pauseDigestDue.isClosed) {
          _pauseDigestDue.add(_attentionDigestFrom(json));
        }
      case 'attentionDue':
        final chatId = _string(json, 'chatId');
        if (chatId.isNotEmpty && !_attentionDue.isClosed) {
          _attentionDue.add(chatId);
        }
      case 'turnStarted':
        final chatId = _string(json, 'chatId');
        _running.add(chatId);
        _events.add(AgentTurnStarted(chatId));
      case 'turnSnapshot':
        final chatId = _string(json, 'chatId');
        final snapshot = _turnSnapshot(json);
        _turnSnapshots[chatId] = snapshot;
        if (snapshot.isRunning) {
          _running.add(chatId);
        } else {
          _running.remove(chatId);
        }
        _events.add(
          AgentTurnSnapshot(
            chatId,
            text: snapshot.text,
            reasoning: snapshot.reasoning,
            isRunning: snapshot.isRunning,
          ),
        );
      case 'turnFinished':
        final chatId = _string(json, 'chatId');
        _running.remove(chatId);
        _turnSnapshots.remove(chatId);
        _events.add(
          AgentTurnFinished(
            chatId,
            TurnEnd.values.byName(_string(json, 'end')),
          ),
        );
        _publishState('chats');
        _publishState('projects');
      case 'messageAdded':
        _events.add(
          AgentMessageAdded(
            _string(json, 'chatId'),
            _message(Map<String, dynamic>.from(json['message'] as Map)),
          ),
        );
        _publishState('chats');
      case 'textDelta':
        _events.add(
          AgentTextDelta(
            _string(json, 'chatId'),
            '${json['text'] ?? ''}',
            reset: json['reset'] == true,
          ),
        );
      case 'reasoningDelta':
        _events.add(
          AgentReasoningDelta(
            _string(json, 'chatId'),
            '${json['text'] ?? ''}',
            reset: json['reset'] == true,
          ),
        );
      case 'runChanged':
        _events.add(
          AgentRunChanged(
            _string(json, 'chatId'),
            _run(Map<String, dynamic>.from(json['run'] as Map)),
          ),
        );
      case 'queueChanged':
        final chatId = _string(json, 'chatId');
        final revision = _int(json, 'queueRevision');
        final current = _queueRevisions[chatId] ?? 0;
        if (revision < current) break;
        final items = json['items'];
        if (items is List) {
          _queueRevisions[chatId] = revision;
          _queues[chatId] = [
            for (final item in items)
              if (item is Map) _queuedPrompt(Map<String, dynamic>.from(item)),
          ];
        } else {
          // Старый сервер присылал только size: догружаем снимок.
          unawaited(_trySyncSession(chatId));
        }
        _events.add(
          AgentQueueChanged(
            chatId,
            _queues[chatId] ?? const [],
            revision: revision,
          ),
        );
      case 'failure':
        _events.add(
          AgentFailureRaised(
            _string(json, 'chatId'),
            GenericFailure('${json['message'] ?? ''}'),
          ),
        );
      case 'trustNeeded':
        _events.add(
          AgentTrustNeeded(
            _string(json, 'chatId'),
            json['workspace'] as String?,
          ),
        );
      case 'usage':
        _events.add(
          AgentUsageUpdated(
            _string(json, 'chatId'),
            _int(json, 'promptTokens'),
            _int(json, 'limit'),
            estimated: json['estimated'] == true,
            contextWindowKnown: json['contextWindowKnown'] as bool? ?? true,
            dailyCostUsd: _double(json['dailyCostUsd']),
            dailyBudgetUsd: _double(json['dailyBudgetUsd']),
          ),
        );
      case 'stateChanged':
        _events.add(AgentStateChanged(_string(json, 'chatId')));
      case 'chatChanged':
        _events.add(AgentStateChanged(_string(json, 'chatId')));
      case 'chatReadChanged':
        // Курсор прочтения — часть снимка списка чатов. Отдельного события
        // для ленты не нужно: позиция прокрутки остаётся у устройства.
        _publishState('chats');
      case 'chatDeleted':
        final chatId = _string(json, 'chatId');
        _running.remove(chatId);
        _waiting.remove(chatId);
        _turnSnapshots.remove(chatId);
        _queues.remove(chatId);
        _queueRevisions.remove(chatId);
        _events.add(AgentChatDeleted(chatId));
      case 'stateAreaChanged':
        final area = _string(json, 'area');
        if (area == 'settings') {
          unawaited(_refreshSettingsFromRemote());
        } else if (area == 'models') {
          unawaited(_refreshModelsFromRemote());
        }
        _publishState(area);
      case 'modelRuntime':
        _publishRuntime(ModelRuntimeState.fromJson(json['runtime']));
      case 'localModels':
        _publishLocalModels(LocalModelsState.fromJson(json));
      case 'draftChanged':
        if (!_draftChanges.isClosed) {
          _draftChanges.add(_string(json, 'chatId'));
        }
    }
  }
}

Project _project(Map<String, dynamic> json) => Project(
  id: _string(json, 'id'),
  hostId: _string(json, 'hostId'),
  name: _string(json, 'name'),
  workspace: _string(json, 'workspace'),
  workspaceKey: _string(json, 'workspaceKey'),
  policyProfileId: json['policyProfileId'] as String?,
  trustAgentsMd: json['trustAgentsMd'] == true,
  skillsInitialized: json['skillsInitialized'] == true,
  archivedAt: _date(json['archivedAt']),
  revision: json['revision'] is num ? (json['revision'] as num).toInt() : 0,
  createdAt: _date(json['createdAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
  updatedAt: _date(json['updatedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
);

Map<String, Object?> _projectBody(Project project) => {
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

ProjectMemory _memory(Map<String, dynamic> json) => ProjectMemory(
  projectId: _string(json, 'projectId'),
  summary: _string(json, 'summary'),
  updatedAt: _date(json['updatedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
);

ProjectSkill _skill(Map<String, dynamic> json) =>
    ProjectSkill(name: _string(json, 'name'), trusted: json['trusted'] == true);

PolicyProfile _policy(Map<String, dynamic> json) => PolicyProfile(
  id: _string(json, 'id'),
  name: _string(json, 'name'),
  description: json['description'] as String?,
  profile: SecurityProfile.decode('${json['profile'] ?? '{}'}'),
  createdAt: _date(json['createdAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
  updatedAt: _date(json['updatedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
);

Map<String, Object?> _policyBody(PolicyProfile profile) => {
  'name': profile.name,
  'description': profile.description,
  'profile': profile.profile.encode(),
  'createdAt': profile.createdAt.toUtc().toIso8601String(),
  'updatedAt': profile.updatedAt.toUtc().toIso8601String(),
};

AgentSettingsSnapshot _snapshotFrom(Map<String, dynamic> json) {
  final rawLimits = json['limits'];
  final rawCatalog = json['catalog'];
  final catalog = rawCatalog is Map
      ? _catalogFrom(Map<String, dynamic>.from(rawCatalog))
      : const ModelCatalogState();
  return AgentSettingsSnapshot(
    defaultModel: '${json['defaultModel'] ?? ''}',
    titleModel: '${json['titleModel'] ?? ''}',
    memoryModel: '${json['memoryModel'] ?? ''}',
    subagentModel: '${json['subagentModel'] ?? ''}',
    fallbackModel: '${json['fallbackModel'] ?? ''}',
    defaultReasoning: ReasoningPreference.parse(
      json['defaultReasoning'] as String?,
    ),
    memoryReasoning: ReasoningPreference.parse(
      json['memoryReasoning'] as String?,
    ),
    subagentReasoning: ReasoningPreference.parse(
      json['subagentReasoning'] as String?,
    ),
    fallbackReasoning: ReasoningPreference.parse(
      json['fallbackReasoning'] as String?,
    ),
    defaultPolicy: '${json['defaultPolicy'] ?? 'ask'}',
    denylist: [
      for (final item in (json['denylist'] as List? ?? const []))
        if (item is String) item,
    ],
    securityProfile: SecurityProfile.decode(
      '${json['securityProfile'] ?? '{}'}',
    ),
    limits: rawLimits is Map
        ? AppLimits.fromJson(jsonEncode(Map<String, dynamic>.from(rawLimits)))
        : const AppLimits(),
    pinnedModels: [
      for (final item in (json['pinnedModels'] as List? ?? const []))
        if (item is String) item,
    ],
    stepsDisplay: json['steps'] is Map
        ? _steps(Map<String, dynamic>.from(json['steps'] as Map))
        : StepsDisplay.defaults,
    catalog: catalog,
  );
}

LlmKeyInfo _keyInfo(Map<String, dynamic> json) => LlmKeyInfo(
  label: '${json['label'] ?? ''}',
  usage: _double(json['usage']) ?? 0,
  limit: _double(json['limit']),
  limitRemaining: _double(json['limitRemaining']),
  limitReset: json['limitReset'] as String?,
  isFreeTier: json['isFreeTier'] == true,
  expiresAt: _date(json['expiresAt']),
);

StepsDisplay _steps(Map<String, dynamic> json) => StepsDisplay(
  group: json['group'] != false,
  expandWhileActive: json['expandWhileActive'] != false,
  thoughts: ThoughtsVisibility.values.byName('${json['thoughts'] ?? 'all'}'),
  tools: ToolsVisibility.values.byName('${json['tools'] ?? 'all'}'),
);

ModelCatalogState _catalogFrom(Map<String, dynamic> json) => ModelCatalogState(
  models: [
    for (final item in (json['models'] as List? ?? const []))
      if (item is Map) _model(Map<String, dynamic>.from(item)),
  ],
  saved: {
    for (final entry in (json['saved'] as Map? ?? const {}).entries)
      '${entry.key}': _savedModel(
        Map<String, dynamic>.from(entry.value as Map),
      ),
  },
  syncedAt: _date(json['syncedAt']),
  loading: json['loading'] == true,
  error: json['error'] as String?,
  providers: [
    for (final item in (json['providers'] as List? ?? const []))
      if (item is Map) _descriptorFrom(Map<String, dynamic>.from(item)),
  ],
  providerStatuses: {
    for (final entry in (json['providerStatuses'] as Map? ?? const {}).entries)
      '${entry.key}': _providerStatusFrom(
        Map<String, dynamic>.from(entry.value as Map),
      ),
  },
);

/// Дескриптор провайдера из JSON-ответа.
LlmProviderDescriptor _descriptorFrom(Map<String, dynamic> json) =>
    LlmProviderDescriptor(
      id: _string(json, 'id'),
      label: _string(json, 'label'),
      modelPrefix: '${json['modelPrefix'] ?? ''}',
      defaultBaseUrl: json['defaultBaseUrl'] as String?,
      requiresApiKey: json['requiresApiKey'] == true,
      supportsApiKey: json['supportsApiKey'] != false,
      supportsBaseUrl: json['supportsBaseUrl'] == true,
      supportsEnabledToggle: json['supportsEnabledToggle'] != false,
      supportsKeyInfo: json['supportsKeyInfo'] == true,
      apiKeyExample: json['apiKeyExample'] as String?,
    );

/// Статус провайдера из JSON-ответа. Секрет сюда не попадает.
LlmProviderStatus _providerStatusFrom(Map<String, dynamic> json) =>
    LlmProviderStatus(
      id: _string(json, 'id'),
      enabled: json['enabled'] != false,
      baseUrl: json['baseUrl'] as String?,
      apiKeySet: json['apiKeySet'] == true,
      apiKeyTail: '${json['apiKeyTail'] ?? ''}',
      available: json['available'] == true,
      modelCount: json['modelCount'] as int?,
      error: json['error'] as String?,
      checkedAt: _date(json['checkedAt']),
      keyInfo: json['keyInfo'] is Map
          ? _keyInfo(Map<String, dynamic>.from(json['keyInfo'] as Map))
          : null,
    );

/// Список статусов из ответа `GET /providers`.
List<LlmProviderStatus> _providerStatusesFrom(Object? json) {
  if (json is! Map) return const [];
  final items = json['providers'];
  if (items is! List) return const [];
  return [
    for (final item in items)
      if (item is Map) _providerStatusFrom(Map<String, dynamic>.from(item)),
  ];
}

LlmModelInfo _model(Map<String, dynamic> json) => LlmModelInfo(
  id: _string(json, 'id'),
  name: _string(json, 'name'),
  contextLength: json['contextLength'] as int?,
  supportsTools: json['supportsTools'] == true,
  promptPrice: json['promptPrice'] as String?,
  completionPrice: json['completionPrice'] as String?,
  created: json['created'] as int?,
  inputModalities: json['inputModalities'] is List
      ? [for (final item in json['inputModalities'] as List) '$item']
      : null,
  reasoning: LlmReasoningCapability.fromJson(json['reasoning']),
);

SavedModel _savedModel(Map<String, dynamic> json) => SavedModel(
  id: _string(json, 'id'),
  name: _string(json, 'name'),
  contextLength: json['contextLength'] as int?,
  supportsTools: json['supportsTools'] == true,
  inputModalities: json['inputModalities'] is List
      ? [for (final item in json['inputModalities'] as List) '$item']
      : null,
  reasoning: LlmReasoningCapability.fromJson(json['reasoning']),
);

Map<String, Object?> _chatBody(Chat chat) => {
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
  'createdAt': chat.createdAt.toUtc().toIso8601String(),
  'updatedAt': chat.updatedAt.toUtc().toIso8601String(),
};

Chat _chat(Map<String, dynamic> json) => Chat(
  id: _string(json, 'id'),
  hostId: _string(json, 'hostId'),
  projectId: json['projectId'] as String?,
  kind: ChatKind.values.byName('${json['kind'] ?? 'main'}'),
  parentChatId: json['parentChatId'] as String?,
  rootChatId: json['rootChatId'] as String?,
  depth: _int(json, 'depth'),
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
  draft: json['draft'] is Map
      ? _draft(Map<String, dynamic>.from(json['draft'] as Map))
      : ChatDraft.empty,
  messageEdits: decodeMessageEdits('${json['messageEdits'] ?? ''}'),
  draftRevision: _int(json, 'draftRevision'),
  messageEditsRevision: _int(json, 'messageEditsRevision'),
  revision: _int(json, 'revision'),
  lastReadSeq: _int(json, 'lastReadSeq'),
  readRevision: _int(json, 'readRevision'),
  lastMessageSeq: _int(json, 'lastMessageSeq'),
  unreadCount: _int(json, 'unreadCount'),
  createdAt: _time(json, 'createdAt'),
  updatedAt: _time(json, 'updatedAt'),
);

ChatDraft _draft(Map<String, dynamic> json) => ChatDraft(
  text: '${json['text'] ?? ''}',
  attachments: [
    for (final item in (json['attachments'] as List? ?? const []))
      if (item is Map) AttachmentRef.fromJson(Map<String, dynamic>.from(item)),
  ],
  mentions: [
    for (final item in (json['mentions'] as List? ?? const []))
      if (item is Map) MentionRef.fromJson(Map<String, dynamic>.from(item)),
  ],
);

SearchHit _searchHit(Map<String, dynamic> json) => SearchHit(
  kind: SearchHitKind.values.byName('${json['kind'] ?? 'message'}'),
  title: _string(json, 'title'),
  score: (json['score'] as num?)?.toDouble() ?? 0,
  chatId: json['chatId'] as String?,
  chatTitle: json['chatTitle'] as String?,
  projectId: json['projectId'] as String?,
  messageId: json['messageId'] as String?,
  seq: json['seq'] is num ? (json['seq'] as num).toInt() : null,
  snippet: json['snippet'] as String?,
);

ChatMessage _message(Map<String, dynamic> json) => ChatMessage(
  id: _string(json, 'id'),
  chatId: _string(json, 'chatId'),
  seq: _int(json, 'seq'),
  role: MessageRole.values.byName(_string(json, 'role')),
  text: '${json['text'] ?? ''}',
  reasoning: '${json['reasoning'] ?? ''}',
  toolCalls: [
    for (final call in (json['toolCalls'] as List? ?? const []))
      ToolCallRef.fromJson(Map<String, dynamic>.from(call as Map)),
  ],
  toolCallId: json['toolCallId'] as String?,
  attachments: [
    for (final attachment in (json['attachments'] as List? ?? const []))
      AttachmentRef(
        name: '${(attachment as Map)['name'] ?? ''}',
        mode: AttachmentMode.values.byName('${attachment['mode'] ?? 'file'}'),
        mimeType: attachment['mimeType'] as String?,
        sizeBytes: _int(Map<String, dynamic>.from(attachment), 'sizeBytes'),
      ),
  ],
  mentions: [
    for (final mention in (json['mentions'] as List? ?? const []))
      if (mention is Map)
        MentionRef.fromJson(Map<String, dynamic>.from(mention)),
  ],
  createdAt: _time(json, 'createdAt'),
);

List<ClientSessionView> _clientSessionsFrom(Map<String, dynamic> json) => [
  for (final item in (json['sessions'] as List? ?? const []))
    if (item is Map) _clientSessionView(Map<String, dynamic>.from(item)),
];

ClientSessionView _clientSessionView(Map<String, dynamic> item) {
  final focused = item['focused'] == true;
  return ClientSessionView(
    id: _string(item, 'id'),
    deviceId: '${item['deviceId'] ?? ''}',
    clientId: '${item['clientId'] ?? ''}',
    clientApp: '${item['clientApp'] ?? ''}',
    clientVersion: '${item['clientVersion'] ?? ''}',
    clientBuild: '${item['clientBuild'] ?? ''}',
    clientPlatform: '${item['clientPlatform'] ?? ''}',
    activeChatId: item['activeChatId'] as String?,
    createdAt: _time(item, 'createdAt'),
    lastSeenAt: _time(item, 'lastSeenAt'),
    expiresAt: _time(item, 'expiresAt'),
    focused: focused,
    // Старый сервер не присылает `active`: для совместимости фокус остаётся
    // признаком присутствия, как было до появления idle-детекта.
    active: item['active'] is bool ? item['active'] as bool : focused,
    // Старый сервер не адресует уведомления: все экраны остаются целями,
    // иначе после обновления клиента уведомления пропали бы везде.
    attention: item['attention'] != false,
    visibility: ClientVisibility.parse(item['visibility']),
    lastInteractionAt: _date(item['lastInteractionAt']),
    // Старый сервер не присылал поле: открытый чат считался видимым целиком.
    activeChatAtEnd: item['activeChatAtEnd'] != false,
    online: item['online'] != false,
    current: item['current'] == true,
  );
}

TurnSnapshot _turnSnapshot(Map<String, dynamic> json) => TurnSnapshot(
  text: '${json['text'] ?? ''}',
  reasoning: '${json['reasoning'] ?? ''}',
  isRunning: json['isRunning'] != false,
);

ToolRun _run(Map<String, dynamic> json) => ToolRun(
  id: _string(json, 'id'),
  chatId: _string(json, 'chatId'),
  messageId: _string(json, 'messageId'),
  toolName: _string(json, 'toolName'),
  argsJson: '${json['argsJson'] ?? ''}',
  command: json['command'] as String?,
  background: json['background'] == true,
  status: ToolRunStatus.values.byName(_string(json, 'status')),
  resultError: json['resultError'] == true,
  pid: json['pid'] as int?,
  exitCode: json['exitCode'] as int?,
  timedOut: json['timedOut'] == true,
  outputText: json['outputText'] as String?,
  outputTruncated: json['outputTruncated'] == true,
  resultPreview: json['resultPreview'] as String?,
  startedAt: _time(json, 'startedAt'),
  finishedAt: _date(json['finishedAt']),
  toolCallId: json['toolCallId'] as String?,
  pendingCard: json['pendingCard'] == null
      ? null
      : jsonEncode(json['pendingCard']),
);

QueuedPrompt _queuedPrompt(Map<String, dynamic> json) {
  final text = '${json['text'] ?? ''}';
  final id = '${json['id'] ?? ''}';
  if (json['isEvent'] == true) return QueuedPrompt.event(text, id: id);
  return QueuedPrompt.user(
    text,
    id: id,
    attachments: [
      for (final item in (json['attachments'] as List? ?? const []))
        if (item is Map)
          AttachmentRef.fromJson(Map<String, dynamic>.from(item)),
    ],
    mentions: [
      for (final mention in (json['mentions'] as List? ?? const []))
        if (mention is Map)
          MentionRef.fromJson(Map<String, dynamic>.from(mention)),
    ],
    note: json['note'] as String?,
  );
}

Map<String, Object?> _attachmentBody(AttachmentRef attachment) => {
  'name': attachment.name,
  'mode': attachment.mode.name,
  'content': attachment.content,
  'mimeType': attachment.mimeType,
  'sizeBytes': attachment.sizeBytes,
  if (attachment.bytes != null) 'bytes': base64Encode(attachment.bytes!),
};

Map<String, Object?> _hostBody(Host host) => {
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
  'revision': host.revision,
  'createdAt': host.createdAt.toUtc().toIso8601String(),
  'updatedAt': host.updatedAt.toUtc().toIso8601String(),
};

Host _host(Map<String, dynamic> json) => Host(
  id: _string(json, 'id'),
  name: _string(json, 'name'),
  kind: HostKind.values.byName(_string(json, 'kind')),
  address: json['address'] as String?,
  port: _int(json, 'port'),
  username: json['username'] as String?,
  authType: SshAuthType.values.byName('${json['authType'] ?? 'key'}'),
  keyPath: json['keyPath'] as String?,
  hostKeyFingerprint: json['hostKeyFingerprint'] as String?,
  os: HostOs.values.byName('${json['os'] ?? 'posix'}'),
  systemLabel: json['systemLabel'] is String
      ? json['systemLabel'] as String
      : null,
  defaultWorkspace: json['defaultWorkspace'] as String?,
  shellOverride: json['shellOverride'] as String?,
  notes: json['notes'] as String?,
  connectTimeoutSeconds: json['connectTimeoutSeconds'] is num
      ? (json['connectTimeoutSeconds'] as num).toInt()
      : null,
  lastCheckAt: _date(json['lastCheckAt']),
  lastLatencyMs: json['lastLatencyMs'] is num
      ? (json['lastLatencyMs'] as num).toInt()
      : null,
  lastCheckError: json['lastCheckError'] as String?,
  revision: json['revision'] is num ? (json['revision'] as num).toInt() : 0,
  createdAt:
      _date(json['createdAt']) ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  updatedAt:
      _date(json['updatedAt']) ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
);

AttentionSnapshot _attentionSnapshotFrom(Map<String, dynamic> json) =>
    AttentionSnapshot(
      revision: _int(json, 'revision'),
      items: [
        for (final item in (json['items'] as List? ?? const []))
          if (item is Map) _chatAttention(Map<String, dynamic>.from(item)),
      ],
      snoozed: (json['snoozed'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => _chatSnooze(Map<String, dynamic>.from(item)))
          .whereType<ChatSnooze>()
          .toList(),
      pause: json['pause'] is Map
          ? _notificationPause(Map<String, dynamic>.from(json['pause'] as Map))
          : null,
      // Старый сервер не присылает `unreadTotal`: null означает «считай
      // сумму сам по снимку списка чатов», а не «непрочитанных нет».
      unreadTotal: json['unreadTotal'] is num
          ? (json['unreadTotal'] as num).toInt()
          : null,
    );

/// Пауза уведомлений из снимка входящих. Битое поле читается как отсутствие
/// паузы: лучше показать уведомление, чем молчать из-за неизвестного срока.
NotificationPause? _notificationPause(Map<String, dynamic> json) {
  final until = _date(json['until']);
  if (until == null) return null;
  final reason = json['reason'];
  return NotificationPause(
    until: until,
    reason: NotificationPauseReason.fromStorage(
      reason is String ? reason : null,
    ),
    revision: _int(json, 'revision'),
  );
}

/// Срок из снимка входящих.
///
/// Старый сервер поля не присылает — тогда напоминаний просто нет. Без срока
/// запись пропускается: скрыть чат «навсегда» из-за битого поля хуже, чем
/// показать его в обычном списке.
ChatSnooze? _chatSnooze(Map<String, dynamic> json) {
  final until = _date(json['until']);
  final chatId = _string(json, 'chatId');
  if (until == null || chatId.isEmpty) return null;
  return ChatSnooze(
    chatId: chatId,
    until: until,
    revision: _int(json, 'revision'),
  );
}

ChatAttention _chatAttention(Map<String, dynamic> json) => ChatAttention(
  chatId: _string(json, 'chatId'),
  hostId: _string(json, 'hostId'),
  projectId: json['projectId'] as String?,
  title: '${json['title'] ?? ''}',
  reasons: {
    for (final reason in (json['reasons'] as List? ?? const []))
      if (reason is String &&
          ChatAttentionReason.values.asNameMap().containsKey(reason))
        ChatAttentionReason.values.byName(reason),
  },
  approvals: [
    for (final item in (json['approvals'] as List? ?? const []))
      if (item is Map) _approval(Map<String, dynamic>.from(item)),
  ],
  questions: [
    for (final item in (json['questions'] as List? ?? const []))
      if (item is Map) _question(Map<String, dynamic>.from(item)),
  ],
  editFileChanges: [
    for (final item in (json['editFileChanges'] as List? ?? const []))
      if (item is Map) _editChangesRequest(Map<String, dynamic>.from(item)),
  ],
  unreadCount: _int(json, 'unreadCount'),
  lastReadSeq: _int(json, 'lastReadSeq'),
  lastMessageSeq: _int(json, 'lastMessageSeq'),
  running: json['running'] == true,
  turnAt: _date(json['turnAt']),
  updatedAt: _time(json, 'updatedAt'),
);

AttentionDigest _attentionDigestFrom(Map<String, dynamic> json) =>
    AttentionDigest(
      items: [
        for (final item in (json['items'] as List? ?? const []))
          if (item is Map)
            _attentionDigestItem(Map<String, dynamic>.from(item)),
      ],
    );

AttentionDigestItem _attentionDigestItem(Map<String, dynamic> json) =>
    AttentionDigestItem(
      chatId: _string(json, 'chatId'),
      hostId: _string(json, 'hostId'),
      projectId: json['projectId'] as String?,
      title: '${json['title'] ?? ''}',
      unreadMessages: _int(json, 'unreadMessages'),
      finishedTurns: _int(json, 'finishedTurns'),
      approvals: _int(json, 'approvals'),
      questions: _int(json, 'questions'),
      editFileChanges: _int(json, 'editFileChanges'),
      problems: _int(json, 'problems'),
    );

ApprovalRequest _approval(Map<String, dynamic> json) => ApprovalRequest(
  id: _string(json, 'id'),
  chatId: _string(json, 'chatId'),
  toolName: _string(json, 'toolName'),
  summary: _string(json, 'summary'),
  reason: _string(json, 'reason'),
  diff: json['diff'] as String?,
  turnId: json['turnId'] as String?,
  permissionKey: json['permissionKey'] as String?,
  grantable: json['grantable'] != false,
);

UserQuestion _question(Map<String, dynamic> json) => UserQuestion(
  id: _string(json, 'id'),
  chatId: _string(json, 'chatId'),
  text: _string(json, 'text'),
);

EditFileChangesRequest _editChangesRequest(Map<String, dynamic> json) =>
    EditFileChangesRequest(
      id: _string(json, 'id'),
      chatId: _string(json, 'chatId'),
      files: [
        for (final file in (json['files'] as List? ?? const []))
          EditFileChangesEntry(
            path: _string(Map<String, dynamic>.from(file as Map), 'path'),
            kind: TurnFileKind.values.byName(
              _string(Map<String, dynamic>.from(file), 'kind'),
            ),
          ),
      ],
      shellMayHaveChangedFiles: json['shellMayHaveChangedFiles'] == true,
      scheduledTasks: (json['scheduledTasks'] as num?)?.toInt() ?? 0,
    );

String _string(Map<String, dynamic> json, String key) => '${json[key] ?? ''}';

int _int(Map<String, dynamic> json, String key) {
  final value = json[key];
  return value is num ? value.toInt() : 0;
}

double? _double(Object? value) => value is num ? value.toDouble() : null;

Map<String, Object?> _draftBody(ChatDraft draft) => {
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

int _revision(Object? json) {
  if (json is Map && json['revision'] is num) {
    return (json['revision'] as num).toInt();
  }
  throw const AgentApiException(
    500,
    'bad_response',
    'revision is missing in draft response',
  );
}

Set<String> _ids(Map<String, dynamic> json) => {
  for (final id in (json['ids'] as List? ?? const []))
    if (id is String) id,
};

DateTime? _date(Object? value) => value is String && value.isNotEmpty
    ? DateTime.tryParse(value)?.toUtc()
    : null;

DateTime _time(Map<String, dynamic> json, String key) =>
    DateTime.parse(_string(json, key)).toUtc();

final class _RemotePluginSettings implements plugins.PluginSettings {
  _RemotePluginSettings(this._api, this._pluginId);

  final RemoteAgentApi _api;
  final String _pluginId;

  @override
  Future<Map<String, Object?>> read() async {
    final json = await _api._get('/plugins/$_pluginId/settings');
    return Map<String, Object?>.from(json);
  }

  @override
  Future<void> save(Map<String, Object?> value) async {
    await _api._send(
      'PUT',
      '/plugins/$_pluginId/settings',
      body: {'value': value},
    );
  }

  @override
  Future<bool> hasSecret(String name) async {
    final json = await _api._get(
      '/plugins/$_pluginId/secrets/${Uri.encodeComponent(name)}',
    );
    return json['exists'] == true;
  }

  @override
  Future<void> writeSecret(String name, String? value) async {
    await _api._send(
      'PUT',
      '/plugins/$_pluginId/secrets/${Uri.encodeComponent(name)}',
      body: {'value': value},
    );
  }
}

final class _RemoteChatStore implements ChatStore, DraftRefreshSource {
  _RemoteChatStore(this._api);

  final RemoteAgentApi _api;

  @override
  Future<Chat?> chat(String id) => _api.chat(id);

  @override
  Future<Chat?> chatForDraft(String id) async {
    try {
      final json = await _api._get('/chats/$id');
      final map = Map<String, dynamic>.from(json['chat'] as Map);
      return _chat(map);
    } on AgentApiException catch (error) {
      if (error.status == 404) return null;
      rethrow;
    }
  }

  @override
  Future<List<ChatMessage>> messages(String id) => _api.messages(id);

  @override
  Future<List<ToolRun>> toolRunsForChat(String id) => _api.runs(id);

  @override
  Future<void> createChat(Chat chat) => _api.saveChat(chat);

  @override
  Future<void> saveChat(Chat chat) async {
    await _api.sendJson(
      'PATCH',
      '/chats/${chat.id}',
      body: {
        'title': chat.title,
        'model': chat.model,
        'reasoning': chat.reasoning.name,
        'policyMode': chat.policyMode.name,
        'workspace': chat.workspace,
      },
    );
  }

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
  }) async {
    await _api.sendJson(
      'PATCH',
      '/chats/$chatId',
      body: {
        'title': ?title,
        'model': ?model,
        'reasoning': ?reasoning?.name,
        'policyMode': ?policyMode?.name,
        if (workspaceSpecified) 'workspace': workspace,
        if (workspaceSpecified) 'workspaceSpecified': true,
        'expectedRevision': ?expectedRevision,
      },
    );
    final chat = await _api.chat(chatId);
    if (chat == null) {
      throw const AgentApiException(
        404,
        'chat_not_found',
        'chat not found after update',
      );
    }
    return chat;
  }

  @override
  Future<Chat> markRead(
    String chatId, {
    required int seq,
    int? expectedRevision,
  }) async {
    final json = await _api.sendJson(
      'PUT',
      '/chats/$chatId/read',
      body: {'seq': seq, 'expectedRevision': ?expectedRevision},
    );
    final map = Map<String, dynamic>.from(json as Map);
    final chat = _chat(map);
    // Список чатов перечитывается сразу: не полагаемся только на SSE, чтобы
    // счётчик не отставал при коротком обрыве соединения.
    _api
      .._trackChatState(chat.id, map)
      .._publishState('chats');
    return chat;
  }

  @override
  Future<int> saveDraft(
    String chatId,
    ChatDraft draft, {
    int? expectedRevision,
  }) async {
    final json = await _api.sendJson(
      'PUT',
      '/chats/$chatId/draft',
      body: {..._draftBody(draft), 'revision': ?expectedRevision},
    );
    return _revision(json);
  }

  @override
  Future<int> saveMessageEdits(
    String chatId,
    Map<String, ChatDraft> edits, {
    int? expectedRevision,
  }) async {
    final json = await _api.sendJson(
      'PUT',
      '/chats/$chatId/message-edits',
      body: {
        'edits': {
          for (final entry in edits.entries) entry.key: _draftBody(entry.value),
        },
        'revision': ?expectedRevision,
      },
    );
    return _revision(json);
  }

  @override
  Stream<String> watchDraftChanges() => _api._draftChanges.stream;
}

final class _RemoteSettings implements SettingsStore {
  _RemoteSettings(this._api);

  final RemoteAgentApi _api;

  @override
  Stream<String?> watch(String key) async* {
    try {
      yield await read(key);
    } on Object {
      // Сервер offline: отдаём null; следующее изменение настроек попробует снова.
      yield null;
    }
    yield* _api._settingsChanges.stream.map((_) => _value(key));
  }

  @override
  Future<String?> read(String key) async {
    await _api._loadGlobalSettings();
    return _value(key);
  }

  @override
  Future<ReasoningPreference> readReasoning(String key) async =>
      ReasoningPreference.parse(await read(key));

  /// Значение ключа из кэша. Журналу шагов и закреплениям важно только
  /// изменение, но ключи возвращаются в том же виде, что и локальное хранилище.
  String? _value(String key) {
    final settings = _api._globalSettings;
    if (settings == null) return null;
    return switch (key) {
      SettingsRepository.keyDefaultModel => settings['defaultModel'] as String?,
      SettingsRepository.keyDefaultReasoning =>
        settings['defaultReasoning'] as String?,
      SettingsRepository.keyMemoryReasoning =>
        settings['memoryReasoning'] as String?,
      SettingsRepository.keySubagentReasoning =>
        settings['subagentReasoning'] as String?,
      SettingsRepository.keyFallbackReasoning =>
        settings['fallbackReasoning'] as String?,
      SettingsRepository.keyDefaultPolicy =>
        settings['defaultPolicy'] as String?,
      SettingsRepository.keyPinnedModels =>
        settings['pinnedModels'] == null
            ? null
            : jsonEncode(settings['pinnedModels']),
      SettingsRepository.keyStepsGroup ||
      SettingsRepository.keyStepsExpandWhileActive ||
      SettingsRepository.keyStepsThoughts ||
      SettingsRepository.keyStepsTools => jsonEncode(settings['steps']),
      _ => null,
    };
  }

  @override
  Future<List<String>> readPinnedModels() async {
    await _api._loadGlobalSettings();
    return [
      for (final id
          in (_api._globalSettings?['pinnedModels'] as List? ?? const []))
        if (id is String) id,
    ];
  }

  @override
  Future<void> savePinnedModels(List<String> ids) async {
    await _api.sendJson('PUT', '/settings/pinned', body: {'pinnedModels': ids});
    _api._publishSettings({'pinnedModels': ids});
  }

  @override
  Future<StepsDisplay> readStepsDisplay() async {
    await _api._loadGlobalSettings();
    final raw = _api._globalSettings?['steps'];
    if (raw is! Map) return StepsDisplay.defaults;
    return _steps(Map<String, dynamic>.from(raw));
  }

  @override
  Future<ChatDailyUsage> readDailyUsage(String chatId) async {
    await _api._loadChatState(chatId);
    final raw = _api._usageByChat[chatId]?['usage'];
    if (raw is! Map) return const ChatDailyUsage();
    final map = Map<String, dynamic>.from(raw);
    return ChatDailyUsage(
      promptTokens: _int(map, 'promptTokens'),
      completionTokens: _int(map, 'completionTokens'),
      costUsd: _double(map['costUsd']) ?? 0,
      requests: _int(map, 'requests'),
    );
  }

  @override
  Future<double?> readDailyBudget(String chatId) async {
    await _api._loadChatState(chatId);
    return _double(_api._usageByChat[chatId]?['budget']);
  }

  @override
  Future<void> saveDailyBudget(String chatId, double? value) async {
    await _api.sendJson(
      'PUT',
      '/chats/$chatId/budget',
      body: {'budget': value},
    );
    _api._usageByChat[chatId] = {
      ...?_api._usageByChat[chatId],
      'budget': value,
    };
  }

  @override
  Future<ChatCompactionInfo?> readCompactionInfo(String chatId) async {
    await _api._loadChatState(chatId);
    final raw = _api._usageByChat[chatId]?['compaction'];
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    return ChatCompactionInfo(
      at: DateTime.parse('${map['at']}').toUtc(),
      reason: '${map['reason'] ?? 'threshold'}',
      cutoffSeq: _int(map, 'cutoffSeq'),
      summaryChars: _int(map, 'summaryChars'),
    );
  }

  @override
  Future<void> setTrusted(
    String hostId,
    String workspace, {
    required bool trusted,
  }) async {
    await _api.sendJson(
      'PUT',
      '/hosts/$hostId/trust',
      body: {'workspace': workspace, 'trusted': trusted},
    );
  }

  @override
  AppLimits cachedLimits() {
    final raw = _api._globalSettings?['limits'];
    if (raw is! Map) return const AppLimits();
    try {
      return AppLimits.fromJson(jsonEncode(Map<String, dynamic>.from(raw)));
    } on FormatException {
      return const AppLimits();
    }
  }

  @override
  List<String> cachedPinnedModels() => [
    for (final id
        in (_api._globalSettings?['pinnedModels'] as List? ?? const []))
      if (id is String) id,
  ];

  @override
  StepsDisplay cachedStepsDisplay() {
    final raw = _api._globalSettings?['steps'];
    return raw is Map
        ? _steps(Map<String, dynamic>.from(raw))
        : StepsDisplay.defaults;
  }

  @override
  @override
  ReasoningPreference cachedReasoning(String key) =>
      ReasoningPreference.parse(cached(key));

  @override
  String? cached(String key) => switch (key) {
    SettingsRepository.keyDefaultModel =>
      _api._globalSettings?['defaultModel'] as String?,
    SettingsRepository.keyDefaultReasoning =>
      _api._globalSettings?['defaultReasoning'] as String?,
    SettingsRepository.keyMemoryReasoning =>
      _api._globalSettings?['memoryReasoning'] as String?,
    SettingsRepository.keySubagentReasoning =>
      _api._globalSettings?['subagentReasoning'] as String?,
    SettingsRepository.keyFallbackReasoning =>
      _api._globalSettings?['fallbackReasoning'] as String?,
    SettingsRepository.keyDefaultPolicy =>
      _api._globalSettings?['defaultPolicy'] as String?,
    _ => null,
  };
}

final class _RemoteProjectStore implements ProjectStore {
  _RemoteProjectStore(this._api);

  final RemoteAgentApi _api;

  @override
  Future<Project?> forChat(String chatId) async {
    await _api._loadChatState(chatId);
    return _api._projectsByChat[chatId];
  }

  @override
  Future<Project?> byId(String id) => Future<Project?>.value();
}

final class _RemoteProjects implements ProjectsStore {
  _RemoteProjects(this._api);

  final RemoteAgentApi _api;

  @override
  Future<Chat> attach(Chat chat) => Future.value(chat);

  @override
  String? configuredWorkspace(Host host) => host.defaultWorkspace;

  @override
  Future<Chat> relocate(
    Chat chat, {
    String? hostId,
    String? workspace,
    bool workspaceSpecified = false,
  }) async {
    if (hostId != null || !workspaceSpecified) return chat;
    Future<Chat> send(int? revision) => _api.chatStore.updateChat(
      chat.id,
      workspace: workspace,
      workspaceSpecified: true,
      expectedRevision: revision,
    );
    try {
      return await send(chat.revision);
    } on AgentApiException catch (error) {
      if (error.code != 'chat_conflict') rethrow;
      final fresh = await _api.chat(chat.id);
      if (fresh == null) rethrow;
      return send(fresh.revision);
    }
  }

  @override
  Future<void> trustWorkspace(String projectId) => Future<void>.value();

  @override
  Future<Project?> find({
    required String hostId,
    required String workspace,
  }) async {
    final query = Uri(
      queryParameters: {'hostId': hostId, 'workspace': workspace},
    ).query;
    final json = await _api._get('/projects/lookup?$query');
    final project = json['project'];
    return project is Map ? _project(Map<String, dynamic>.from(project)) : null;
  }

  @override
  Future<List<WorkspaceEntry>> searchMentions(
    String projectId,
    String query,
  ) async {
    final suffix = Uri(queryParameters: {'q': query}).query;
    final json = await _api._get('/projects/$projectId/mentions?$suffix');
    return [
      for (final item in (json['entries'] as List? ?? const []))
        if (item is Map)
          WorkspaceEntry.fromJson(Map<String, dynamic>.from(item)),
    ];
  }
}

final class _RemoteModels implements ModelStore {
  _RemoteModels(this._api);

  final RemoteAgentApi _api;

  @override
  ModelCatalogState get state => _api._catalog ?? const ModelCatalogState();

  @override
  Stream<ModelCatalogState> watch() async* {
    try {
      if (_api._catalog == null) await _api._loadModels();
    } on Object {
      // Сервер offline: отдаём пустой каталог, обновление придёт после reconnect.
    }
    yield state;
    yield* _api._catalogChanges.stream;
  }

  @override
  Future<void> refresh() => _api.refreshModels();

  @override
  Future<void> remember(List<String> ids) async {
    await _api.sendJson('POST', '/models/remember', body: {'ids': ids});
  }

  @override
  ModelRuntimeState get runtime => _api._runtime ?? const ModelRuntimeState();

  @override
  Stream<ModelRuntimeState> watchRuntime() async* {
    if (_api._runtime == null) await _api._loadRuntime();
    yield runtime;
    yield* _api._runtimeChanges.stream;
  }

  @override
  Future<void> refreshRuntime() async {
    await _api._loadRuntime();
  }

  @override
  Future<void> loadModel(String modelId) async {
    await _api.sendJson(
      'POST',
      '/models/runtime/load',
      body: {'model': modelId},
    );
  }

  @override
  Future<void> unloadModel(String modelId) async {
    await _api.sendJson(
      'POST',
      '/models/runtime/unload',
      body: {'model': modelId},
    );
  }
}

final class _RemoteHosts implements HostStore {
  _RemoteHosts(this._api);

  final RemoteAgentApi _api;

  @override
  Future<List<Host>> all() async {
    try {
      return await _api.hosts();
    } on Object {
      return const [];
    }
  }

  @override
  Stream<List<Host>> watchAll() => _api.watchHosts();
}

final class _RemoteExec implements ExecStore {
  const _RemoteExec();

  @override
  ActiveExec? find(String runId) => null;

  @override
  Future<void> stop(ActiveExec exec, {required bool force}) =>
      Future<void>.value();
}

final class _RemoteInteractions implements InteractionsStore {
  _RemoteInteractions(this._api);

  final RemoteAgentApi _api;

  @override
  Stream<ApprovalRequest> get approvalRequests => _api.approvals;

  @override
  Stream<UserQuestion> get questions => _api.questions;

  @override
  Stream<EditFileChangesRequest> get editFileChangesRequests =>
      _api.editChanges;

  @override
  Stream<InteractionResolution> get resolutions => _api.resolutions;

  @override
  List<ApprovalRequest> pendingApprovals(String chatId) =>
      _api.pendingApprovalsSync(chatId);

  @override
  List<UserQuestion> pendingQuestions(String chatId) =>
      _api.pendingQuestionsSync(chatId);

  @override
  List<EditFileChangesRequest> pendingEditFileChanges(String chatId) =>
      _api.pendingEditFileChangesSync(chatId);

  @override
  void resolveApproval(String requestId, ApprovalDecision decision) {
    unawaited(_api.resolveApproval(requestId, decision.action));
  }

  @override
  void answer(String questionId, String? text) {
    unawaited(_api.answerQuestion(questionId, text));
  }

  @override
  void resolveEditFileChanges(String requestId, EditFileChangesChoice choice) {
    unawaited(_api.resolveEditFileChanges(requestId, choice));
  }
}

final class _RemoteChatSession implements ChatSessionApi {
  _RemoteChatSession(this._api, this._chatId);

  final RemoteAgentApi _api;
  final String _chatId;

  @override
  bool get isRunning => _api.runningChatIds.contains(_chatId);

  @override
  List<QueuedPrompt> get queue => _api._queues[_chatId] ?? const [];

  @override
  int get queueRevision => _api._queueRevisions[_chatId] ?? 0;

  @override
  TurnSnapshot get turnSnapshot =>
      _api._turnSnapshots[_chatId] ?? const TurnSnapshot();

  @override
  Stream<AgentEvent> get events => _api._chatEvents(_chatId);

  @override
  Future<void> submit(
    String text, {
    List<AttachmentRef> attachments = const [],
    List<MentionRef> mentions = const [],
    bool sendNow = false,
    String? clientMessageId,
  }) => _api.send(
    _chatId,
    text,
    sendNow: sendNow,
    attachments: attachments,
    mentions: mentions,
    clientMessageId: clientMessageId,
  );

  @override
  Future<void> stop({String? reason}) => _api.stop(_chatId, reason: reason);

  @override
  Future<void> continueAfterStepLimit() async {
    await _api.sendJson('PUT', '/chats/$_chatId/turn');
  }

  @override
  Future<bool> regenerateLast() async {
    final json = await _api.sendJson('POST', '/chats/$_chatId/regenerations');
    return json is Map && json['accepted'] == true;
  }

  @override
  Future<bool> promoteQueued(
    String itemId, {
    required int expectedRevision,
  }) async {
    var revision = expectedRevision;
    // Две попытки: конфликт означает лишь, что очередь изменилась в другом
    // окне. Действие адресует элемент по id, поэтому повтор на свежей ревизии
    // применяется к тому же промпту, а не к соседнему по позиции.
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await _api.sendJson(
          'PATCH',
          '/chats/$_chatId/queue/${Uri.encodeComponent(itemId)}',
          body: {'position': 0, 'expectedRevision': revision},
        );
        // Без SSE экран не узнает о перестановке: обновляем снимок сразу,
        // чтобы следующее действие не отправилось со старой ревизией.
        await _api._trySyncSession(_chatId);
        return true;
      } on AgentApiException catch (error) {
        if (error.code != 'queue_conflict') rethrow;
        await _api._trySyncSession(_chatId);
        final fresh = _api._queueRevisions[_chatId] ?? revision;
        // Ревизия не сдвинулась — элемента уже нет, повтор не поможет.
        if (fresh == revision) return false;
        revision = fresh;
      }
    }
    return false;
  }

  @override
  Future<QueuedPrompt?> takeQueued(
    String itemId, {
    required int expectedRevision,
  }) async {
    var revision = expectedRevision;
    // Как и promote: одна повторная попытка по тому же id после конфликта.
    for (var attempt = 0; attempt < 2; attempt++) {
      final items = _api._queues[_chatId];
      final index = items?.indexWhere((item) => item.id == itemId) ?? -1;
      if (items == null || index < 0) return null;
      final item = items[index];
      try {
        await _api.sendJson(
          'DELETE',
          '/chats/$_chatId/queue/${Uri.encodeComponent(itemId)}'
              '?expectedRevision=$revision',
        );
        await _api._trySyncSession(_chatId);
        return item;
      } on AgentApiException catch (error) {
        if (error.code != 'queue_conflict') rethrow;
        await _api._trySyncSession(_chatId);
        final fresh = _api._queueRevisions[_chatId] ?? revision;
        if (fresh == revision) return null;
        revision = fresh;
      }
    }
    return null;
  }

  @override
  Future<bool> editUserMessage(
    String messageId,
    String newText, {
    List<AttachmentRef>? attachments,
    List<MentionRef>? mentions,
  }) async {
    final json = await _api.sendJson(
      'PATCH',
      '/chats/$_chatId/messages/$messageId',
      body: {
        'text': newText,
        if (attachments != null)
          'attachments': [
            for (final attachment in attachments) _attachmentBody(attachment),
          ],
        if (mentions != null)
          'mentions': [for (final mention in mentions) mention.toJson()],
      },
    );
    return json is Map && json['accepted'] == true;
  }

  @override
  Future<void> deleteAfter(String messageId) async {
    await _api.sendJson(
      'DELETE',
      '/chats/$_chatId/messages/$messageId/following',
    );
  }

  @override
  Future<void> restoreUnanswered() => _api.openChat(_chatId);

  @override
  Future<void> compactNow({bool force = false}) async {
    await _api.sendJson(
      'POST',
      '/chats/$_chatId/compactions',
      body: {'force': force},
    );
  }
}

/// Файлы локальных моделей через HTTP API демона.
final class _RemoteLocalModels implements LocalModelsSource {
  _RemoteLocalModels(this._api);

  final RemoteAgentApi _api;

  @override
  LocalModelsState get state => _api._localModels ?? const LocalModelsState();

  @override
  Stream<LocalModelsState> watch() => Stream.multi((controller) {
    // Подписка на изменения ставится сразу, до сетевого снимка: иначе
    // прогресс скачивания, пришедший между GET и подпиской, теряется.
    controller.add(state);
    final sub = _api._localModelsChanges.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = sub.cancel;
    unawaited(_api._loadLocalModels());
  });

  @override
  Future<void> refresh() => _api._loadLocalModels();

  /// Совместимый алиас: на клиенте завершение приходит через SSE.
  Future<String> install(String source, {String? name, String? sha256}) =>
      startInstall(source, name: name, sha256: sha256);

  @override
  Future<String> startInstall(
    String source, {
    String? name,
    String? sha256,
  }) async {
    final json = await _api._send(
      'POST',
      '/models/files/install',
      body: {'source': source, 'name': name, 'sha256': sha256},
    );
    await _api._loadLocalModels();
    return json is Map ? '${json['id'] ?? ''}' : '';
  }

  @override
  Future<void> cancelInstall(String id) async {
    await _api._send('POST', '/models/files/cancel', body: {'id': id});
  }

  @override
  Future<String> importPath(String path, {String? name}) async {
    final json = await _api._send(
      'POST',
      '/models/files/import',
      body: {'path': path, 'name': name},
    );
    await _api._loadLocalModels();
    return json is Map ? '${json['id'] ?? ''}' : '';
  }

  @override
  Future<void> delete(String id) async {
    await _api._send('DELETE', '/models/files/$id');
    await _api._loadLocalModels();
  }

  @override
  Future<void> updateSettings(String id, LocalModelSettings settings) async {
    await _api._send(
      'PATCH',
      '/models/files/$id',
      body: {'settings': settings.toJson()},
    );
    await _api._loadLocalModels();
  }

  @override
  Future<void> clearCache() async {
    await _api._send('POST', '/models/files/clear');
    await _api._loadLocalModels();
  }

  @override
  Future<void> saveAutoUnload(int minutes) async {
    await _api._send(
      'PUT',
      '/models/files/auto-unload',
      body: {'minutes': minutes},
    );
    await _api._loadLocalModels();
  }
}

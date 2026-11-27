import 'dart:async';
import 'dart:convert';

import 'package:injectable/injectable.dart';
import 'package:probably_works/app/notifications/profile_notice_bridge.dart';
import 'package:probably_works/app/profiles/agent_profile.dart';
import 'package:probably_works/app/profiles/local_agent_apis.dart';
import 'package:probably_works/core/platform/client_info.dart';
import 'package:probably_works/core/session/session_close_signal.dart';
import 'package:probably_works/core/settings/client_settings.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/agent_settings_api.dart';
import 'package:pw_agent/agent/api/attention_api.dart';
import 'package:pw_agent/agent/api/chat_api.dart';
import 'package:pw_agent/agent/api/client_session_api.dart';
import 'package:pw_agent/agent/api/data_api.dart';
import 'package:pw_agent/agent/api/hosts_api.dart';
import 'package:pw_agent/agent/api/mcp_api.dart';
import 'package:pw_agent/agent/api/plugin_api.dart';
import 'package:pw_agent/agent/api/projects_api.dart';
import 'package:pw_agent/agent/api/push_api.dart';
import 'package:pw_agent/agent/api/security_audit_api.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/logging/app_log.dart';
import 'package:pw_agent/core/notify/app_notifier.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/providers/ai/openrouter/openrouter_llm_provider.dart';
import 'package:pw_client/pw_client.dart';
import 'package:uuid/uuid.dart';

/// Реестр профилей. Активного профиля здесь нет: его задаёт маршрут.
///
/// Экземпляры [AgentApi]/[ChatApi] кэшируются по профилю, чтобы переключение
/// пути не создавало новый HTTP-клиент и SSE-подписку.
@lazySingleton
class ProfileService {
  ProfileService(
    this._settings,
    this._secrets,
    this._local,
    this._clientInfo,
    this._notifier, {
    @ignoreParam this.includeLocal = true,
    @ignoreParam ClientSessionStore? clientSessionStore,
    @ignoreParam ClientSessionChannel? clientSessionChannel,
  }) : _clientSessionStore = clientSessionStore ?? MemoryClientSessionStore(),
       _clientSessionChannel =
           clientSessionChannel ?? const NoopClientSessionChannel();

  static const _uuid = Uuid();

  final ClientSettings _settings;
  final SecretStore _secrets;
  final LocalAgentApisProvider _local;
  final ClientInfo _clientInfo;
  final AppNotifier _notifier;
  final bool includeLocal;

  /// Сессии выдаёт сервер; клиент только хранит id. На web это
  /// `sessionStorage` + `BroadcastChannel`, на остальных платформах — память.
  final ClientSessionStore _clientSessionStore;
  final ClientSessionChannel _clientSessionChannel;

  final _changes = StreamController<void>.broadcast();
  final _remote = <String, RemoteAgentApi>{};
  final _listeners = <String, List<StreamSubscription<Object?>>>{};
  final _tokens = <String, String>{};

  /// Общие запросы присутствия на профиль.
  ///
  /// События приходят пачками, и каждое уведомление иначе отправляло бы свой
  /// `GET /client/sessions`. Один запрос отдаёт снимок всем ожидающим; после
  /// завершения запись удаляется, поэтому следующий показ читает свежий список.
  final _presenceRefreshes = <AgentApi, Future<List<ClientSessionView>>>{};

  var _profiles = <AgentProfile>[];
  var _loaded = false;

  List<AgentProfile> get profiles => List.unmodifiable(_profiles);

  Stream<void> get changes => _changes.stream;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final raw = await _settings.read(ClientSettingsKeys.agentProfiles);
    final storedLocal = await _settings.read(
      ClientSettingsKeys.localAgentProfileId,
    );
    final localId = storedLocal == null || storedLocal.isEmpty
        ? 'p-${_uuid.v4()}'
        : storedLocal;
    if (includeLocal && (storedLocal == null || storedLocal.isEmpty)) {
      await _settings.write(ClientSettingsKeys.localAgentProfileId, localId);
    }
    final locals = <AgentProfile>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          locals.addAll([
            for (final item in decoded)
              if (item is Map)
                _normalizeRemote(
                  AgentProfile.fromJson(Map<String, dynamic>.from(item)),
                ),
          ]);
        }
      } on FormatException {
        // Битый список не должен мешать открытию приложения.
      }
    }
    _profiles = [
      if (includeLocal) AgentProfile.local(localId),
      for (final profile in locals)
        if (!profile.isLocal) profile,
    ];
    for (final profile in _profiles.where((profile) => !profile.isLocal)) {
      var token = await _secrets.read(agentProfileTokenKey(profile.id));
      final oldKey = agentProfileTokenKey('remote-${profile.id}');
      if (token == null || token.isEmpty) {
        final oldToken = await _secrets.read(oldKey);
        if (oldToken != null && oldToken.isNotEmpty) {
          token = oldToken;
          await _secrets.write(agentProfileTokenKey(profile.id), oldToken);
          await _secrets.delete(oldKey);
        }
      }
      _tokens[profile.id] = token ?? '';
    }
    await _persist();
  }

  AgentProfile get localProfile => _profiles.firstWhere((p) => p.isLocal);

  String get localProfileId => localProfile.id;

  AgentProfile _normalizeRemote(AgentProfile profile) {
    if (!profile.id.startsWith('remote-')) return profile;
    return profile.copyWith(id: profile.id.replaceFirst('remote-', ''));
  }

  AgentProfile? byId(String id) =>
      _profiles.where((profile) => profile.id == id).firstOrNull;

  AgentApi agentApiFor(AgentProfile profile) =>
      profile.isLocal ? _local.value.agent : _remoteFor(profile);

  ChatApi chatApiFor(AgentProfile profile) =>
      profile.isLocal ? _local.value.chat : _remoteFor(profile);

  DataApi dataApiFor(AgentProfile profile) =>
      profile.isLocal ? _local.value.data : _remoteFor(profile);

  HostsApi hostsApiFor(AgentProfile profile) =>
      profile.isLocal ? _local.value.hosts : _remoteFor(profile);

  ProjectsApi projectsApiFor(AgentProfile profile) =>
      profile.isLocal ? _local.value.projects : _remoteFor(profile);

  AgentSettingsApi settingsApiFor(AgentProfile profile) =>
      profile.isLocal ? _local.value.settings : _remoteFor(profile);

  McpApi mcpApiFor(AgentProfile profile) =>
      profile.isLocal ? _local.value.mcp : _remoteFor(profile);

  PluginApi pluginApiFor(AgentProfile profile) =>
      profile.isLocal ? _local.value.plugins : _remoteFor(profile);

  SecurityAuditApi securityAuditApiFor(AgentProfile profile) =>
      profile.isLocal ? _local.value.audit : _remoteFor(profile);

  PushApi pushApiFor(AgentProfile profile) =>
      profile.isLocal ? _local.value.push : _remoteFor(profile);

  AgentStatus statusFor(AgentProfile profile) => agentApiFor(profile).status;

  Stream<AgentStatus> statusChangesFor(AgentProfile profile) =>
      agentApiFor(profile).statusChanges;

  Future<AgentProfile> addRemote({
    required String name,
    required Uri baseUri,
    required String token,
  }) async {
    _validateRemote(baseUri);
    final profile = AgentProfile(
      id: 'p-${_uuid.v4()}',
      name: name.trim(),
      kind: AgentProfileKind.remote,
      baseUri: baseUri,
    );
    _profiles = [..._profiles, profile];
    _tokens[profile.id] = token;
    await _secrets.write(agentProfileTokenKey(profile.id), token);
    await _persist();
    _changes.add(null);
    unawaited(agentApiFor(profile).checkConnection());
    return profile;
  }

  Future<void> updateRemote(
    String id, {
    required String name,
    required Uri baseUri,
    String? token,
  }) async {
    _validateRemote(baseUri);
    final index = _profiles.indexWhere((profile) => profile.id == id);
    if (index < 0) return;
    final old = _profiles[index];
    _profiles = [..._profiles]
      ..[index] = AgentProfile(
        id: old.id,
        name: name.trim(),
        kind: AgentProfileKind.remote,
        baseUri: baseUri,
      );
    if (token != null && token.isNotEmpty) {
      _tokens[id] = token;
      await _secrets.write(agentProfileTokenKey(id), token);
    }
    await _disposeRemote(id);
    await _persist();
    _changes.add(null);
  }

  Future<void> removeRemote(String id) async {
    final profile = byId(id);
    if (profile == null || profile.isLocal) return;
    _profiles = [
      for (final item in _profiles)
        if (item.id != id) item,
    ];
    _tokens.remove(id);
    await _secrets.delete(agentProfileTokenKey(id));
    await _disposeRemote(id);
    _clientSessionStore.delete(id);
    await _persist();
    _changes.add(null);
  }

  /// Одноразово переносит секреты GUI в keyring локального демона.
  ///
  /// Нужен при переходе с embedded на daemon-first: до этого ключ OpenRouter
  /// и пароли SSH лежали в FlutterSecureStorage, а демон их не видел.
  Future<void> migrateSecretsToLocalDaemon() async {
    if (_local.modeOrNull != LocalRuntimeMode.localDaemon) return;
    if (await _settings.read(ClientSettingsKeys.daemonSecretsMigrated) == '1') {
      return;
    }
    final apis = _local.value;
    try {
      // Ошибка проверки ключа не должна мешать переносу SSH-секретов.
      try {
        await _migrateApiKey(apis.settings);
      } on Object catch (error) {
        AppLog.root.warning('cannot migrate OpenRouter key to daemon', error);
      }
      await _migrateHostSecrets(apis.hosts);
      await _settings.write(ClientSettingsKeys.daemonSecretsMigrated, '1');
      AppLog.root.info('local GUI secrets migrated to daemon');
    } on Object catch (error) {
      AppLog.root.warning('cannot migrate local GUI secrets to daemon', error);
    }
  }

  Future<void> _migrateApiKey(AgentSettingsApi settings) async {
    final key = await _secrets.read(openRouterKeyName);
    if (key == null || key.isEmpty) return;
    final snapshot = await settings.load();
    final status = snapshot.catalog.providerStatuses[openRouterProviderId];
    if (status?.apiKeySet ?? false) return;
    await settings.saveProviderApiKey(openRouterProviderId, key);
  }

  Future<void> _migrateHostSecrets(HostsApi hostsApi) async {
    final hosts = await hostsApi.hosts();
    for (final host in hosts) {
      final password = await _secrets.read(hostPasswordKey(host.id));
      final passphrase = await _secrets.read(hostPassphraseKey(host.id));
      final privateKey = await _secrets.read(hostPrivateKeyKey(host.id));
      final environment = _decodeEnvironment(
        await _secrets.read(hostEnvironmentKey(host.id)),
      );
      final secret = host.authType == SshAuthType.password
          ? _nonEmpty(password)
          : _nonEmpty(passphrase);
      final privateKeyPem = _nonEmpty(privateKey);
      if (secret == null && privateKeyPem == null && environment == null) {
        continue;
      }
      await hostsApi.saveHost(
        host,
        secret: secret,
        privateKeyPem: privateKeyPem,
        environment: environment,
      );
      AppLog.root.info('migrated local secrets for host ${host.id}');
    }
  }

  static String? _nonEmpty(String? value) =>
      value == null || value.isEmpty ? null : value;

  static Map<String, String>? _decodeEnvironment(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final values = {
        for (final entry in decoded.entries)
          if (entry.value is String) '${entry.key}': entry.value as String,
      };
      return values.isEmpty ? null : values;
    } on FormatException {
      return null;
    }
  }

  /// Включает клиентские уведомления для локального демона.
  void attachLocalNotices() {
    if (_local.modeOrNull != LocalRuntimeMode.localDaemon) return;
    final id = localProfile.id;
    _listeners.putIfAbsent(id, () => _listenNotices(_local.value.agent, id));
  }

  Future<void> dispose() async {
    for (final id in _listeners.keys.toList()) {
      await _disposeRemote(id);
    }
    _presenceRefreshes.clear();
    _remote.clear();
    _clientSessionChannel.close();
    await _changes.close();
  }

  Future<void> _disposeRemote(String id) async {
    for (final subscription in _listeners.remove(id) ?? const []) {
      await subscription.cancel();
    }
    await _remote.remove(id)?.dispose();
  }

  /// Сообщает серверам активных профилей, что вкладка закрывается.
  ///
  /// Вызывается из web `pagehide`. Запросы keepalive, чтобы браузер успел
  /// отправить их после выгрузки. Ошибка не критична: сессию закроет обрыв SSE
  /// или TTL.
  Future<void> markSessionsClosing() async {
    await Future.wait([
      for (final api in _remote.values)
        if (api.sessionId != null) _markSessionClosing(api, api.sessionId!),
    ]);
  }

  Future<void> _markSessionClosing(RemoteAgentApi api, String sessionId) async {
    try {
      await sendSessionClosing(
        baseUri: api.baseUri,
        token: api.token,
        sessionId: sessionId,
        headers: api.clientHeaders,
      );
    } on Object {
      // Вкладка уже уходит: следующий признак жизни или TTL разберётся сам.
    }
  }

  RemoteAgentApi _remoteFor(AgentProfile profile) {
    final existing = _remote[profile.id];
    if (existing != null) return existing;
    final baseUri = profile.baseUri;
    if (baseUri == null) {
      throw StateError('remote profile ${profile.id} has no baseUri');
    }
    final api = RemoteAgentApi(
      baseUri: baseUri,
      token: _tokens[profile.id] ?? '',
      clientHeaders: _clientInfo.headers,
      sessionStore: _clientSessionStore,
      sessionChannel: _clientSessionChannel,
      sessionKey: profile.id,
    )..startEvents();
    _remote[profile.id] = api;
    _listeners[profile.id] = _listenNotices(api, profile.id);
    return api;
  }

  /// Сервер не умеет показывать системные уведомления GUI, поэтому клиент
  /// повторяет их по SSE и потокам карточек удалённого профиля. Локальный
  /// агент уведомляет сам через `ChatSession`, здесь его нет.
  ///
  /// Перед показом проверяется presence: если тот же чат открыт в активной
  /// сессии на другом экране, пользователь уже видит событие. Проверка
  /// запрашивает свежий список, чтобы сначала уведомление не появилось из-за
  /// устаревшего снимка после переключения устройства.
  ///
  /// Там же проверяется отложенный чат: пока действует срок «напомнить
  /// позже», уведомления молчат, а после срока приходит отдельное событие
  /// `attentionDue`.
  List<StreamSubscription<Object?>> _listenNotices(
    AgentApi api,
    String profileId,
  ) => ProfileNoticeBridge(
    api: api,
    notifier: _notifier,
    profileId: profileId,
    isVisible: (chatId) => _chatVisibleInFocusedSession(api, chatId),
    isSnoozed: (chatId) => _chatSnoozed(api, chatId),
  ).listen();

  /// Читает входящие и проверяет, отложен ли чат.
  ///
  /// Снимок входящих небольшой, а уведомления приходят редко. Если сервер не
  /// поддерживает входящие или проверка не прошла, считаем чат неотложенным:
  /// пропустить важное хуже, чем показать лишнее.
  Future<bool> _chatSnoozed(AgentApi api, String chatId) async {
    final Object source = api;
    if (source is! AttentionApi) return false;
    try {
      final snapshot = await source.attention().timeout(
        const Duration(seconds: 2),
      );
      final snooze = snapshot.snoozeOf(chatId);
      return snooze != null && snooze.until.isAfter(DateTime.now());
    } on Object {
      return false;
    }
  }

  Future<bool> _chatVisibleInFocusedSession(AgentApi api, String chatId) async {
    final Object source = api;
    if (source case final ClientSessionApi presence) {
      try {
        // Уведомление не должно ждать медленную сеть: за пару секунд presence
        // либо подтвердит, что чат уже виден, либо покажем уведомление.
        final sessions = await _refreshPresence(
          api,
          presence,
        ).timeout(const Duration(seconds: 2));
        // Фокус этого окна уже проверил `PluginAppNotifier`: presence своего
        // экрана может отставать и скрыть уведомление на этом устройстве зря.
        return isChatVisibleInPresence(sessions, chatId, includeCurrent: false);
      } on Object {
        // Без свежего presence лучше показать лишнее уведомление, чем
        // пропустить запрос подтверждения.
        return false;
      }
    }
    return false;
  }

  /// Читает список присутствия, объединяя одновременные запросы профиля.
  ///
  /// Запись снимается по завершении, поэтому следующий показ после ответа
  /// снова читает сервер, а не опирается на устаревший снимок.
  Future<List<ClientSessionView>> _refreshPresence(
    AgentApi api,
    ClientSessionApi presence,
  ) {
    final existing = _presenceRefreshes[api];
    if (existing != null) return existing;
    final future = presence.refreshClientSessions().whenComplete(
      () => _presenceRefreshes.remove(api),
    );
    _presenceRefreshes[api] = future;
    return future;
  }

  Future<void> _persist() => _settings.write(
    ClientSettingsKeys.agentProfiles,
    jsonEncode([
      for (final profile in _profiles)
        if (!profile.isLocal) profile.toJson(),
    ]),
  );

  static void _validateRemote(Uri uri) {
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw ArgumentError.value(uri, 'baseUri', 'expected http or https');
    }
    if (uri.host.isEmpty) {
      throw ArgumentError.value(uri, 'baseUri', 'host is required');
    }
  }
}

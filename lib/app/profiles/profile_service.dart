import 'dart:async';
import 'dart:convert';

import 'package:injectable/injectable.dart';
import 'package:probably_works/app/profiles/agent_profile.dart';
import 'package:probably_works/core/platform/client_info.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/agent_settings_api.dart';
import 'package:pw_agent/agent/api/chat_api.dart';
import 'package:pw_agent/agent/api/hosts_api.dart';
import 'package:pw_agent/agent/api/mcp_api.dart';
import 'package:pw_agent/agent/api/plugin_api.dart';
import 'package:pw_agent/agent/api/projects_api.dart';
import 'package:pw_agent/agent/api/push_api.dart';
import 'package:pw_agent/agent/api/security_audit_api.dart';

import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/notify/app_notifier.dart';
import 'package:pw_agent/core/security/secret_store.dart';
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
    this._localApi,
    this._localChat,
    this._localHosts,
    this._localProjects,
    this._localSettings,
    this._localMcp,
    this._localPlugins,
    this._localSecurityAudit,
    this._localPush,
    this._clientInfo,
    this._notifier,
  );

  static const _uuid = Uuid();

  final SettingsRepository _settings;
  final SecretStore _secrets;
  final AgentApi _localApi;
  final ChatApi _localChat;
  final HostsApi _localHosts;
  final ProjectsApi _localProjects;
  final AgentSettingsApi _localSettings;
  final McpApi _localMcp;
  final PluginApi _localPlugins;
  final SecurityAuditApi _localSecurityAudit;
  final PushApi _localPush;
  final ClientInfo _clientInfo;
  final AppNotifier _notifier;

  final _changes = StreamController<void>.broadcast();
  final _remote = <String, RemoteAgentApi>{};
  final _listeners = <String, List<StreamSubscription<Object?>>>{};
  final _tokens = <String, String>{};

  var _profiles = <AgentProfile>[AgentProfile.local()];
  var _loaded = false;

  List<AgentProfile> get profiles => List.unmodifiable(_profiles);

  Stream<void> get changes => _changes.stream;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final raw = await _settings.read(agentProfilesKey);
    final storedLocal = await _settings.read(localAgentProfileKey);
    final localId = storedLocal == null || storedLocal.isEmpty
        ? 'p-${_uuid.v4()}'
        : storedLocal;
    if (storedLocal == null || storedLocal.isEmpty) {
      await _settings.write(localAgentProfileKey, localId);
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
      AgentProfile.local(localId),
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
      profile.isLocal ? _localApi : _remoteFor(profile);

  ChatApi chatApiFor(AgentProfile profile) =>
      profile.isLocal ? _localChat : _remoteFor(profile);

  HostsApi hostsApiFor(AgentProfile profile) =>
      profile.isLocal ? _localHosts : _remoteFor(profile);

  ProjectsApi projectsApiFor(AgentProfile profile) =>
      profile.isLocal ? _localProjects : _remoteFor(profile);

  AgentSettingsApi settingsApiFor(AgentProfile profile) =>
      profile.isLocal ? _localSettings : _remoteFor(profile);

  McpApi mcpApiFor(AgentProfile profile) =>
      profile.isLocal ? _localMcp : _remoteFor(profile);

  PluginApi pluginApiFor(AgentProfile profile) =>
      profile.isLocal ? _localPlugins : _remoteFor(profile);

  SecurityAuditApi securityAuditApiFor(AgentProfile profile) =>
      profile.isLocal ? _localSecurityAudit : _remoteFor(profile);

  PushApi pushApiFor(AgentProfile profile) =>
      profile.isLocal ? _localPush : _remoteFor(profile);

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
    await _persist();
    _changes.add(null);
  }

  Future<void> dispose() async {
    for (final id in _listeners.keys.toList()) {
      await _disposeRemote(id);
    }
    _remote.clear();
    await _changes.close();
  }

  Future<void> _disposeRemote(String id) async {
    for (final subscription in _listeners.remove(id) ?? const []) {
      await subscription.cancel();
    }
    await _remote.remove(id)?.dispose();
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
    )..startEvents();
    _remote[profile.id] = api;
    _listeners[profile.id] = _listenNotices(api);
    return api;
  }

  /// Сервер не умеет показывать системные уведомления GUI, поэтому клиент
  /// повторяет их по SSE и потокам карточек удалённого профиля. Локальный
  /// агент уведомляет сам через `ChatSession`, здесь его нет.
  List<StreamSubscription<Object?>> _listenNotices(RemoteAgentApi api) => [
    api.events.listen((event) {
      final kind = switch (event) {
        AgentTurnFinished(end: TurnEnd.completed) =>
          AgentNoticeKind.turnFinished,
        AgentTurnFinished(end: TurnEnd.stepLimit) =>
          AgentNoticeKind.stepLimitReached,
        AgentTurnFinished(end: TurnEnd.failed) => AgentNoticeKind.turnFailed,
        _ => null,
      };
      if (kind != null) unawaited(_notify(api, event.chatId, kind));
    }),
    api.approvals.listen(
      (request) => unawaited(
        _notify(api, request.chatId, AgentNoticeKind.approvalNeeded),
      ),
    ),
    api.questions.listen(
      (question) => unawaited(
        _notify(api, question.chatId, AgentNoticeKind.questionAsked),
      ),
    ),
  ];

  Future<void> _notify(
    RemoteAgentApi api,
    String chatId,
    AgentNoticeKind kind,
  ) async {
    var title = '';
    try {
      title = (await api.chat(chatId))?.title ?? '';
    } on Object {
      // Название не критично: уведомление покажет только действие.
    }
    await _notifier.notify(kind: kind, chatTitle: title);
  }

  Future<void> _persist() => _settings.write(
    agentProfilesKey,
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

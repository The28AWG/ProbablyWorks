import 'dart:async';
import 'dart:convert';

import 'package:injectable/injectable.dart';
import 'package:probably_works/app/profiles/agent_profile.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/chat_api.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
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
  );

  static const _uuid = Uuid();
  static const localProfileId = 'local';

  final SettingsRepository _settings;
  final SecretStore _secrets;
  final AgentApi _localApi;
  final ChatApi _localChat;

  final _changes = StreamController<void>.broadcast();
  final _remote = <String, RemoteAgentApi>{};
  final _tokens = <String, String>{};

  var _profiles = <AgentProfile>[AgentProfile.local()];
  var _loaded = false;

  List<AgentProfile> get profiles => List.unmodifiable(_profiles);

  Stream<void> get changes => _changes.stream;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final raw = await _settings.read(agentProfilesKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          final loaded = [
            for (final item in decoded)
              if (item is Map)
                AgentProfile.fromJson(Map<String, dynamic>.from(item)),
          ];
          if (loaded.isNotEmpty) _profiles = loaded;
        }
      } on FormatException {
        // Битый список не должен мешать открытию приложения.
      }
    }
    if (!_profiles.any((profile) => profile.isLocal)) {
      _profiles.insert(0, AgentProfile.local());
    }
    for (final profile in _profiles.where((profile) => !profile.isLocal)) {
      _tokens[profile.id] =
          await _secrets.read(agentProfileTokenKey(profile.id)) ?? '';
    }
  }

  AgentProfile? byId(String id) =>
      _profiles.where((profile) => profile.id == id).firstOrNull;

  AgentApi agentApiFor(AgentProfile profile) =>
      profile.isLocal ? _localApi : _remoteFor(profile);

  ChatApi chatApiFor(AgentProfile profile) =>
      profile.isLocal ? _localChat : _remoteFor(profile);

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
      id: 'remote-${_uuid.v4()}',
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
    await _remote.remove(id)?.dispose();
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
    await _remote.remove(id)?.dispose();
    await _persist();
    _changes.add(null);
  }

  Future<void> dispose() async {
    for (final api in _remote.values) {
      await api.dispose();
    }
    _remote.clear();
    await _changes.close();
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
    )..startEvents();
    _remote[profile.id] = api;
    return api;
  }

  Future<void> _persist() => _settings.write(
    agentProfilesKey,
    jsonEncode([for (final profile in _profiles) profile.toJson()]),
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

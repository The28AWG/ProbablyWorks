import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/app/profiles/agent_profile.dart';
import 'package:probably_works/app/profiles/local_agent_apis.dart';
import 'package:probably_works/app/profiles/profile_service.dart';
import 'package:probably_works/core/platform/client_info.dart';
import 'package:probably_works/core/settings/client_settings.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/agent_settings_api.dart';
import 'package:pw_agent/agent/api/chat_api.dart';
import 'package:pw_agent/agent/api/hosts_api.dart';
import 'package:pw_agent/agent/api/mcp_api.dart';
import 'package:pw_agent/agent/api/plugin_api.dart';
import 'package:pw_agent/agent/api/projects_api.dart';
import 'package:pw_agent/agent/api/push_api.dart';
import 'package:pw_agent/agent/api/security_audit_api.dart';
import 'package:pw_agent/agent/domain/steps_display.dart';
import 'package:pw_agent/agent/policy/security_profile.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/notify/app_notifier.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';

void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  late MemoryClientSettings clientSettings;
  late MemorySecretStore secrets;

  setUp(() async {
    db = openInMemoryDatabase();
    settings = SettingsRepository(db);
    await settings.preload();
    clientSettings = MemoryClientSettings();
    secrets = MemorySecretStore();
  });

  tearDown(() => db.close());

  ProfileService service() => ProfileService(
    clientSettings,
    secrets,
    (LocalAgentApisProvider()..set(
      LocalAgentApis(
        agent: _FakeAgentApi(),
        chat: _FakeChatApi(),
        hosts: _FakeHostsApi(),
        projects: _FakeProjectsApi(),
        settings: _FakeSettingsApi(),
        mcp: _FakeMcpApi(),
        plugins: _FakePluginApi(),
        audit: _FakeSecurityAuditApi(),
        push: _FakePushApi(),
      ),
    )),
    const ClientInfo.fallback(),
    _FakeNotifier(),
  );

  test('loads local profile and persists remote profiles', () async {
    final first = service();
    await first.load();
    expect(first.profiles.single.isLocal, isTrue);

    final remote = await first.addRemote(
      name: 'Work',
      baseUri: Uri.parse('http://127.0.0.1:7787'),
      token: 'secret-token',
    );
    expect(first.byId(remote.id)?.name, 'Work');
    expect(secrets.values[agentProfileTokenKey(remote.id)], 'secret-token');

    final second = service();
    await second.load();
    expect(
      second.byId(remote.id)?.baseUri?.toString(),
      'http://127.0.0.1:7787',
    );

    await second.removeRemote(remote.id);
    expect(second.byId(remote.id), isNull);
    expect(secrets.values[agentProfileTokenKey(remote.id)], isNull);
  });

  test('migrates GUI secrets to local daemon once', () async {
    final host = Host(
      id: 'h1',
      name: 'server',
      kind: HostKind.ssh,
      authType: SshAuthType.password,
      createdAt: DateTime.utc(2026, 11, 12),
      updatedAt: DateTime.utc(2026, 11, 12),
    );
    final settingsApi = _MigrationSettingsApi();
    final hostsApi = _MigrationHostsApi(host);
    final provider = LocalAgentApisProvider()
      ..set(
        LocalAgentApis(
          agent: _FakeAgentApi(),
          chat: _FakeChatApi(),
          hosts: hostsApi,
          projects: _FakeProjectsApi(),
          settings: settingsApi,
          mcp: _FakeMcpApi(),
          plugins: _FakePluginApi(),
          audit: _FakeSecurityAuditApi(),
          push: _FakePushApi(),
          mode: LocalRuntimeMode.localDaemon,
        ),
      );
    final service = ProfileService(
      clientSettings,
      secrets,
      provider,
      const ClientInfo.fallback(),
      _FakeNotifier(),
    );
    secrets.values[openRouterKeyName] = 'api-key';
    secrets.values[hostPasswordKey('h1')] = 'password';
    secrets.values[hostEnvironmentKey('h1')] = jsonEncode({'TOKEN': 'v'});

    await service.migrateSecretsToLocalDaemon();

    expect(settingsApi.savedKey, 'api-key');
    expect(hostsApi.savedSecret, 'password');
    expect(hostsApi.savedEnvironment, {'TOKEN': 'v'});
    expect(
      clientSettings.values[ClientSettingsKeys.daemonSecretsMigrated],
      '1',
    );

    await service.migrateSecretsToLocalDaemon();
    expect(settingsApi.saves, 1);
    expect(hostsApi.saves, 1);
  });

  test('rejects non-http remote urls', () async {
    final api = service();
    await api.load();

    await expectLater(
      api.addRemote(
        name: 'Bad',
        baseUri: Uri.parse('ftp://example.com'),
        token: 'token',
      ),
      throwsArgumentError,
    );
  });
}

final class _FakeAgentApi implements AgentApi {
  @override
  AgentStatus get status => AgentStatus.online;

  @override
  Stream<AgentStatus> get statusChanges => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('AgentApi is not used in profile tests');
}

final class _FakeChatApi implements ChatApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('ChatApi is not used in profile tests');
}

final class _FakeHostsApi implements HostsApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('HostsApi is not used in profile tests');
}

final class _FakeProjectsApi implements ProjectsApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('ProjectsApi is not used in profile tests');
}

final class _FakeSettingsApi implements AgentSettingsApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('AgentSettingsApi is not used in profile tests');
}

final class _FakeNotifier implements AppNotifier {
  @override
  Future<void> notify({
    required AgentNoticeKind kind,
    required String chatTitle,
    String? detail,
  }) => Future<void>.value();
}

final class _FakeMcpApi implements McpApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('McpApi is not used in profile tests');
}

final class _FakePluginApi implements PluginApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('PluginApi is not used in profile tests');
}

final class _FakeSecurityAuditApi implements SecurityAuditApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('SecurityAuditApi is not used in profile tests');
}

final class _FakePushApi implements PushApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('PushApi is not used in profile tests');
}

final class _MigrationSettingsApi implements AgentSettingsApi {
  String? savedKey;
  var saves = 0;

  @override
  Future<AgentSettingsSnapshot> load() async => AgentSettingsSnapshot(
    defaultModel: 'm',
    titleModel: '',
    subagentModel: '',
    fallbackModel: '',
    defaultPolicy: 'ask',
    denylist: const [],
    securityProfile: const SecurityProfile(),
    limits: const AppLimits(),
    pinnedModels: const [],
    stepsDisplay: const StepsDisplay(),
    apiKeyTail: savedKey == null ? '' : 'tail',
    catalog: const ModelCatalogState(models: []),
  );

  @override
  Future<void> saveApiKey(String key) async {
    saves++;
    savedKey = key;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('not used in migration test');
}

final class _MigrationHostsApi implements HostsApi {
  _MigrationHostsApi(this.host);

  final Host host;
  String? savedSecret;
  Map<String, String>? savedEnvironment;
  var saves = 0;

  @override
  Future<List<Host>> hosts() async => [host];

  @override
  Future<void> saveHost(
    Host host, {
    String? secret,
    String? privateKeyPem,
    Map<String, String>? environment,
  }) async {
    saves++;
    savedSecret = secret;
    savedEnvironment = environment;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('not used in migration test');
}

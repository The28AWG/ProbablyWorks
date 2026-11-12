import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/app/profiles/agent_profile.dart';
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
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/notify/app_notifier.dart';
import 'package:pw_agent/core/security/secret_store.dart';

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
    _FakeAgentApi(),
    _FakeChatApi(),
    _FakeHostsApi(),
    _FakeProjectsApi(),
    _FakeSettingsApi(),
    _FakeMcpApi(),
    _FakePluginApi(),
    _FakeSecurityAuditApi(),
    _FakePushApi(),
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

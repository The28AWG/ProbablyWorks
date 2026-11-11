import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/app/profiles/agent_profile.dart';
import 'package:probably_works/app/profiles/profile_service.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/chat_api.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/security/secret_store.dart';

void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  late MemorySecretStore secrets;

  setUp(() async {
    db = openInMemoryDatabase();
    settings = SettingsRepository(db);
    await settings.preload();
    secrets = MemorySecretStore();
  });

  tearDown(() => db.close());

  ProfileService service() =>
      ProfileService(settings, secrets, _FakeAgentApi(), _FakeChatApi());

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

import 'package:http/http.dart' as http;
import 'package:pw_agent/agent/api/push_api.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/notify/app_notifier.dart';
import 'package:pw_agent/core/notify/push_service.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_server/src/daemon/push_app_notifier.dart';
import 'package:test/test.dart';

final class _FakeClient extends http.BaseClient {
  _FakeClient(this.statusCode);

  final int statusCode;
  final requests = <http.Request>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request as http.Request);
    return http.StreamedResponse(Stream.value(const <int>[]), statusCode);
  }
}

void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  late MemorySecretStore secrets;
  late _FakeClient client;
  late PushService push;

  setUp(() async {
    db = openInMemoryDatabase();
    settings = SettingsRepository(db);
    await settings.preload();
    secrets = MemorySecretStore();
    client = _FakeClient(204);
    push = PushService.withClient(settings, secrets, client);
    await push.save(
      const PushSettings(enabled: true, relayUrl: 'https://relay.test'),
      token: 'relay-token',
    );
  });

  tearDown(() async {
    await db.close();
  });

  test('a shared pause suppresses push delivery', () async {
    final notifier = PushAppNotifier(() => push, isPaused: () => true);

    await notifier.notify(
      kind: AgentNoticeKind.approvalNeeded,
      chatTitle: 'Fix login',
    );

    expect(client.requests, isEmpty);
  });

  test('push is delivered again after the pause ends', () async {
    final notifier = PushAppNotifier(() => push, isPaused: () => false);

    await notifier.notify(kind: AgentNoticeKind.attentionDigest, chatTitle: '');

    expect(client.requests, hasLength(1));
  });
}

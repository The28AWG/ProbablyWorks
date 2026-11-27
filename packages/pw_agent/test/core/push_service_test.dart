import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/push_api.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/state/domain_change_bus.dart';
import 'package:pw_agent/agent/state/shared_state.dart';
import 'package:pw_agent/core/data/chat_repository.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/notify/app_notifier.dart';
import 'package:pw_agent/core/notify/push_service.dart';
import 'package:pw_agent/core/security/secret_store.dart';
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

  setUp(() async {
    db = openInMemoryDatabase();
    settings = SettingsRepository(db);
    await settings.preload();
    secrets = MemorySecretStore();
  });

  tearDown(() async {
    await db.close();
  });

  test('does nothing and rejects test until relay is configured', () async {
    final client = _FakeClient(204);
    final push = PushService.withClient(settings, secrets, client);

    await push.notify(kind: AgentNoticeKind.turnFinished, chatTitle: 'Chat');
    await expectLater(
      push.test(),
      throwsA(
        isA<AgentApiException>().having(
          (error) => error.code,
          'code',
          'push_not_configured',
        ),
      ),
    );
    expect(client.requests, isEmpty);
  });

  test('requires URL and token before enabling push', () async {
    final client = _FakeClient(204);
    final push = PushService.withClient(settings, secrets, client);

    await expectLater(
      push.save(
        const PushSettings(enabled: true, relayUrl: 'https://relay.test'),
      ),
      throwsA(
        isA<AgentApiException>().having(
          (error) => error.code,
          'code',
          'push_token_required',
        ),
      ),
    );

    await push.save(
      const PushSettings(enabled: true, relayUrl: 'https://relay.test'),
      token: 'relay-token',
    );
    final loaded = await push.load();
    expect(loaded.configured, isTrue);
    expect(loaded.hasToken, isTrue);
  });

  test('sends notification metadata to the configured relay', () async {
    final client = _FakeClient(204);
    final push = PushService.withClient(settings, secrets, client);
    await push.save(
      const PushSettings(enabled: true, relayUrl: 'https://relay.test'),
      token: 'relay-token',
    );

    await push.notify(
      kind: AgentNoticeKind.approvalNeeded,
      chatTitle: 'Fix login',
    );
    await push.test();

    expect(client.requests, hasLength(2));
    final request = client.requests.first;
    expect(request.url.toString(), 'https://relay.test');
    expect(request.headers['Authorization'], 'Bearer relay-token');
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    expect(body['event'], 'approvalNeeded');
    expect(body['title'], 'Fix login');
  });

  test('sends grouping metadata and the stable notice id', () async {
    final client = _FakeClient(204);
    final push = PushService.withClient(settings, secrets, client);
    await push.save(
      const PushSettings(enabled: true, relayUrl: 'https://relay.test'),
      token: 'relay-token',
    );

    await push.notify(
      kind: AgentNoticeKind.questionAsked,
      chatTitle: 'Fix login',
      profileId: 'p1',
      chatId: 'c1',
      questionId: 'q1',
      noticeId: 'p1:questionAsked:q1',
    );

    final body =
        jsonDecode(client.requests.single.body) as Map<String, dynamic>;
    expect(body['event'], 'questionAsked');
    expect(body['noticeId'], 'p1:questionAsked:q1');
    expect(body['questionId'], 'q1');
    expect(body['answerId'], 'inline:q1');
    expect(body['groupKey'], 'p1:questionAsked:c1');
    expect(body['collapseKey'], 'p1:questionAsked:q1');
    expect(body['priority'], 'high');
    expect(body['actions'], ['reply', 'open']);
    expect(body['replyInput'], isTrue);
    expect(body['ttlSeconds'], 3600);
  });

  test('cancel addresses the notification by notice id', () async {
    final client = _FakeClient(204);
    final push = PushService.withClient(settings, secrets, client);
    await push.save(
      const PushSettings(enabled: true, relayUrl: 'https://relay.test'),
      token: 'relay-token',
    );

    await push.cancel('p1:approvalNeeded:a1', profileId: 'p1');

    final body =
        jsonDecode(client.requests.single.body) as Map<String, dynamic>;
    expect(body['event'], 'cancel');
    expect(body['noticeId'], 'p1:approvalNeeded:a1');
    expect(body['profileId'], 'p1');
  });

  test('cancel is silent when push is not configured', () async {
    final client = _FakeClient(204);
    final push = PushService.withClient(settings, secrets, client);

    await push.cancel('p1:approvalNeeded:a1');

    expect(client.requests, isEmpty);
  });

  test('versions push settings and publishes the change', () async {
    final changes = DomainChangeBus();
    addTearDown(changes.close);
    final published = <SharedResource>[];
    final sub = changes.changes.listen(published.add);
    addTearDown(sub.cancel);
    final push = PushService.withClient(
      settings,
      secrets,
      _FakeClient(204),
      changes,
    );

    await push.save(
      const PushSettings(enabled: true, relayUrl: 'https://relay.test'),
      token: 'relay-token',
    );
    final first = await push.load();
    expect(first.revision, 1);
    expect(published, [SharedResource.push]);

    await expectLater(
      push.save(
        const PushSettings(enabled: false, relayUrl: ''),
        expectedRevision: 0,
      ),
      throwsA(
        isA<AgentApiException>().having(
          (error) => error.code,
          'code',
          'push_conflict',
        ),
      ),
    );

    await push.save(
      const PushSettings(enabled: false, relayUrl: ''),
      expectedRevision: first.revision,
    );
    expect((await push.load()).revision, 2);
    expect(published, [SharedResource.push, SharedResource.push]);
  });

  test('concurrent saves with one revision are serialized', () async {
    final push = PushService.withClient(settings, secrets, _FakeClient(204));
    await push.save(
      const PushSettings(enabled: true, relayUrl: 'https://relay.test'),
      token: 'relay-token',
    );
    expect((await push.load()).revision, 1);

    var saved = 0;
    var conflicts = 0;
    Future<void> save(PushSettings value) async {
      try {
        await push.save(value, expectedRevision: 1);
        saved++;
      } on AgentApiException catch (error) {
        expect(error.code, 'push_conflict');
        conflicts++;
      }
    }

    // Оба запроса основаны на ревизии 1. Транзакция не пускает второй между
    // проверкой и записью первого, иначе оба прошли бы проверку молча.
    await Future.wait([
      save(const PushSettings(enabled: false, relayUrl: '')),
      save(const PushSettings(enabled: false, relayUrl: '')),
    ]);

    expect(saved, 1);
    expect(conflicts, 1);
    expect((await push.load()).revision, 2);
  });

  test('rejects malformed relay URLs', () async {
    final client = _FakeClient(204);
    final push = PushService.withClient(settings, secrets, client);

    await expectLater(
      push.save(
        const PushSettings(enabled: true, relayUrl: 'ftp://relay.test'),
        token: 'token',
      ),
      throwsA(
        isA<AgentApiException>().having(
          (error) => error.code,
          'code',
          'bad_push_url',
        ),
      ),
    );
  });

  test('includes the server unread total in the push payload', () async {
    final now = DateTime.utc(2026, 11, 28, 12);
    final chats = ChatRepository(db);
    await HostRepository(db, MemorySecretStore()).ensureLocalHost(now);
    await chats.saveChat(
      Chat(
        id: 'c1',
        hostId: 'local',
        title: 'Chat',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await chats.insertMessage(
      ChatMessage(
        id: 'm1',
        chatId: 'c1',
        seq: 1,
        role: MessageRole.assistant,
        text: 'готово',
        createdAt: now,
      ),
    );

    expect(await chats.unreadTotal(), 1);
    final client = _FakeClient(204);
    final push = PushService.withClient(settings, secrets, client, null, chats);
    await push.save(
      const PushSettings(enabled: true, relayUrl: 'https://relay.test'),
      token: 'relay-token',
    );
    await push.notify(
      kind: AgentNoticeKind.turnFinished,
      chatTitle: 'Chat',
      chatId: 'c1',
    );

    final body =
        jsonDecode(client.requests.single.body) as Map<String, dynamic>;
    // Устройство-получатель ставит на иконку то же число, что видят окна.
    expect(body['badge'], 1);
  });
}

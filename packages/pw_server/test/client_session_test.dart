import 'package:pw_server/pw_server.dart';
import 'package:test/test.dart';

void main() {
  const info = ClientSessionInfo(
    deviceId: 'device-a',
    app: 'ProbablyWorks',
    package: 'probably_works',
    version: '1.0.0',
    build: '1',
    platform: 'linux',
  );
  const otherInfo = ClientSessionInfo(
    deviceId: 'device-b',
    app: 'ProbablyWorks',
    package: 'probably_works',
    version: '1.0.0',
    build: '1',
    platform: 'android',
  );

  late DateTime now;
  late ClientSessionRegistry registry;

  setUp(() {
    now = DateTime.utc(2026, 11, 24, 12);
    registry = ClientSessionRegistry(
      ttl: const Duration(seconds: 60),
      sweepInterval: const Duration(hours: 1),
      now: () => now,
    );
  });

  tearDown(() => registry.dispose());

  test('creates a session and returns the same one by previous id', () {
    final first = registry.handshake(info: info);
    expect(first.deviceId, 'device-a');
    expect(first.expiresAt, now.add(const Duration(seconds: 60)));

    now = now.add(const Duration(seconds: 10));
    final second = registry.handshake(
      info: otherInfo,
      previousSessionId: first.id,
    );

    expect(second.id, first.id);
    expect(second.deviceId, 'device-b');
    expect(second.lastSeenAt, now);
  });

  test('two handshakes are two sessions with the same device id', () {
    final first = registry.handshake(info: info);
    final second = registry.handshake(info: info);

    expect(second.id, isNot(first.id));
    expect(second.deviceId, first.deviceId);
  });

  test('expires and removes sessions after ttl', () {
    final session = registry.handshake(info: info);
    now = now.add(const Duration(seconds: 61));

    final lookup = registry.touch(session.id);
    expect(lookup.session, isNull);
    expect(lookup.problem, ClientSessionProblem.expired);
    expect(registry.list(), isEmpty);
  });

  test('reports a missing session', () {
    expect(registry.touch('missing').problem, ClientSessionProblem.missing);
  });

  test('updates presence and lists all sessions', () {
    final first = registry.handshake(info: info);
    final second = registry.handshake(info: otherInfo);

    final updated = registry.updatePresence(
      first.id,
      focused: true,
      activeChatId: 'c1',
    );
    expect(updated?.focused, isTrue);
    expect(updated?.activeChatId, 'c1');

    final sessions = registry.list();
    expect(
      sessions.map((session) => session.id),
      containsAll([first.id, second.id]),
    );
    expect(sessions, hasLength(2));
  });

  test('reports a focused chat and publishes presence changes', () async {
    final session = registry.handshake(info: info);
    final changes = <void>[];
    final sub = registry.changes.listen(changes.add);
    addTearDown(sub.cancel);

    expect(registry.hasFocusedChat('c1'), isFalse);
    registry.updatePresence(session.id, focused: true, activeChatId: 'c1');
    await Future<void>.delayed(Duration.zero);

    expect(registry.hasFocusedChat('c1'), isTrue);
    expect(registry.hasFocusedChat('c2'), isFalse);
    expect(changes, isNotEmpty);
  });

  test('sweep removes expired sessions', () {
    final session = registry.handshake(info: info);
    now = now.add(const Duration(seconds: 61));

    registry.sweep();

    expect(registry.byId(session.id), isNull);
  });

  test('remove closes the session', () {
    final session = registry.handshake(info: info);

    expect(registry.remove(session.id), isNotNull);
    expect(registry.byId(session.id), isNull);
    expect(registry.remove(session.id), isNull);
  });
}

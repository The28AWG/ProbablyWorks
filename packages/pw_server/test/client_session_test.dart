import 'dart:io';

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

  test('keeps a session alive while its SSE connection is open', () {
    final session = registry.handshake(info: info);
    now = now.add(const Duration(seconds: 50));

    registry.keepAlive(session.id);

    expect(registry.byId(session.id)?.lastSeenAt, now);
    now = now.add(const Duration(seconds: 50));
    expect(registry.list(), hasLength(1));
  });

  test('closing removes the session unless it is touched', () {
    final session = registry.handshake(info: info);
    registry.markClosing(session.id, grace: const Duration(seconds: 5));

    now = now.add(const Duration(seconds: 3));
    registry.touch(session.id);
    now = now.add(const Duration(seconds: 4));
    registry.sweep();

    expect(registry.byId(session.id), isNotNull);

    registry.markClosing(session.id, grace: const Duration(seconds: 5));
    now = now.add(const Duration(seconds: 6));
    registry.sweep();

    expect(registry.byId(session.id), isNull);
  });

  test('an SSE ping does not cancel a closing signal', () {
    final session = registry.handshake(info: info);
    registry.markClosing(session.id, grace: const Duration(seconds: 5));

    now = now.add(const Duration(seconds: 3));
    registry.keepAlive(session.id);
    now = now.add(const Duration(seconds: 3));
    registry.sweep();

    expect(registry.byId(session.id), isNull);
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

  test('unchanged presence does not publish another change', () async {
    final session = registry.handshake(info: info);
    final changes = <void>[];
    final sub = registry.changes.listen(changes.add);
    addTearDown(sub.cancel);

    registry.updatePresence(session.id, focused: true, activeChatId: 'c1');
    await Future<void>.delayed(Duration.zero);
    final afterFirst = changes.length;

    registry.updatePresence(session.id, focused: true, activeChatId: 'c1');
    await Future<void>.delayed(Duration.zero);

    expect(changes.length, afterFirst);
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

  test('the last SSE detach schedules closing', () {
    final session = registry.handshake(info: info);
    final response = _FakeResponse();

    registry
      ..attach(session.id, response)
      ..detach(session.id, response);
    now = now.add(const Duration(seconds: 6));
    registry.sweep();

    expect(registry.byId(session.id), isNull);
  });
}

final class _FakeResponse implements HttpResponse {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('HttpResponse is not used in this test');
}

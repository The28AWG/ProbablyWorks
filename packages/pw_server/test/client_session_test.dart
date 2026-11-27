import 'dart:io';

import 'package:pw_server/pw_server.dart';
import 'package:test/test.dart';

void main() {
  const info = ClientSessionInfo(
    deviceId: 'device-a',
    clientId: 'client-a',
    app: 'ProbablyWorks',
    package: 'probably_works',
    version: '1.0.0',
    build: '1',
    platform: 'linux',
  );
  const otherInfo = ClientSessionInfo(
    deviceId: 'device-b',
    clientId: 'client-b',
    app: 'ProbablyWorks',
    package: 'probably_works',
    version: '1.0.0',
    build: '1',
    platform: 'android',
  );
  const updatedInfo = ClientSessionInfo(
    deviceId: 'device-a2',
    clientId: 'client-a',
    app: 'ProbablyWorks',
    package: 'probably_works',
    version: '2.0.0',
    build: '2',
    platform: 'linux',
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

  test('creates a session and resumes it by id and secret', () {
    final first = registry.handshake(info: info);
    expect(first.deviceId, 'device-a');
    expect(first.clientId, 'client-a');
    expect(first.resumeSecret, isNotEmpty);
    expect(first.resumeSecret, isNot(first.id));
    expect(first.expiresAt, now.add(const Duration(seconds: 60)));

    now = now.add(const Duration(seconds: 10));
    final second = registry.handshake(
      info: updatedInfo,
      previousSessionId: first.id,
      previousSessionSecret: first.resumeSecret,
    );

    expect(second.id, first.id);
    expect(second.deviceId, 'device-a2');
    expect(second.clientId, 'client-a');
    expect(second.clientVersion, '2.0.0');
    expect(second.lastSeenAt, now);
  });

  test('does not resume a session without its secret', () {
    final first = registry.handshake(info: info);

    final second = registry.handshake(info: info, previousSessionId: first.id);

    expect(second.id, isNot(first.id));
    // Чужая живая сессия не удалена: без секрета её просто не переиспользуют.
    expect(registry.byId(first.id), isNotNull);
  });

  test('does not resume a session from another client id', () {
    final first = registry.handshake(info: info);

    final second = registry.handshake(
      info: otherInfo,
      previousSessionId: first.id,
      previousSessionSecret: first.resumeSecret,
    );

    expect(second.id, isNot(first.id));
    expect(registry.byId(first.id), isNotNull);
  });

  test('two handshakes are two sessions with the same device id', () {
    final first = registry.handshake(info: info);
    final second = registry.handshake(info: info);

    expect(second.id, isNot(first.id));
    expect(second.deviceId, first.deviceId);
    expect(second.clientId, first.clientId);
    expect(second.resumeSecret, isNot(first.resumeSecret));
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

  test('reports a visible chat and publishes presence changes', () async {
    final session = registry.handshake(info: info);
    final changes = <void>[];
    final sub = registry.changes.listen(changes.add);
    addTearDown(sub.cancel);

    expect(registry.hasVisibleChat('c1'), isFalse);
    registry.updatePresence(session.id, focused: true, activeChatId: 'c1');
    await Future<void>.delayed(Duration.zero);

    expect(registry.hasVisibleChat('c1'), isTrue);
    expect(registry.hasVisibleChat('c2'), isFalse);
    expect(changes, isNotEmpty);
  });

  test('an idle window stops suppressing notifications', () {
    // Долгий TTL: проверяем именно idle-детект, а не истечение сессии.
    final longLived = ClientSessionRegistry(
      ttl: const Duration(minutes: 30),
      sweepInterval: const Duration(hours: 1),
      now: () => now,
    );
    addTearDown(longLived.dispose);
    final session = longLived.handshake(info: info);
    longLived.updatePresence(
      session.id,
      focused: true,
      activeChatId: 'c1',
      visibility: 'foreground',
      visibilitySpecified: true,
      lastInteractionAt: now,
      interactionSpecified: true,
    );

    expect(longLived.hasVisibleChat('c1'), isTrue);

    // Окно осталось в фокусе, но пользователь давно не взаимодействовал:
    // сервер не считает его присутствием, хотя heartbeat продлевает сессию.
    now = now.add(const Duration(minutes: 6));
    longLived.touch(session.id);

    expect(longLived.hasVisibleChat('c1'), isFalse);
    expect(longLived.isPresent(session, now), isFalse);
    // Уведомление всё равно адресуется одному устройству, а не всем.
    expect(longLived.attentionDeviceKeyAt(now), 'client-a');
  });

  test('a chat scrolled away from the end does not suppress notifications', () {
    final session = registry.handshake(info: info);
    registry.updatePresence(
      session.id,
      focused: true,
      activeChatId: 'c1',
      activeChatAtEnd: false,
    );

    expect(registry.hasVisibleChat('c1'), isFalse);
  });

  test('the most recent interaction selects the attention device', () {
    final desktop = registry.handshake(info: info);
    final phone = registry.handshake(info: otherInfo);
    registry
      ..updatePresence(
        desktop.id,
        focused: true,
        visibility: 'foreground',
        visibilitySpecified: true,
        lastInteractionAt: now.subtract(const Duration(minutes: 3)),
        interactionSpecified: true,
        activeChatId: 'c1',
      )
      ..updatePresence(
        phone.id,
        focused: true,
        visibility: 'foreground',
        visibilitySpecified: true,
        lastInteractionAt: now.subtract(const Duration(seconds: 5)),
        interactionSpecified: true,
        activeChatId: 'c1',
      );

    expect(registry.isPresent(desktop, now), isTrue);
    expect(registry.isPresent(phone, now), isTrue);
    expect(registry.attentionDeviceKeyAt(now), 'client-b');
    // Оба устройства видят один чат, но на телефоне пользователь активен:
    // push не нужен ни на одно из них.
    expect(registry.hasVisibleChat('c1'), isTrue);
  });

  test('a background window does not make its device present', () {
    final focused = registry.handshake(info: info);
    final background = registry.handshake(info: info);
    registry
      ..updatePresence(
        focused.id,
        visibility: 'foreground',
        visibilitySpecified: true,
        lastInteractionAt: now,
        interactionSpecified: true,
      )
      ..updatePresence(
        background.id,
        visibility: 'background',
        visibilitySpecified: true,
        lastInteractionAt: now,
        interactionSpecified: true,
      );

    expect(registry.isPresent(focused, now), isTrue);
    expect(registry.isPresent(background, now), isFalse);
    // Устройство считается активным, пока активен хотя бы один его экран.
    expect(registry.attentionDeviceKeyAt(now), 'client-a');
  });

  test('sweep moves attention when the active device goes idle', () async {
    final longLived = ClientSessionRegistry(
      ttl: const Duration(minutes: 30),
      sweepInterval: const Duration(hours: 1),
      now: () => now,
    );
    addTearDown(longLived.dispose);
    final desktop = longLived.handshake(info: info);
    final phone = longLived.handshake(info: otherInfo);
    longLived
      ..updatePresence(
        desktop.id,
        focused: true,
        visibility: 'foreground',
        visibilitySpecified: true,
        lastInteractionAt: now,
        interactionSpecified: true,
      )
      ..updatePresence(
        phone.id,
        focused: false,
        visibility: 'background',
        visibilitySpecified: true,
        lastInteractionAt: now.subtract(const Duration(minutes: 1)),
        interactionSpecified: true,
      );
    expect(longLived.isPresent(desktop, now), isTrue);
    expect(longLived.isPresent(phone, now), isFalse);

    final changes = <void>[];
    final sub = longLived.changes.listen(changes.add);
    addTearDown(sub.cancel);

    // Пользователь ушёл, heartbeat продолжает идти, но взаимодействия нет.
    now = now.add(const Duration(minutes: 6));
    longLived.touch(desktop.id);
    now = now.add(const Duration(seconds: 10));
    longLived
      ..touch(phone.id)
      ..sweep();
    await Future<void>.delayed(Duration.zero);

    expect(longLived.isPresent(desktop, now), isFalse);
    expect(longLived.attentionDeviceKeyAt(now), 'client-b');
    // Смена адресата — повод пересмотреть отложенные карточки на телефоне.
    expect(changes, isNotEmpty);
  });

  test(
    'sweep ignores heartbeat reordering while all screens are idle',
    () async {
      final longLived = ClientSessionRegistry(
        ttl: const Duration(minutes: 30),
        sweepInterval: const Duration(hours: 1),
        now: () => now,
      );
      addTearDown(longLived.dispose);
      final desktop = longLived.handshake(info: info);
      final phone = longLived.handshake(info: otherInfo);
      longLived
        ..updatePresence(
          desktop.id,
          visibility: 'background',
          visibilitySpecified: true,
          lastInteractionAt: now.subtract(const Duration(minutes: 2)),
          interactionSpecified: true,
        )
        ..updatePresence(
          phone.id,
          visibility: 'background',
          visibilitySpecified: true,
          lastInteractionAt: now.subtract(const Duration(minutes: 3)),
          interactionSpecified: true,
        );

      final changes = <void>[];
      final sub = longLived.changes.listen(changes.add);
      addTearDown(sub.cancel);

      // Оба экрана в фоне, heartbeat переставляет их по lastSeenAt. Набор
      // активных сессий не меняется, поэтому снимок рассылать незачем.
      now = now.add(const Duration(seconds: 10));
      longLived
        ..touch(desktop.id)
        ..sweep();
      await Future<void>.delayed(Duration.zero);

      expect(changes, isEmpty);
    },
  );

  test('a background device yields to the most recent session', () {
    final desktop = registry.handshake(info: info);
    final phone = registry.handshake(info: otherInfo);
    registry.updatePresence(
      desktop.id,
      focused: true,
      visibility: 'background',
      visibilitySpecified: true,
      lastInteractionAt: now.subtract(const Duration(minutes: 1)),
      interactionSpecified: true,
    );
    now = now.add(const Duration(seconds: 10));
    registry.updatePresence(
      phone.id,
      focused: false,
      visibility: 'background',
      visibilitySpecified: true,
      lastInteractionAt: now.subtract(const Duration(minutes: 2)),
      interactionSpecified: true,
    );

    expect(registry.isPresent(desktop, now), isFalse);
    expect(registry.isPresent(phone, now), isFalse);
    // Оба в фоне: уведомление получает самое свежее устройство, а не оба.
    expect(registry.attentionDeviceKeyAt(now), 'client-b');
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

  test(
    'applies presence by increasing revision and ignores stale updates',
    () async {
      final session = registry.handshake(info: info);
      final changes = <void>[];
      final sub = registry.changes.listen(changes.add);
      addTearDown(sub.cancel);

      registry.updatePresence(
        session.id,
        focused: true,
        activeChatId: 'a',
        revision: 2,
      );
      await Future<void>.delayed(Duration.zero);
      expect(changes, hasLength(1));

      // Более новый запрос пришёл раньше: старый не должен откатить состояние
      // и не должен рассылать событие присутствия.
      registry.updatePresence(
        session.id,
        focused: false,
        activeChatId: null,
        revision: 1,
      );
      await Future<void>.delayed(Duration.zero);
      expect(changes.length, 1);
      expect(session.focused, isTrue);
      expect(session.activeChatId, 'a');
      expect(session.presenceRevision, 2);

      registry.updatePresence(
        session.id,
        focused: false,
        activeChatId: null,
        revision: 3,
      );
      await Future<void>.delayed(Duration.zero);
      expect(changes, hasLength(2));
      expect(session.focused, isFalse);
      expect(session.activeChatId, isNull);
      expect(session.presenceRevision, 3);
    },
  );

  test('a stale presence revision still keeps the session alive', () {
    final session = registry.handshake(info: info);

    registry.updatePresence(session.id, focused: true, revision: 5);
    now = now.add(const Duration(seconds: 50));
    registry.updatePresence(session.id, focused: false, revision: 4);

    expect(session.focused, isTrue);
    expect(session.lastSeenAt, now);
  });

  test('a reload keeps the presence revision of the reused session', () {
    final first = registry.handshake(info: info);
    registry.updatePresence(first.id, focused: true, revision: 7);

    final second = registry.handshake(
      info: info,
      previousSessionId: first.id,
      previousSessionSecret: first.resumeSecret,
    );

    expect(second.id, first.id);
    expect(second.presenceRevision, 7);
    // Следующая ревизия после reload продолжает нумерацию, а не начинает с 1.
    registry.updatePresence(second.id, focused: false, revision: 8);
    expect(second.focused, isFalse);
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

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:pw_server/src/api/api_token.dart';

/// Описание клиента, которое сервер получил из заголовков `X-Client-*`.
///
/// [deviceId] — устройство в модели: одинаковый `deviceId` и разные
/// `sessionId` означают одно устройство с несколькими подключениями. Это не
/// глобальный уникальный идентификатор: после обновления приложения отпечаток
/// меняется, а у двух одинаково описанных машин он может совпасть. Для доступа
/// и отзыва устройств он не годится.
final class ClientSessionInfo {
  const ClientSessionInfo({
    required this.deviceId,
    required this.app,
    required this.package,
    required this.version,
    required this.build,
    required this.platform,
  });

  /// Отпечаток `X-Client-*`, а не уникальный id устройства.
  final String deviceId;

  /// Название приложения из `X-Client-App`.
  final String app;

  /// Имя пакета из `X-Client-Package`.
  final String package;

  /// Версия приложения из `X-Client-Version`.
  final String version;

  /// Номер сборки из `X-Client-Build`.
  final String build;

  /// Платформа из `X-Client-Platform`.
  final String platform;
}

/// Временная клиентская сессия. Живёт только в памяти процесса.
///
/// Это представление клиента, а не пользователь. В текущем single-user
/// демоне один API-токен; сессии не делят пользователей и не привязаны к
/// fingerprint токена.
final class ClientSession {
  /// Создаёт запись сессии; id и срок выбирает реестр.
  ClientSession({
    required this.id,
    required ClientSessionInfo info,
    required this.createdAt,
    required this.lastSeenAt,
    required this.ttl,
  }) : deviceId = info.deviceId,
       clientApp = info.app,
       clientPackage = info.package,
       clientVersion = info.version,
       clientBuild = info.build,
       clientPlatform = info.platform;

  /// Непрозрачный id, выданный сервером.
  final String id;

  /// Когда сессия создана.
  final DateTime createdAt;

  /// Время жизни после последнего обращения.
  final Duration ttl;

  /// Отпечаток `X-Client-*`, а не уникальный id устройства.
  String deviceId;
  String clientApp;
  String clientPackage;
  String clientVersion;
  String clientBuild;
  String clientPlatform;

  /// SSE-соединения этой сессии. Нужны, чтобы `DELETE /client/session`
  /// и истечение TTL закрывали поток, а не оставляли его висеть.
  final Set<HttpResponse> sseConnections = {};

  /// Последнее обращение клиента; от него считается TTL.
  DateTime lastSeenAt;

  /// Момент, после которого сессия считается истёкшей.
  DateTime get expiresAt => lastSeenAt.add(ttl);

  /// Истекла ли сессия к моменту [now].
  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);

  /// Продлевает сессию до [now] + [ttl].
  void touch(DateTime now) {
    lastSeenAt = now;
  }

  /// Обновляет описание клиента при повторном рукопожатии.
  ///
  /// Версия и платформа могли измениться после обновления приложения, а
  /// сессия остаться прежней. Это нормально: сессия — это представление,
  /// а не версия сборки.
  void updateInfo(ClientSessionInfo info) {
    deviceId = info.deviceId;
    clientApp = info.app;
    clientPackage = info.package;
    clientVersion = info.version;
    clientBuild = info.build;
    clientPlatform = info.platform;
  }

  /// Запоминает фокус приложения и открытый чат для присутствия.
  ///
  /// [focused] и [activeChatId] необязательны: heartbeat может прислать только
  /// изменившуюся часть, не сбрасывая вторую.
  void updatePresence({
    bool? focused,
    String? activeChatId,
    bool activeChatIdSpecified = true,
  }) {
    if (focused != null) this.focused = focused;
    if (activeChatIdSpecified) this.activeChatId = activeChatId;
  }

  /// Находится ли приложение в фокусе на этом клиенте.
  bool focused = false;

  /// Чат, открытый на этом клиенте, если он сообщил его в heartbeat.
  String? activeChatId;
}

/// Причина, по которой сессия не подошла.
enum ClientSessionProblem { missing, expired }

/// Результат проверки сессии.
final class ClientSessionLookup {
  const ClientSessionLookup.session(this.session) : problem = null;

  const ClientSessionLookup.failure(this.problem) : session = null;

  /// Найденная сессия или null при ошибке.
  final ClientSession? session;

  /// Причина ошибки или null, если сессия подошла.
  final ClientSessionProblem? problem;
}

/// Реестр клиентских сессий.
///
/// Хранит только runtime-состояние: после перезапуска сервера сессии исчезают,
/// и клиенты проходят рукопожатие заново. TTL и heartbeat не дают списку
/// «онлайн» превратиться в список когда-то запущенных клиентов.
final class ClientSessionRegistry {
  /// [now] подменяется в тестах, чтобы не ждать настоящий TTL.
  ClientSessionRegistry({
    this.ttl = const Duration(seconds: 60),
    this.sweepInterval = const Duration(seconds: 10),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _sweepTimer = Timer.periodic(sweepInterval, (_) => sweep());
  }

  /// Время жизни сессии после последнего обращения.
  final Duration ttl;

  /// Как часто удалять истёкшие сессии.
  final Duration sweepInterval;

  final DateTime Function() _now;
  final Map<String, ClientSession> _sessions = {};
  Timer? _sweepTimer;
  final _changes = StreamController<void>.broadcast();

  /// События изменения состава сессий или присутствия. Сами данные читаются
  /// через [list], чтобы подписчик не держал устаревший снимок.
  Stream<void> get changes => _changes.stream;

  /// Текущее время реестра; в тестах управляется снаружи.
  DateTime get now => _now();

  /// Сервер сам выбирает интервал heartbeat, клиент не зашивает его в код.
  Duration get heartbeatInterval {
    final millis = ttl.inMilliseconds ~/ 3;
    return Duration(milliseconds: max(1000, min(30000, millis)));
  }

  /// Создаёт сессию или переиспользует [previousSessionId], если она жива.
  ///
  /// [previousSessionId] — подсказка для непрерывности после reload, а не
  /// доказательство. Запрос уже авторизован Bearer-токеном сервера; если
  /// старой сессии нет, будет создана новая.
  ClientSession handshake({
    required ClientSessionInfo info,
    String? previousSessionId,
  }) {
    final at = now;
    if (previousSessionId != null && previousSessionId.isNotEmpty) {
      final previous = _sessions[previousSessionId];
      if (previous != null) {
        if (!previous.isExpiredAt(at)) {
          previous
            ..updateInfo(info)
            ..touch(at);
          _notify();
          return previous;
        }
        _sessions.remove(previous.id);
        _close(previous);
      }
    }
    final session = ClientSession(
      id: _newSessionId(),
      info: info,
      createdAt: at,
      lastSeenAt: at,
      ttl: ttl,
    );
    _sessions[session.id] = session;
    _notify();
    return session;
  }

  /// Продлевает сессию и сообщает, почему она не подошла.
  ClientSessionLookup touch(String id) {
    final session = _sessions[id];
    if (session == null) {
      return const ClientSessionLookup.failure(ClientSessionProblem.missing);
    }
    final at = now;
    if (session.isExpiredAt(at)) {
      _sessions.remove(id);
      _close(session);
      _notify();
      return const ClientSessionLookup.failure(ClientSessionProblem.expired);
    }
    session.touch(at);
    return ClientSessionLookup.session(session);
  }

  /// Обновляет фокус и открытый чат; heartbeat продлевает сессию.
  ///
  /// Событие изменения рассылается только когда присутствие действительно
  /// изменилось. Иначе каждый heartbeat раз в 20 секунд заставлял бы всех
  /// клиентов перечитывать список сессий.
  ClientSession? updatePresence(
    String id, {
    bool? focused,
    String? activeChatId,
    bool activeChatIdSpecified = true,
  }) {
    final session = _sessions[id];
    if (session == null) return null;
    final nextFocused = focused ?? session.focused;
    final nextActiveChatId = activeChatIdSpecified
        ? activeChatId
        : session.activeChatId;
    final changed =
        nextFocused != session.focused ||
        nextActiveChatId != session.activeChatId;
    session
      ..touch(now)
      ..updatePresence(
        focused: focused,
        activeChatId: activeChatId,
        activeChatIdSpecified: activeChatIdSpecified,
      );
    if (changed) _notify();
    return session;
  }

  /// Все живые сессии. Список уже без истёкших записей.
  List<ClientSession> list() {
    sweep();
    return [..._sessions.values]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  /// Возвращает сессию по id или null.
  ClientSession? byId(String id) => _sessions[id];

  /// Удаляет сессию и закрывает её SSE-соединения.
  ClientSession? remove(String id) {
    final session = _sessions.remove(id);
    if (session != null) {
      _close(session);
      _notify();
    }
    return session;
  }

  /// Связывает SSE-ответ с сессией, чтобы `DELETE` мог его закрыть.
  void attach(String id, HttpResponse response) {
    _sessions[id]?.sseConnections.add(response);
  }

  /// Убирает SSE-ответ из сессии после закрытия потока.
  void detach(String id, HttpResponse response) {
    _sessions[id]?.sseConnections.remove(response);
  }

  /// Удаляет истёкшие сессии. Вызывается таймером и при чтении списка.
  void sweep() {
    final at = now;
    final expired = [
      for (final entry in _sessions.entries)
        if (entry.value.isExpiredAt(at)) entry.key,
    ];
    for (final id in expired) {
      final session = _sessions.remove(id);
      if (session != null) _close(session);
    }
    if (expired.isNotEmpty) _notify();
  }

  /// Открыт ли чат в активной (focused) сессии. Нужно, чтобы не отправлять
  /// push туда, где пользователь и так видит событие.
  bool hasFocusedChat(String? chatId) {
    if (chatId == null) return false;
    final at = now;
    return _sessions.values.any(
      (session) =>
          !session.isExpiredAt(at) &&
          session.focused &&
          session.activeChatId == chatId,
    );
  }

  /// Останавливает таймер и закрывает все SSE-соединения реестра.
  void dispose() {
    _sweepTimer?.cancel();
    _sweepTimer = null;
    for (final session in _sessions.values) {
      _close(session);
    }
    _sessions.clear();
    unawaited(_changes.close());
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _close(ClientSession session) {
    for (final response in [...session.sseConnections]) {
      unawaited(response.close());
    }
    session.sseConnections.clear();
  }

  static String _newSessionId() => ApiTokenStore.generateApiToken();
}

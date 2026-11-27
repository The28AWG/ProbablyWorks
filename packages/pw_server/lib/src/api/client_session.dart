import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:pw_server/src/api/api_token.dart';

/// Описание клиента, которое сервер получил из заголовков `X-Client-*`.
///
/// [clientId] — устройство в модели: одинаковый `clientId` и разные
/// `sessionId` означают одно устройство с несколькими подключениями.
/// [deviceId] — запасной отпечаток для старых клиентов и журнала: после
/// обновления приложения он меняется, а у двух одинаково описанных машин может
/// совпасть. Ни то, ни другое не годится для доступа и отзыва устройств.
final class ClientSessionInfo {
  const ClientSessionInfo({
    required this.deviceId,
    required this.app,
    required this.package,
    required this.version,
    required this.build,
    required this.platform,
    this.clientId = '',
  });

  /// Отпечаток `X-Client-*`, а не уникальный id устройства.
  final String deviceId;

  /// Стабильный id установки из `X-Client-Id`.
  ///
  /// В отличие от [deviceId], не меняется при обновлении приложения и не
  /// совпадает у двух машин с одинаковой версией. Пустая строка означает
  /// старого клиента: тогда для группировки используется [deviceId].
  final String clientId;

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
  /// Создаёт запись сессии; id, секрет продолжения и срок выбирает реестр.
  ClientSession({
    required this.id,
    required this.resumeSecret,
    required ClientSessionInfo info,
    required this.createdAt,
    required this.lastSeenAt,
    required this.ttl,
  }) : deviceId = info.deviceId,
       clientId = info.clientId,
       clientApp = info.app,
       clientPackage = info.package,
       clientVersion = info.version,
       clientBuild = info.build,
       clientPlatform = info.platform;

  /// Непрозрачный id, выданный сервером.
  final String id;

  /// Секрет продолжения сессии. Клиент хранит его рядом с id и присылает
  /// только в рукопожатии; сервер хранит его вместе с сессией, но не отдаёт в
  /// списке. Одного `previousSessionId` недостаточно, иначе другое окно могло
  /// бы «усыновить» чужое представление.
  final String resumeSecret;

  /// Когда сессия создана.
  final DateTime createdAt;

  /// Время жизни после последнего обращения.
  final Duration ttl;

  /// Отпечаток `X-Client-*`, а не уникальный id устройства.
  String deviceId;

  /// Стабильный id установки из `X-Client-Id` или пустая строка.
  String clientId;
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

  /// Момент, после которого сессию нужно удалить, если она не вернётся.
  ///
  /// Ставится по `pagehide` из браузера или когда закрылось последнее SSE-
  /// соединение. Короткая задержка нужна для reload: новая страница успевает
  /// переиспользовать сессию и снять отметку обычным запросом.
  DateTime? closingAt;

  /// Таймер отложенного закрытия. Хранится рядом с отметкой, чтобы любой
  /// признак жизни мог его отменить.
  Timer? closeTimer;

  /// Момент, после которого сессия считается истёкшей.
  DateTime get expiresAt => lastSeenAt.add(ttl);

  /// Истекла ли сессия к моменту [now].
  ///
  /// Отложенное закрытие действует раньше TTL: вкладка уже ушла, и держать
  /// её до конца TTL незачем.
  bool isExpiredAt(DateTime now) {
    final closing = closingAt;
    if (closing != null && !now.isBefore(closing)) return true;
    return !now.isBefore(expiresAt);
  }

  /// Продлевает сессию до [now] + [ttl] и снимает отложенное закрытие.
  void touch(DateTime now) {
    lastSeenAt = now;
    cancelClosing();
  }

  /// Продлевает сессию, не отменяя отложенное закрытие.
  ///
  /// Нужно для ping в SSE: поток ещё пишется, но если страница уже прислала
  /// `closing`, сервер не должен считать это возвращением вкладки.
  void keepAlive(DateTime now) {
    lastSeenAt = now;
  }

  /// Снимает отметку закрытия и таймер.
  void cancelClosing() {
    closeTimer?.cancel();
    closeTimer = null;
    closingAt = null;
  }

  /// Обновляет описание клиента при повторном рукопожатии.
  ///
  /// Версия и платформа могли измениться после обновления приложения, а
  /// сессия остаться прежней. Это нормально: сессия — это представление,
  /// а не версия сборки. [clientId] при этом остаётся прежним: обновление
  /// приложения не создаёт новое устройство.
  void updateInfo(ClientSessionInfo info) {
    deviceId = info.deviceId;
    clientApp = info.app;
    clientPackage = info.package;
    clientVersion = info.version;
    clientBuild = info.build;
    clientPlatform = info.platform;
    if (info.clientId.isNotEmpty) clientId = info.clientId;
  }

  /// Запоминает фокус приложения и открытый чат для присутствия.
  ///
  /// [focused] и [activeChatId] необязательны: heartbeat может прислать только
  /// изменившуюся часть, не сбрасывая вторую.
  ///
  /// [revision] — монотонный номер состояния присутствия. Запрос с ревизией не
  /// больше уже принятой игнорируется: периодический heartbeat мог обогнать
  /// более свежий запрос, и без такой проверки presence откатился бы назад.
  /// Ревизия null означает старого клиента без номера: его состояние
  /// применяется как раньше.
  ///
  /// Возвращает true, если видимое присутствие изменилось. Устаревшая ревизия
  /// возвращает false, но сама сессия уже продлена вызывающим кодом.
  ///
  /// Время взаимодействия обновляется только заметным шагом вперёд. Heartbeat
  /// присылает возраст последнего ввода, который при простое растёт вместе с
  /// часами сервера; без порога каждое такое сообщение считалось бы изменением
  /// присутствия и рассылало бы снимок всем окнам.
  bool updatePresence({
    bool? focused,
    String? activeChatId,
    bool activeChatIdSpecified = true,
    String? visibility,
    bool visibilitySpecified = false,
    DateTime? lastInteractionAt,
    bool interactionSpecified = false,
    bool? activeChatAtEnd,
    int? revision,
  }) {
    if (revision != null && revision <= presenceRevision) return false;
    final nextFocused = focused ?? this.focused;
    final nextActiveChatId = activeChatIdSpecified
        ? activeChatId
        : this.activeChatId;
    final nextVisibility = visibilitySpecified ? visibility : this.visibility;
    final nextActiveChatAtEnd = activeChatAtEnd ?? this.activeChatAtEnd;
    var nextInteraction = this.lastInteractionAt;
    if (interactionSpecified &&
        lastInteractionAt != null &&
        (nextInteraction == null ||
            lastInteractionAt.difference(nextInteraction) >
                const Duration(seconds: 2))) {
      nextInteraction = lastInteractionAt;
    }
    final changed =
        nextFocused != this.focused ||
        nextActiveChatId != this.activeChatId ||
        nextVisibility != this.visibility ||
        nextInteraction != this.lastInteractionAt ||
        nextActiveChatAtEnd != this.activeChatAtEnd;
    if (focused != null) this.focused = focused;
    if (activeChatIdSpecified) this.activeChatId = activeChatId;
    if (visibilitySpecified) this.visibility = visibility;
    this.lastInteractionAt = nextInteraction;
    this.activeChatAtEnd = nextActiveChatAtEnd;
    if (revision != null) presenceRevision = revision;
    return changed;
  }

  /// Находится ли приложение в фокусе на этом клиенте.
  bool focused = false;

  /// Чат, открытый на этом клиенте, если он сообщил его в heartbeat.
  String? activeChatId;

  /// Последняя принятая ревизия присутствия.
  ///
  /// Ноль — новая сессия или клиент без ревизий. Значение переживает
  /// повторное рукопожатие после reload: иначе новый экземпляр страницы
  /// начинал бы нумерацию заново, и сервер отклонял бы его обновления как
  /// устаревшие.
  int presenceRevision = 0;

  /// Чаты, тяжёлые события которых нужны этому экрану.
  ///
  /// `null` — клиент ещё не присылал список подписок: для совместимости со
  /// старыми клиентами сервер отдаёт ему все события, как раньше. Пустое
  /// множество — клиент явно сказал, что ни один чат не открыт, и тяжёлые
  /// события не нужны. Полный поток нужен только для дельт ответа, очереди,
  /// сообщений и снимка хода; карточки, удаление чата и присутствие остаются
  /// глобальными, иначе другое окно не узнало бы о запросе подтверждения.
  Set<String>? chatSubscriptions;

  /// Видимость приложения: `foreground`, `background` или `locked`.
  ///
  /// `null` — старый клиент, который присылает только [focused]. Тогда сервер
  /// сохраняет прежнее поведение и считает фокус достаточным признаком
  /// присутствия. Новый клиент присылает видимость, чтобы свёрнутое окно не
  /// выглядело как «пользователь здесь».
  String? visibility;

  /// Когда пользователь последний раз взаимодействовал с этим экраном.
  ///
  /// Сервер хранит время в своих часах: клиент присылает возраст последнего
  /// взаимодействия, а не абсолютную отметку, чтобы расхождение часов не
  /// превращало активное устройство в «давно ушедшее» и наоборот.
  DateTime? lastInteractionAt;

  /// Находится ли открытый чат у нижней границы ленты.
  ///
  /// Для старых клиентов и серверов значение `true`: раньше открытый чат
  /// считался видимым целиком. Новый клиент сообщает, что пользователь
  /// прокрутил вверх или стоит на разделителе непрочитанного, — тогда
  /// уведомление о новом сообщении уместно.
  bool activeChatAtEnd = true;

  /// Видимо ли приложение на экране с учётом совместимости.
  bool get isForeground =>
      visibility == null ? focused : visibility == 'foreground';

  /// Время последней активности для выбора активного устройства.
  ///
  /// Старый клиент отметки не присылает, поэтому для него используется
  /// [lastSeenAt]: поведение остаётся прежним, пока клиент не обновится.
  DateTime get activityAt => lastInteractionAt ?? lastSeenAt;

  /// Считается ли устройство активным к моменту [now].
  ///
  /// Нужен недавний ввод и видимое приложение. Одно лишь открытое окно не
  /// делает устройство активным: иначе забытый на столе десктоп навсегда
  /// подавлял бы уведомления на телефоне.
  bool isPresentAt(DateTime now, Duration idleTimeout) {
    if (isExpiredAt(now) || !isForeground) return false;
    final interaction = lastInteractionAt;
    if (interaction == null) return true;
    return now.difference(interaction) <= idleTimeout;
  }
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
    this.closeGrace = const Duration(seconds: 5),
    this.activeTimeout = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _sweepTimer = Timer.periodic(sweepInterval, (_) => sweep());
  }

  /// Время жизни сессии после последнего обращения.
  final Duration ttl;

  /// Сколько ждать после сигнала закрытия или обрыва SSE, прежде чем убрать
  /// сессию. Перезагрузка вкладки успевает снять отметку.
  final Duration closeGrace;

  /// Сколько устройство остаётся «активным» без нового взаимодействия.
  ///
  /// Окно может быть открыто и в фокусе, но пользователь давно ушёл. Через
  /// этот срок устройство перестаёт подавлять уведомления и уступает
  /// активному телефону. Пять минут — компромисс: короче — уведомления
  /// приходят от ещё не забытого экрана, длиннее — телефон молчит слишком долго.
  final Duration activeTimeout;

  /// Как часто удалять истёкшие сессии.
  final Duration sweepInterval;

  final DateTime Function() _now;
  final Map<String, ClientSession> _sessions = {};
  Timer? _sweepTimer;
  final _changes = StreamController<void>.broadcast();
  var _revision = 0;

  /// Последний вычисленный набор активных сессий.
  ///
  /// Нужен, чтобы заметить, что пользователь ушёл и истёк idle-таймаут, когда
  /// нового запроса от клиента нет. Без этого снимок с `active` не обновился
  /// бы до следующего heartbeat, а отложенная карточка не переехала бы на
  /// другое устройство.
  Set<String> _lastPresentSessionIds = const {};

  /// Монотонная ревизия снимка присутствия.
  ///
  /// Растёт при каждом реальном изменении состава или присутствия. Клиент
  /// сравнивает её у события и у ответа `GET /client/sessions`: поздний, но
  /// более старый снимок не должен перезаписать свежий.
  int get revision => _revision;

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
  /// доказательство. Продолжение разрешено только вместе с секретом, который
  /// сервер выдал этой же сессии в рукопожатии. Если обе стороны прислали
  /// [clientId], он тоже должен совпасть. Так другое окно не может
  /// «усыновить» чужое представление, даже если узнало id из списка. Если
  /// старой сессии нет или проверка не прошла, создаётся новая; живую чужую
  /// сессию при этом не трогаем.
  ClientSession handshake({
    required ClientSessionInfo info,
    String? previousSessionId,
    String? previousSessionSecret,
  }) {
    final at = now;
    if (previousSessionId != null && previousSessionId.isNotEmpty) {
      final previous = _sessions[previousSessionId];
      if (previous != null) {
        if (previous.isExpiredAt(at)) {
          _sessions.remove(previous.id);
          _close(previous);
        } else if (_canResume(previous, info, previousSessionSecret)) {
          previous
            ..updateInfo(info)
            ..touch(at);
          _notify();
          return previous;
        }
      }
    }
    final session = ClientSession(
      id: _newSessionId(),
      resumeSecret: _newSessionId(),
      info: info,
      createdAt: at,
      lastSeenAt: at,
      ttl: ttl,
    );
    _sessions[session.id] = session;
    _notify();
    return session;
  }

  /// Проверяет, можно ли продолжить [session] по присланной подсказке.
  ///
  /// Секрет — главное условие: без него id из списка сессий бесполезен.
  /// [clientId] необязателен для старых клиентов, но если обе стороны его
  /// прислали, он тоже должен совпасть: секрет от одной вкладки не должен
  /// продолжать сессию устройства, которое успело сменить установку.
  static bool _canResume(
    ClientSession session,
    ClientSessionInfo info,
    String? secret,
  ) {
    if (secret == null || secret.isEmpty || secret != session.resumeSecret) {
      return false;
    }
    return session.clientId.isEmpty ||
        info.clientId.isEmpty ||
        session.clientId == info.clientId;
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
  /// клиентов перечитывать список сессий. Запрос с устаревшей ревизией тоже
  /// продлевает сессию, но состояние не меняет.
  ClientSession? updatePresence(
    String id, {
    bool? focused,
    String? activeChatId,
    bool activeChatIdSpecified = true,
    String? visibility,
    bool visibilitySpecified = false,
    DateTime? lastInteractionAt,
    bool interactionSpecified = false,
    bool? activeChatAtEnd,
    int? revision,
  }) {
    final session = _sessions[id];
    if (session == null) return null;
    session.touch(now);
    final changed = session.updatePresence(
      focused: focused,
      activeChatId: activeChatId,
      activeChatIdSpecified: activeChatIdSpecified,
      visibility: visibility,
      visibilitySpecified: visibilitySpecified,
      lastInteractionAt: lastInteractionAt,
      interactionSpecified: interactionSpecified,
      activeChatAtEnd: activeChatAtEnd,
      revision: revision,
    );
    if (changed) _notify();
    return session;
  }

  /// Заменяет набор чатов, тяжёлые события которых получает сессия.
  ///
  /// Список приходит от клиента при открытии и закрытии чата. Он не влияет на
  /// присутствие и не рассылает событие соседям: это транспортная настройка
  /// конкретного окна, а не состояние, которое видит пользователь.
  ClientSession? updateChatSubscriptions(String id, Set<String> chatIds) {
    final session = _sessions[id];
    if (session == null) return null;
    session
      ..touch(now)
      ..chatSubscriptions = {...chatIds};
    return session;
  }

  /// Продлевает сессию по живому SSE-соединению.
  ///
  /// В фоновой вкладке браузер затормаживает таймеры клиента, и heartbeat
  /// может не успеть до истечения TTL. Открытый SSE при этом остаётся живым:
  /// сервер пишет в него ping. Считать такую сессию истёкшей нельзя, иначе
  /// экран «пропадает» из присутствия и возвращается при переключении вкладки.
  ///
  /// Метод не отменяет отложенное закрытие: ping может продолжать идти, пока
  /// браузер ещё не разорвал поток после сигнала `closing`.
  void keepAlive(String id) {
    _sessions[id]?.keepAlive(now);
  }

  /// Планирует закрытие сессии, если она не подаст признак жизни.
  ///
  /// Вызывается по `pagehide` из браузера и по [detach], когда закрылось
  /// последнее SSE-соединение. [closeGrace] даёт перезагрузке время
  /// переиспользовать сессию: любой обычный запрос или новое SSE снимают
  /// отметку. Если клиент не вернулся, сессия удаляется таймером.
  ClientSession? markClosing(String id, {Duration? grace}) {
    final session = _sessions[id];
    if (session == null) return null;
    final delay = grace ?? closeGrace;
    session
      ..closeTimer?.cancel()
      ..closingAt = now.add(delay)
      ..closeTimer = Timer(delay, () {
        final current = _sessions[id];
        if (current == null) return;
        final closing = current.closingAt;
        if (closing == null || _now().isBefore(closing)) return;
        _sessions.remove(id);
        _close(current);
        _notify();
      });
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
  ///
  /// Новое соединение означает, что вкладка вернулась: отложенное закрытие
  /// снимается.
  void attach(String id, HttpResponse response) {
    final session = _sessions[id];
    if (session == null) return;
    session.sseConnections.add(response);
    session.cancelClosing();
  }

  /// Убирает SSE-ответ из сессии после закрытия потока.
  ///
  /// Если это было последнее соединение, вкладка, скорее всего, закрыта или
  /// ушла с сайта. Планируем закрытие с короткой задержкой: переподключение
  /// SSE успеет отменить его.
  void detach(String id, HttpResponse response) {
    final session = _sessions[id];
    if (session == null) return;
    session.sseConnections.remove(response);
    if (session.sseConnections.isEmpty) markClosing(id);
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
    // Устройство могло перестать быть активным без запроса: пользователь
    // просто ушёл. Смена набора активных сессий — такое же изменение
    // присутствия, как новый фокус, и о ней нужно сообщить подписчикам.
    // Адресат уведомлений здесь не сравнивается: при отсутствии активных он
    // выбирается по `lastSeenAt`, который обновляют heartbeat и SSE-ping, и
    // сравнение рассылало бы снимок на каждом sweep.
    final presentIds = _presentSessionIdsAt(at);
    final presenceChanged = !_sameSessionIds(
      presentIds,
      _lastPresentSessionIds,
    );
    if (expired.isNotEmpty || presenceChanged) _notify();
  }

  /// Ключ устройства для группировки окон и адресации.
  ///
  /// Стабильный [ClientSession.clientId] важнее отпечатка заголовков: две
  /// вкладки одного браузера или два окна одной установки должны считаться
  /// одним устройством.
  static String deviceKeyOf(ClientSession session) =>
      session.clientId.isNotEmpty ? session.clientId : session.deviceId;

  /// Активен ли экран этой сессии к моменту [now].
  bool isPresent(ClientSession session, DateTime now) =>
      session.isPresentAt(now, activeTimeout);

  /// Идентификаторы сессий, которые сейчас считаются активными.
  ///
  /// `active` в снимке рассчитывается для каждого экрана отдельно, поэтому
  /// смена ловится по всем сессиям, а не только по выбранному устройству.
  Set<String> _presentSessionIdsAt(DateTime at) => {
    for (final session in _sessions.values)
      if (session.isPresentAt(at, activeTimeout)) session.id,
  };

  static bool _sameSessionIds(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  /// Сессия, на которую сейчас направлено внимание пользователя.
  ///
  /// Сначала выбираются действительно активные экраны, затем — самое свежее
  /// живое. Второй шаг нужен, когда пользователь свернул всё: push всё равно
  /// должен прийти на одно устройство, а не на все сразу. Заблокированные
  /// экраны уступают место остальным, если такие есть.
  ClientSession? attentionSessionAt(DateTime at) {
    final live = [
      for (final session in _sessions.values)
        if (!session.isExpiredAt(at)) session,
    ];
    if (live.isEmpty) return null;
    final present = [
      for (final session in live)
        if (isPresent(session, at)) session,
    ];
    if (present.isNotEmpty) {
      present.sort(_comparePresent);
      return present.first;
    }
    final available = [
      for (final session in live)
        if (session.visibility != 'locked') session,
    ];
    final pool = available.isEmpty ? live : available;
    return pool.reduce((a, b) => _compareSeen(a, b) <= 0 ? a : b);
  }

  /// Ключ устройства, которое должно показывать системные уведомления.
  ///
  /// При отсутствии активных экранов это самое свежее живое устройство: ровно
  /// одно, чтобы событие не всплыло сразу на всех экранах. Свежесть здесь —
  /// выбор момента, а не повод рассылать снимок: sweep сравнивает только набор
  /// активных сессий, иначе heartbeat переставлял бы устройства на каждом шаге.
  String? attentionDeviceKeyAt(DateTime at) {
    final session = attentionSessionAt(at);
    return session == null ? null : deviceKeyOf(session);
  }

  /// Открыт ли чат там, где пользователь действительно его видит.
  ///
  /// Одного фокуса недостаточно: окно могло остаться открытым после ухода.
  /// Дополнительно нужен конец ленты — если пользователь читает старые
  /// сообщения, уведомление о новом не будет лишним.
  bool hasVisibleChat(String? chatId) {
    if (chatId == null) return false;
    final at = now;
    return _sessions.values.any(
      (session) =>
          isPresent(session, at) &&
          session.activeChatId == chatId &&
          session.activeChatAtEnd,
    );
  }

  /// Сортировка активных сессий: недавнее взаимодействие важнее свежести
  /// heartbeat. При равенстве выигрывает более свежая сессия.
  static int _comparePresent(ClientSession a, ClientSession b) {
    final byActivity = b.activityAt.compareTo(a.activityAt);
    if (byActivity != 0) return byActivity;
    return _compareSeen(a, b);
  }

  static int _compareSeen(ClientSession a, ClientSession b) {
    final bySeen = b.lastSeenAt.compareTo(a.lastSeenAt);
    if (bySeen != 0) return bySeen;
    return b.createdAt.compareTo(a.createdAt);
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
    final at = now;
    // Снимок и следующий sweep сравнивают именно с этими значениями: так
    // изменение присутствия не рассылает второй такой же снимок.
    _lastPresentSessionIds = _presentSessionIdsAt(at);
    _revision++;
    if (!_changes.isClosed) _changes.add(null);
  }

  void _close(ClientSession session) {
    session
      ..closeTimer?.cancel()
      ..closeTimer = null
      ..closingAt = null;
    for (final response in [...session.sseConnections]) {
      unawaited(response.close());
    }
    session.sseConnections.clear();
  }

  static String _newSessionId() => ApiTokenStore.generateApiToken();
}

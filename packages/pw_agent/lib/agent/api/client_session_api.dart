/// Видимость приложения на клиенте в момент heartbeat.
///
/// `foreground` — окно на экране, `background` — приложение свёрнуто или
/// вкладка скрыта, `locked` — устройство заблокировано. Сервер отличает
/// «приложение открыто» от «пользователь здесь»: без видимости и времени
/// последнего взаимодействия фоновое окно навсегда подавляло бы push.
enum ClientVisibility {
  foreground,
  background,
  locked;

  /// Разбирает значение из протокола; неизвестное значение считается
  /// отсутствующим, чтобы старый сервер не ломал список экранов.
  static ClientVisibility? parse(Object? value) => switch (value) {
    'foreground' => ClientVisibility.foreground,
    'background' => ClientVisibility.background,
    'locked' => ClientVisibility.locked,
    _ => null,
  };
}

/// Представление клиентского подключения для списка устройств.
///
/// Это не пользователь и не токен: одна сессия — одно окно/устройство,
/// подключённое к одному экземпляру агента.
final class ClientSessionView {
  const ClientSessionView({
    required this.id,
    required this.deviceId,
    required this.clientApp,
    required this.clientVersion,
    required this.clientBuild,
    required this.clientPlatform,
    required this.createdAt,
    required this.lastSeenAt,
    required this.expiresAt,
    required this.focused,
    required this.online,
    required this.current,
    this.clientId = '',
    this.activeChatId,
    this.visibility,
    this.lastInteractionAt,
    this.activeChatAtEnd = true,
    this.active = false,
    this.attention = true,
  });

  final String id;
  final String deviceId;

  /// Стабильный id установки. Пустая строка — старый сервер или клиент без
  /// сохранённого id; тогда устройство определяется по [deviceId].
  final String clientId;

  final String clientApp;
  final String clientVersion;
  final String clientBuild;
  final String clientPlatform;
  final String? activeChatId;
  final DateTime createdAt;
  final DateTime lastSeenAt;
  final DateTime expiresAt;
  final bool focused;
  final bool online;
  final bool current;

  /// Видимость приложения из heartbeat. `null` — старый клиент или сервер,
  /// который ещё не присылает это поле.
  final ClientVisibility? visibility;

  /// Когда пользователь последний раз взаимодействовал с этим экраном.
  ///
  /// `null` — старый клиент или сервер без поля. Сервер считает экран
  /// активным только пока взаимодействие было недавним, поэтому «открытое и
  /// забытое» окно больше не подавляет уведомление.
  final DateTime? lastInteractionAt;

  /// Открытый чат находится у нижней границы ленты.
  ///
  /// Разделитель непрочитанного и прокрутка вверх означают, что пользователь
  /// ещё не видит новые сообщения. Уведомление в этот момент уместно даже при
  /// открытом чате.
  final bool activeChatAtEnd;

  /// Экран действительно активен: приложение на экране, а последнее
  /// взаимодействие было недавним. Это признак внимания, а не авторизации.
  /// Считается для каждого окна отдельно: фоновое окно того же устройства не
  /// выглядит как «пользователь здесь». Устройство активно, если активен хотя
  /// бы один его экран.
  final bool active;

  /// Это устройство должно показывать системные уведомления.
  ///
  /// Сервер выбирает одно устройство по активности, а при отсутствии активных
  /// — по свежести присутствия. Остальные экраны молчат, чтобы push не
  /// приходил на все устройства сразу. Для старого сервера значение `true` у
  /// всех сессий сохраняет прежнее поведение.
  final bool attention;

  /// Ключ группировки вкладок и окон в одно устройство.
  ///
  /// [clientId] не меняется при обновлении приложения и различает машины с
  /// одинаковой версией. [deviceId] остаётся запасным вариантом для старых
  /// клиентов: он по-прежнему отпечаток `X-Client-*`.
  String get deviceKey => clientId.isNotEmpty ? clientId : deviceId;

  /// Короткая подпись устройства для UI.
  String get label {
    final app = clientApp.isEmpty ? clientPlatform : clientApp;
    return clientVersion.isEmpty ? app : '$app $clientVersion';
  }
}

/// Открыт ли [chatId] на экране, который действительно видит пользователь.
///
/// Недостаточно `focused`: приложение может быть в фокусе, но пользователь уже
/// ушёл от компьютера. Поэтому сессия должна быть активной (недавнее
/// взаимодействие) и показывать конец ленты. Иначе уведомление о новом
/// сообщении уместно: пользователь смотрит старую часть чата или вообще
/// переключился на другое окно.
///
/// [includeCurrent] выключают, когда фокус текущего окна проверяется отдельно:
/// presence этого окна может отставать, а устаревший `focused` не должен
/// скрывать уведомление на самом устройстве.
bool isChatVisibleInPresence(
  Iterable<ClientSessionView> sessions,
  String chatId, {
  bool includeCurrent = true,
}) => sessions.any(
  (session) =>
      (includeCurrent || !session.current) &&
      session.online &&
      session.active &&
      session.activeChatId == chatId &&
      session.activeChatAtEnd,
);

/// Должно ли текущее устройство показывать системное уведомление.
///
/// Сервер помечает [ClientSessionView.attention] у одного устройства, чтобы
/// одно событие не всплывало на всех экранах. Если адресации нет (старый
/// сервер), текущий экран не найден или все отметки сняты, возвращается
/// `true`: пропустить запрос подтверждения хуже, чем показать лишнее
/// уведомление.
bool isNotificationTargetInPresence(Iterable<ClientSessionView> sessions) {
  final online = [
    for (final session in sessions)
      if (session.online) session,
  ];
  if (online.isEmpty) return true;
  if (!online.any((session) => session.attention)) return true;
  final current = [
    for (final session in online)
      if (session.current) session,
  ];
  // Своего экрана нет в снимке (например, сессия успела истечь): не берёмся
  // решать за сервер и показываем уведомление.
  if (current.isEmpty) return true;
  return current.any((session) => session.attention);
}

/// Присутствие клиентов и список подключений. Реализуется удалённым API;
/// встроенный агент возвращает пустой список.
abstract interface class ClientSessionApi {
  Stream<List<ClientSessionView>> get clientSessions;

  Future<List<ClientSessionView>> refreshClientSessions();

  /// Убирает другое подключение по fingerprint из списка экранов.
  ///
  /// Это уборка зависшего представления, а не отзыв доступа: экран, который
  /// ещё открыт, сможет пройти рукопожатие заново. Встроенный агент соседей
  /// не имеет, поэтому ничего не делает.
  Future<void> closeClientSession(String id);

  /// Обновляет присутствие.
  ///
  /// Удалённый клиент отправляет изменение сразу и перечитывает список
  /// экранов; встроенный агент ничего не делает, потому что соседей у него нет.
  ///
  /// [visibility] и [activeChatAtEnd] появились позже `focused`: старый
  /// сервер их игнорирует, а новый отличает «окно открыто» от «пользователь
  /// здесь». [activeChatAtEnd] имеет смысл только вместе с [activeChatId].
  void setPresence({
    bool? focused,
    String? activeChatId,
    bool clearActiveChat = false,
    ClientVisibility? visibility,
    bool? activeChatAtEnd,
  });

  /// Отмечает взаимодействие пользователя для idle-детекта.
  ///
  /// Клиент запоминает время последнего ввода, нажатия или прокрутки и
  /// отправляет его со следующим heartbeat. Частые вызовы не создают запрос на
  /// каждое движение: публикация сглаживается.
  void noteInteraction([DateTime? at]);
}

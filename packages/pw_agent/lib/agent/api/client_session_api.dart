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
    this.activeChatId,
  });

  final String id;
  final String deviceId;
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

  /// Короткая подпись устройства для UI.
  String get label {
    final app = clientApp.isEmpty ? clientPlatform : clientApp;
    return clientVersion.isEmpty ? app : '$app $clientVersion';
  }
}

/// Присутствие клиентов и список подключений. Реализуется удалённым API;
/// встроенный агент возвращает пустой список.
abstract interface class ClientSessionApi {
  Stream<List<ClientSessionView>> get clientSessions;

  Future<List<ClientSessionView>> refreshClientSessions();

  /// Обновляет присутствие. Следующий heartbeat отправит изменения.
  void setPresence({
    bool? focused,
    String? activeChatId,
    bool clearActiveChat = false,
  });
}

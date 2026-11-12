import 'dart:convert';

/// Версия протокола локального демона.
const localDaemonProtocol = 1;

/// Данные, которые демон публикует для локального GUI.
///
/// Файл с этими данными имеет права `0600`. Токен нужен для доступа к
/// loopback API; позже его можно перенести в OS-keyring.
final class LocalDaemonInfo {
  const LocalDaemonInfo({
    required this.pid,
    required this.port,
    required this.token,
    required this.startedAt,
    this.protocol = localDaemonProtocol,
  });

  factory LocalDaemonInfo.fromJson(Map<String, dynamic> json) =>
      LocalDaemonInfo(
        protocol: json['protocol'] is num
            ? (json['protocol'] as num).toInt()
            : 0,
        pid: json['pid'] is num ? (json['pid'] as num).toInt() : 0,
        port: json['port'] is num ? (json['port'] as num).toInt() : 0,
        token: '${json['token'] ?? ''}',
        startedAt:
            DateTime.tryParse('${json['startedAt'] ?? ''}')?.toUtc() ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );

  final int protocol;
  final int pid;
  final int port;
  final String token;
  final DateTime startedAt;

  bool get isValid =>
      protocol == localDaemonProtocol &&
      pid > 0 &&
      port > 0 &&
      token.isNotEmpty;

  Map<String, Object?> toJson() => {
    'protocol': protocol,
    'pid': pid,
    'port': port,
    'token': token,
    'startedAt': startedAt.toUtc().toIso8601String(),
  };

  String encode() => jsonEncode(toJson());

  static LocalDaemonInfo? decode(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final info = LocalDaemonInfo.fromJson(Map<String, dynamic>.from(json));
      return info.isValid ? info : null;
    } on FormatException {
      return null;
    }
  }
}

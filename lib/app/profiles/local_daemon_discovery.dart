import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pw_agent/core/config/app_paths.dart';
import 'package:pw_agent/core/config/local_daemon_info.dart';
import 'package:pw_agent/core/security/secret_store.dart';

/// Ищет запущенный локальный демон по discovery-файлу.
///
/// Проверяются protocol, доступность HTTP API и токен. Если токена нет в
/// `daemon.json`, он читается из OS-keyring через [SecretStore]. Ошибки и
/// устаревший файл означают «демона нет», а не падение приложения.
final class LocalDaemonDiscovery {
  LocalDaemonDiscovery(this._paths, {http.Client? client, this.secrets})
    : _client = client ?? http.Client();

  final AppPaths _paths;
  final http.Client _client;

  /// Хранилище, из которого читается токен, если его нет в `daemon.json`.
  final SecretStore? secrets;

  static const _timeout = Duration(seconds: 2);

  Future<LocalDaemonInfo?> find() async {
    try {
      final file = _paths.daemonInfo;
      if (!file.existsSync()) return null;
      final info = LocalDaemonInfo.decode(file.readAsStringSync());
      if (info == null) return null;
      final token = await _tokenFor(info);
      if (token == null || token.isEmpty) return null;
      final base = Uri.parse('http://127.0.0.1:${info.port}');
      final health = await _client
          .get(base.resolve('/api/v1/health'))
          .timeout(_timeout);
      if (health.statusCode != 200) return null;
      // Токен и версия протокола проверяются отдельным probe-запросом:
      // остальные маршруты после рукопожатия требуют `X-Client-Session`.
      // Probe не создаёт сессию, поэтому не тревожит список клиентов.
      if (!await _probe(base, token)) return null;
      return info.copyWith(token: token);
    } on Object {
      return null;
    }
  }

  Future<bool> _probe(Uri base, String token) async {
    final response = await _client
        .get(
          base.resolve('/api/v1/client/probe'),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(_timeout);
    if (response.statusCode != 200) return false;
    try {
      final decoded = jsonDecode(response.body);
      return decoded is Map &&
          decoded['protocol'] is num &&
          (decoded['protocol'] as num).toInt() == localDaemonProtocol;
    } on FormatException {
      // Битый ответ — демон не подтвердил токен.
    }
    return false;
  }

  Future<String?> _tokenFor(LocalDaemonInfo info) async {
    if (info.token.isNotEmpty) return info.token;
    return secrets?.read(apiTokenKey);
  }

  Uri baseUriFor(LocalDaemonInfo info) =>
      Uri.parse('http://127.0.0.1:${info.port}');

  void dispose() => _client.close();
}

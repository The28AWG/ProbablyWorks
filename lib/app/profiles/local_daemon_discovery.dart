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
      final settings = await _client
          .get(
            base.resolve('/api/v1/settings'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(_timeout);
      if (settings.statusCode != 200) return null;
      return info.copyWith(token: token);
    } on Object {
      return null;
    }
  }

  Future<String?> _tokenFor(LocalDaemonInfo info) async {
    if (info.token.isNotEmpty) return info.token;
    return secrets?.read(apiTokenKey);
  }

  Uri baseUriFor(LocalDaemonInfo info) =>
      Uri.parse('http://127.0.0.1:${info.port}');

  void dispose() => _client.close();
}

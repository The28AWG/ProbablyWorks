import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pw_agent/core/security/file_permissions.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_server/src/api/api_token.dart';

/// `SecretStore` headless-демона.
///
/// Это MVP без OS-keyring: значения лежат в JSON-файле `0600` внутри каталога
/// приложения `0700`. Ключ OpenRouter и токен API можно переопределить
/// переменными окружения — так демон запускается на сервере без графической
/// сессии. Для полноценного keyring нужен отдельный провайдер (libsecret,
/// Keychain, DPAPI).
final class DaemonSecretStore implements SecretStore {
  DaemonSecretStore(Directory support, {this.environment = const {}})
    : _file = File(p.join(support.path, 'secrets.json'));

  static const openRouterEnvironment = 'PROBABLY_WORKS_OPENROUTER_KEY';
  static const openRouterFallbackEnvironment = 'OPENROUTER_API_KEY';
  static const apiTokenEnvironment = 'PROBABLY_WORKS_API_TOKEN';

  final File _file;
  final Map<String, String> environment;

  @override
  SecretStoreKind get kind => SecretStoreKind.headlessFile;

  @override
  Future<String?> read(String key) async {
    final fromEnvironment = _environmentValue(key);
    if (fromEnvironment != null) return fromEnvironment;
    return (await _load())[key];
  }

  @override
  Future<void> write(String key, String value) async {
    final values = await _load();
    values[key] = value;
    await _save(values);
  }

  @override
  Future<void> delete(String key) async {
    final values = await _load();
    if (values.remove(key) == null) return;
    await _save(values);
  }

  String? _environmentValue(String key) {
    if (key == openRouterKeyName) {
      return _nonEmpty(environment[openRouterEnvironment]) ??
          _nonEmpty(environment[openRouterFallbackEnvironment]);
    }
    if (key == apiTokenKey) {
      return _nonEmpty(environment[apiTokenEnvironment]);
    }
    return null;
  }

  Future<Map<String, String>> _load() async {
    if (!_file.existsSync()) return {};
    try {
      final decoded = jsonDecode(await _file.readAsString());
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.value is String) '${entry.key}': entry.value as String,
      };
    } on FormatException {
      return {};
    } on FileSystemException {
      return {};
    }
  }

  Future<void> _save(Map<String, String> values) async {
    await _file.parent.create(recursive: true);
    final temp = File('${_file.path}.tmp');
    await temp.writeAsString(jsonEncode(values), flush: true);
    FilePermissions.file(temp);
    await temp.rename(_file.path);
  }

  static String? _nonEmpty(String? value) =>
      value == null || value.isEmpty ? null : value;
}

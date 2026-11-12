import 'dart:convert';
import 'dart:math';

import 'package:pw_agent/core/security/secret_store.dart';

/// Токен доступа к HTTP API. Хранится в защищённом хранилище и не пишется в логи.
final class ApiTokenStore {
  ApiTokenStore(this._secrets);

  final SecretStore _secrets;

  /// Возвращает сохранённый токен или создаёт новый.
  Future<String> ensure() async {
    final existing = await _secrets.read(apiTokenKey);
    if (existing != null && existing.isNotEmpty) return existing;
    return rotate();
  }

  /// Выпускает новый токен; старый сразу перестаёт работать.
  Future<String> rotate() async {
    final token = generateApiToken();
    await _secrets.write(apiTokenKey, token);
    return token;
  }

  /// 32 случайных байта в base64url без padding.
  static String generateApiToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}

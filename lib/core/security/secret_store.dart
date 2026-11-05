import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:injectable/injectable.dart';

/// Секреты (ключ OpenRouter, пароли, passphrase SSH и переменные окружения хоста) только здесь, не в SQLite.
abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

const openRouterKeyName = 'openrouter.apiKey';

String hostPasswordKey(String hostId) => 'host.$hostId.password';
String hostPassphraseKey(String hostId) => 'host.$hostId.passphrase';

/// PEM приватного ключа SSH хранится в secure storage: файл с устройства (в т.ч. Android/iOS) не имеет стабильного пути.
String hostPrivateKeyKey(String hostId) => 'host.$hostId.privateKey';

/// JSON-объект переменных окружения хоста. Колонки в таблице хостов нет: значения могут быть токенами.
String hostEnvironmentKey(String hostId) => 'host.$hostId.environment';

@LazySingleton(as: SecretStore)
class FlutterSecretStore implements SecretStore {
  FlutterSecretStore(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Хранилище в памяти: для тестов и интеграционных сценариев.
class MemorySecretStore implements SecretStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

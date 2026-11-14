import 'package:pw_agent/core/util/char_substring.dart';

/// Тип backend'а секретов. Нужен аудиту, чтобы не зависеть от Flutter-классов.
enum SecretStoreKind { memory, osKeychain, headlessFile, unknown }

/// Доступ к секретам приложения. Реализация зависит от платформы:
/// в GUI это защищённое хранилище ОС, в headless-демоне — отдельный провайдер.
abstract interface class SecretStore {
  /// Тип хранилища для отчёта безопасности.
  SecretStoreKind get kind;

  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Старое имя секрета OpenRouter. Читается для существующих профилей;
/// новые ключи пишутся в `provider.openrouter.apiKey`.
const openRouterKeyName = 'openrouter.apiKey';

/// Ключ провайдера в [SecretStore]. Схема общая для всех провайдеров.
String providerApiKeyName(String providerId) => 'provider.$providerId.apiKey';

/// id провайдера из имени секрета `provider.<id>.apiKey`. Null — не тот ключ.
String? providerIdFromApiKeyName(String key) {
  const prefix = 'provider.';
  const suffix = '.apiKey';
  if (!key.startsWith(prefix) || !key.endsWith(suffix)) return null;
  final id = charRange(key, prefix.length, key.length - suffix.length);
  return id.isEmpty ? null : id;
}

/// Ключ токена HTTP API в [SecretStore].
const apiTokenKey = 'api.token';

String hostPasswordKey(String hostId) => 'host.$hostId.password';
String hostPassphraseKey(String hostId) => 'host.$hostId.passphrase';

/// PEM приватного ключа SSH хранится в secure storage: файл с устройства (в т.ч. Android/iOS) не имеет стабильного пути.
String hostPrivateKeyKey(String hostId) => 'host.$hostId.privateKey';

/// JSON-объект переменных окружения хоста. Колонки в таблице хостов нет: значения могут быть токенами.
String hostEnvironmentKey(String hostId) => 'host.$hostId.environment';

/// Хранилище в памяти: для тестов и интеграционных сценариев.
class MemorySecretStore implements SecretStore {
  final Map<String, String> values = {};

  @override
  SecretStoreKind get kind => SecretStoreKind.memory;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

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

const openRouterKeyName = 'openrouter.apiKey';

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

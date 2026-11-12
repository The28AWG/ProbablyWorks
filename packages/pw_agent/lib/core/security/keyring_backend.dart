/// Системное хранилище секретов: Secret Service, Keychain, Credential Manager.
///
/// Реализации не должны бросать исключения наружу: [SystemSecretStore]
/// перехватывает ошибки и переходит на файловый fallback.
abstract interface class KeyringBackend {
  /// Человекочитаемое имя backend'а для логов и аудита.
  String get name;

  /// Возвращает секрет или null, если записи нет.
  Future<String?> read(String key);

  /// Сохраняет секрет, заменяя существующую запись.
  Future<void> write(String key, String value);

  /// Удаляет запись. Отсутствующая запись не считается ошибкой.
  Future<void> delete(String key);
}

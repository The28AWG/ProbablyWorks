/// Хранилище выданного сервером `sessionId` между перезагрузками клиента.
///
/// На desktop и mobile это обычная память процесса: после запуска приложения
/// выдаётся новая сессия. На web реализация использует `sessionStorage`,
/// потому что перезагрузка вкладки не должна выглядеть как новое устройство.
/// Рядом с id клиент хранит секрет продолжения: он не попадает в список
/// сессий и уходит только в рукопожатии.
abstract interface class ClientSessionStore {
  /// Читает сохранённый id или null, если его нет.
  String? read(String key);

  /// Сохраняет id, выданный сервером.
  void write(String key, String value);

  /// Удаляет id профиля, например при удалении профиля.
  void delete(String key);
}

/// Хранилище в памяти. Значения живут столько же, сколько процесс клиента.
final class MemoryClientSessionStore implements ClientSessionStore {
  final Map<String, String> _values = {};

  @override
  String? read(String key) => _values[key];

  @override
  void write(String key, String value) => _values[key] = value;

  @override
  void delete(String key) => _values.remove(key);
}

/// Проверка, не занят ли `sessionId` другой вкладкой.
///
/// Нужен только web: `sessionStorage` может скопироваться при дублировании
/// вкладки, а две вкладки должны оставаться двумя клиентами. На нативных
/// платформах используется [NoopClientSessionChannel].
abstract interface class ClientSessionChannel {
  /// `true`, если другая живая вкладка уже держит этот id.
  Future<bool> isActive(String id);

  /// Освобождает ресурсы канала. Идемпотентен.
  void close();
}

/// Заглушка для платформ, где вкладок нет.
final class NoopClientSessionChannel implements ClientSessionChannel {
  const NoopClientSessionChannel();

  @override
  Future<bool> isActive(String id) async => false;

  /// Закрывать нечего: у заглушки нет ресурсов.
  @override
  // ignore: no-empty-block, у заглушки нет ресурсов для закрытия
  void close() {}
}

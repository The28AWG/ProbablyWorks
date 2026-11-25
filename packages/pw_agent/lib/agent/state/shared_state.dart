/// Общий ресурс, изменения которого должны доехать до всех окон и устройств.
///
/// Список фиксирует матрицу синхронизации: новый экран, который меняет общий
/// ресурс, обязан либо опубликовать событие из доменного сервиса, либо быть
/// описан здесь как локальный для окна. Область совпадает со строкой в SSE
/// `stateAreaChanged`, поэтому старые клиенты продолжают понимать событие.
enum SharedResource {
  /// Хосты: список и поля подключения.
  hosts(area: 'hosts'),

  /// Список чатов и их метаданные.
  chats(area: 'chats'),

  /// Проекты, их память, skills и профили политики.
  projects(area: 'projects'),

  /// Настройки агента, включая провайдеров и политику.
  settings(area: 'settings'),

  /// Каталог моделей и их доступность.
  models(area: 'models'),

  /// Конфигурация MCP-серверов и состояние подключений.
  mcp(area: 'mcp'),

  /// Включённость плагинов и их настройки.
  plugins(area: 'plugins'),

  /// Настройки push-уведомлений.
  push(area: 'push'),

  /// Сводка истории и результат очистки/сброса настроек.
  data(area: 'data');

  const SharedResource({required this.area});

  /// Значение `area` в событии `stateAreaChanged`.
  final String area;

  /// Восстанавливает ресурс из строки SSE. Неизвестная область — null:
  /// новый сервер не должен ломать старый клиент.
  static SharedResource? fromArea(String area) {
    for (final resource in values) {
      if (resource.area == area) return resource;
    }
    return null;
  }
}

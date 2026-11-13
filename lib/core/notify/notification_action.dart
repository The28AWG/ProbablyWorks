/// Действие, которое пользователь выбрал в системном уведомлении.
enum NotificationActionKind {
  /// Открыть чат, к которому относится уведомление.
  open,

  /// Разрешить действие агента один раз.
  approve,

  /// Отклонить действие агента.
  deny,
}

/// Контекст уведомления, нужный для действия.
///
/// [profileId] может быть null: уведомление пришло из локального агента,
/// который не знает профиль GUI. В этом случае используется локальный профиль.
final class NotificationActionRequest {
  const NotificationActionRequest({
    required this.action,
    this.profileId,
    this.chatId,
    this.approvalId,
  });

  final NotificationActionKind action;
  final String? profileId;
  final String? chatId;
  final String? approvalId;
}

/// Обработчик действий уведомлений. Живёт в UI-слое: только он знает профили
/// и умеет открыть чат.
typedef NotificationActionHandler = Future<void> Function(
  NotificationActionRequest request,
);

/// Реализация [AppNotifier] может принимать обработчик действий.
///
/// Отдельный интерфейс, чтобы `ProfileService` и начальная загрузка не зависели
/// от Flutter-плагина уведомлений.
abstract interface class NotificationActionSink {
  /// Установить обработчик. Если действие пришло до установки, реализация
  /// запоминает его и вызывает обработчик после регистрации.
  set actionHandler(NotificationActionHandler? handler);
}

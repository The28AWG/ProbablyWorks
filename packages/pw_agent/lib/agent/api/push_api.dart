/// Настройки push-уведомлений конкретного агента.
final class PushSettings {
  const PushSettings({
    this.enabled = false,
    this.relayUrl = '',
    this.hasToken = false,
    this.revision = 0,
  });

  final bool enabled;
  final String relayUrl;

  /// Токен релея не возвращается наружу: только факт, что он сохранён.
  final bool hasToken;

  /// Ревизия формы. Сохранение со старой ревизией не затирает настройки,
  /// изменённые в другом окне.
  final int revision;

  /// Push разрешён только при всех трёх условиях.
  bool get configured => enabled && relayUrl.trim().isNotEmpty && hasToken;

  PushSettings copyWith({
    bool? enabled,
    String? relayUrl,
    bool? hasToken,
    int? revision,
  }) => PushSettings(
    enabled: enabled ?? this.enabled,
    relayUrl: relayUrl ?? this.relayUrl,
    hasToken: hasToken ?? this.hasToken,
    revision: revision ?? this.revision,
  );

  @override
  String toString() =>
      'PushSettings(enabled: $enabled, relayUrl: $relayUrl, hasToken: $hasToken)';
}

/// Управление push-уведомлениями профиля.
///
/// Локальная реализация хранит настройки в БД агента, а токен — в
/// `SecretStore`. Удалённая — через HTTP профиля.
abstract interface class PushApi {
  Future<PushSettings> pushSettings();

  /// Сохраняет настройки. [token] пустой — оставить прежний токен.
  Future<void> savePush(
    PushSettings settings, {
    String? token,
    bool clearToken = false,
    int? expectedRevision,
  });

  /// Отправляет тестовое уведомление. Без полной конфигурации — ошибка.
  Future<void> testPush();
}

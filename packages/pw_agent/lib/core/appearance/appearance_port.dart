/// Применение языковых и тематических настроек после `settings_update`.
///
/// Агент не знает про Flutter-контроллеры: клиент передаёт адаптер, headless-демон —
/// no-op реализацию.
abstract interface class AppearancePort {
  /// [value] — `system`, `en` или `ru`.
  void applyLanguage(String value);

  /// [value] — `system`, `light` или `dark`.
  void applyThemeMode(String value);
}

import 'package:pw_agent/core/appearance/appearance_port.dart';

/// Запоминает настройки внешнего вида в тестах без Flutter-контроллеров.
// ignore: avoid-top-level-members-in-tests, нужен нескольким тестам
class FakeAppearance implements AppearancePort {
  String? language;
  String? themeMode;

  @override
  void applyLanguage(String value) => language = value;

  @override
  void applyThemeMode(String value) => themeMode = value;
}

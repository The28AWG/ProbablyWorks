import 'package:pw_agent/core/appearance/appearance_port.dart';

/// В демоне нет интерфейса, поэтому настройки внешнего вида никуда не применяются.
final class NoopAppearance implements AppearancePort {
  const NoopAppearance();

  @override
  void applyLanguage(String value) => value;

  @override
  void applyThemeMode(String value) => value;
}

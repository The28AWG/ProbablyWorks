import 'package:injectable/injectable.dart';
import 'package:probably_works/app/locale/locale_controller.dart';
import 'package:probably_works/app/theme/theme_controller.dart';
import 'package:pw_agent/core/appearance/appearance_port.dart';

/// Применяет `settings_update` к контроллерам интерфейса.
@LazySingleton(as: AppearancePort)
class ClientAppearancePort implements AppearancePort {
  ClientAppearancePort(this._locale, this._theme);

  final LocaleController _locale;
  final ThemeController _theme;

  @override
  void applyLanguage(String value) => _locale.apply(value);

  @override
  void applyThemeMode(String value) =>
      _theme.apply(ThemeController.modeFrom(value));
}

import 'package:flutter/widgets.dart';
import 'package:injectable/injectable.dart';

/// Язык интерфейса. null — как в системе; иначе код `ru` или `en`.
@singleton
class LocaleController extends ValueNotifier<Locale?> {
  LocaleController() : super(null);

  static const supported = [Locale('en'), Locale('ru')];

  void apply(String? code) {
    value = code == null || code.isEmpty || code == 'system'
        ? null
        : Locale(code);
  }
}

/// Локаль текста вне виджетов (фон, восстановление после перезапуска): выбор языка в настройках,
/// иначе системный язык, иначе английский.
Locale resolveAppLocale(String? code) {
  if (code != null && code.isNotEmpty && code != 'system') {
    return LocaleController.supported.firstWhere(
      (locale) => locale.languageCode == code,
      orElse: () => const Locale('en'),
    );
  }
  final system = WidgetsBinding.instance.platformDispatcher.locale;
  return LocaleController.supported.firstWhere(
    (locale) => locale.languageCode == system.languageCode,
    orElse: () => const Locale('en'),
  );
}

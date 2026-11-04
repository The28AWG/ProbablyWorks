import 'package:injectable/injectable.dart';
import 'package:material_ui/material_ui.dart';

/// Тема приложения: системная, светлая или тёмная. Выбор в настройках, [MaterialApp] слушает значение.
/// Сохранённое значение применяется при старте (см. bootstrap), дальше меняется через [apply].
@singleton
class ThemeController extends ValueNotifier<ThemeMode> {
  ThemeController() : super(ThemeMode.system);

  /// Разбирает значение из kv-таблицы (имя [ThemeMode]). Пустое или неизвестное значение даёт системную тему.
  static ThemeMode modeFrom(String? raw) =>
      ThemeMode.values.asNameMap()[raw] ?? ThemeMode.system;

  /// Меняет тему сразу: [MaterialApp] перестраивается по уведомлению.
  void apply(ThemeMode mode) => value = mode;
}

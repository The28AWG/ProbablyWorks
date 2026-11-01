import 'package:material_ui/material_ui.dart';

/// Тема приложения: Material 3, нейтральная палитра с акцентом для статусов агента.
abstract final class AppTheme {
  const AppTheme._();
  static const _seed = Color(0xFF3B5BDB);

  static final light = ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: _seed),
    useMaterial3: true,
    visualDensity: VisualDensity.compact,
    cardTheme: const CardThemeData(margin: EdgeInsets.zero),
  );

  static final dark = ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: Brightness.dark,
    ),
    useMaterial3: true,
    visualDensity: VisualDensity.compact,
    cardTheme: const CardThemeData(margin: EdgeInsets.zero),
  );
}

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/theme/theme_controller.dart';

void main() {
  test('modeFrom reads stored names and falls back to system', () {
    expect(ThemeController.modeFrom('light'), ThemeMode.light);
    expect(ThemeController.modeFrom('dark'), ThemeMode.dark);
    expect(ThemeController.modeFrom('system'), ThemeMode.system);
    expect(ThemeController.modeFrom(null), ThemeMode.system);
    expect(ThemeController.modeFrom(''), ThemeMode.system);
    expect(ThemeController.modeFrom('bogus'), ThemeMode.system);
  });

  test('apply notifies listeners with the new mode', () {
    final controller = ThemeController();
    final seen = <ThemeMode>[];
    controller
      ..addListener(() => seen.add(controller.value))
      ..apply(ThemeMode.dark)
      ..apply(ThemeMode.light);

    expect(seen, [ThemeMode.dark, ThemeMode.light]);
    expect(controller.value, ThemeMode.light);
  });
}

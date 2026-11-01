import 'dart:io';

import 'package:flutter/services.dart';
// FontLoader lives in flutter_test; this helper is only for golden/widget tests.
// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';

/// Загружает бандловые шрифты приложения, чтобы golden-эталоны совпадали с продуктом.
abstract final class GoldenFonts {
  GoldenFonts._();

  static Future<void> load() async {
    await _loadFont('Inter', [
      'assets/fonts/inter/Inter-Regular.ttf',
      'assets/fonts/inter/Inter-Medium.ttf',
      'assets/fonts/inter/Inter-SemiBold.ttf',
      'assets/fonts/inter/Inter-Bold.ttf',
    ]);
    await _loadFont('JetBrainsMono', [
      'assets/fonts/jetbrains_mono/JetBrainsMono-Regular.ttf',
      'assets/fonts/jetbrains_mono/JetBrainsMono-Medium.ttf',
      'assets/fonts/jetbrains_mono/JetBrainsMono-Bold.ttf',
    ]);
  }

  static Future<void> _loadFont(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final file in files) {
      final bytes = File(file).readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }
}

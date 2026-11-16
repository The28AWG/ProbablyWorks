import 'dart:math' as math;

import 'package:pw_agent/core/util/ansi_text.dart';
import 'package:pw_agent/core/util/char_substring.dart';

/// Обязательный строковый аргумент инструмента. Пустая строка — ошибка, а не
/// допустимое значение: иначе действие молча уйдёт не туда.
String toolStringArg(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value is! String || value.isEmpty) {
    throw ArgumentError.value(value, key, 'required string');
  }
  return value;
}

/// Необязательное целое. Дробные значения и значения ниже [min] — ошибка
/// аргумента, а не молчаливая подмена. Выше [max] значение обрезается: это
/// верхний предел формата ответа, а не запрет на запрос.
int toolIntArg(
  Map<String, dynamic> args,
  String key, {
  required int min,
  int? max,
  required int fallback,
}) {
  final value = args[key];
  if (value == null) return fallback;
  if (value is! num || value != value.toInt()) {
    throw ArgumentError.value(value, key, 'integer expected');
  }
  final number = value.toInt();
  if (number < min) {
    throw ArgumentError.value(value, key, 'must be at least $min');
  }
  return max == null ? number : math.min(number, max);
}

/// Однострочный предпросмотр текста для журнала и карточки подтверждения.
String previewToolText(String text, {int max = 200}) {
  final single = plainTerminalText(text).replaceAll(RegExp(r'\s+'), ' ').trim();
  return single.length <= max ? single : '${charPrefix(single, max)}…';
}

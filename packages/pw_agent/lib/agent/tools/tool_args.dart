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

/// Однострочный предпросмотр текста для журнала и карточки подтверждения.
String previewToolText(String text, {int max = 200}) {
  final single = plainTerminalText(text).replaceAll(RegExp(r'\s+'), ' ').trim();
  return single.length <= max ? single : '${charPrefix(single, max)}…';
}

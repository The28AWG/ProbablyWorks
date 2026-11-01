/// CSI (цвета, курсор), OSC (заголовок окна, гиперссылки) и короткие ESC-последовательности.
final _escape = RegExp(
  r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-Z\\-_])',
);

/// Текст терминального вывода без управляющих последовательностей: для модели и превью.
/// Убирает escape-последовательности. Строка, перерисованная через возврат каретки
/// (индикатор прогресса), сохраняет последний видимый вариант.
String plainTerminalText(String text) {
  final lines = text.replaceAll(_escape, '').split('\n');
  final buffer = StringBuffer();
  for (var i = 0; i < lines.length; i++) {
    if (i > 0) buffer.write('\n');
    final parts = lines[i].split('\r');
    buffer.write(parts.lastWhere((part) => part.isNotEmpty, orElse: () => ''));
  }
  return buffer.toString();
}

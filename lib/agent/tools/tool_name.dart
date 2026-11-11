/// Максимальная длина имени инструмента у провайдеров моделей.
const maxToolNameLength = 64;

/// Приводит имя внешнего инструмента к лимиту провайдера.
///
/// Длинное имя обрезается и получает детерминированный хвост из FNV-1a:
/// два разных инструмента с общим префиксом не столкнутся в обычном случае,
/// а имя остаётся стабильным между запусками.
String fitToolName(String value) {
  if (value.length <= maxToolNameLength) return value;
  final suffix = '_${_fnv1a(value).toRadixString(16).padLeft(8, '0')}';
  final keep = maxToolNameLength - suffix.length;
  return '${String.fromCharCodes(value.codeUnits.take(keep))}$suffix';
}

int _fnv1a(String value) {
  var hash = 0x811c9dc5;
  for (final code in value.codeUnits) {
    hash ^= code;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}

/// Размер в человекочитаемом виде: `1.5 GB`, `420 MB`.
///
/// Используется в настройках данных и локальных моделях, чтобы одинаковые
/// числа не форматировались по-разному на соседних вкладках.
String formatByteSize(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = unit == 0
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(value >= 100 ? 0 : 1);
  return '$text ${units[unit]}';
}

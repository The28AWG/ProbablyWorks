/// Нормализованный текст для поиска: нижний регистр, `ё` → `е`, слова через
/// пробел. Пунктуация не участвует.
String normalizeSearchText(String text) => text
    .toLowerCase()
    .replaceAll('ё', 'е')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

/// Оценка одного поля под один термин запроса. 0 — совпадения нет.
double scoreSearchText(String text, String term) {
  final value = normalizeSearchText(text);
  final needle = normalizeSearchText(term);
  if (value.isEmpty || needle.isEmpty) return 0;
  if (value == needle) return 1;
  if (value.startsWith(needle)) return 0.95;
  final words = value.split(' ');
  if (words.any((word) => word.startsWith(needle))) return 0.9;
  if (value.contains(needle)) return 0.8;
  if (needle.length < 4) return 0;
  final maxDistance = needle.length >= 8 ? 2 : 1;
  if (words.any((word) => _distance(word, needle) <= maxDistance)) {
    return 0.5;
  }
  if (needle.length >= 6 && _distance(value, needle) <= 2) return 0.35;
  return 0;
}

/// Расстояние Левенштейна с ранним выходом по [max].
int _distance(String a, String b, {int max = 2}) {
  if ((a.length - b.length).abs() > max) return max + 1;
  var previous = List<int>.generate(b.length + 1, (index) => index);
  for (var i = 1; i <= a.length; i++) {
    final current = List<int>.filled(b.length + 1, 0);
    current[0] = i;
    var rowMin = current.first;
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      final value = [
        previous[j] + 1,
        current[j - 1] + 1,
        previous[j - 1] + cost,
      ].reduce((left, right) => left < right ? left : right);
      current[j] = value;
      if (value < rowMin) rowMin = value;
    }
    if (rowMin > max) return max + 1;
    previous = current;
  }
  return previous.last;
}

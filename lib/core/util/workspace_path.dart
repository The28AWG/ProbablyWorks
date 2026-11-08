/// Каноническая форма рабочей папки для ключа проекта.
///
/// Ключ проекта — пара «хост + папка». Одна и та же папка может быть записана по-разному
/// (`~/repo`, `/home/user/repo/`, `repo/../repo`), поэтому перед поиском проекта путь
/// приводится к лексической форме. Симлинки и `~` на удалённом хосте раскрывает `RealpathOp`,
/// а этот модуль даёт запасной вариант, когда хост недоступен.
library;

/// Приводит путь к лексической канонической форме.
///
/// Раскрывает `.` и `..`, убирает повторные и хвостовые разделители. `~` остаётся как есть:
/// его раскрывает Host, а не приложение (у удалённого хоста свой домашний каталог).
/// На Windows разделители приводятся к `/`, а регистр понижается: путь там регистронезависим.
String normalizeWorkspacePath(String path, {required bool windows}) {
  var value = path.trim();
  if (value.isEmpty) return '~';
  if (windows) value = value.replaceAll(r'\', '/');

  // Буква диска не должна попасть в общий разбор: `C:` — не сегмент пути.
  var drive = '';
  if (windows) {
    final match = RegExp(r'^([A-Za-z]:)(/|$)').firstMatch(value);
    if (match != null) {
      drive = match.group(1)!.toUpperCase();
      value = value.replaceFirst(match.group(1)!, '');
    }
  }

  final absolute = value.startsWith('/');
  final parts = <String>[];
  for (final segment in value.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (parts.isNotEmpty && parts.last != '..') {
        parts.removeLast();
      } else if (!absolute) {
        parts.add('..');
      }
      continue;
    }
    parts.add(segment);
  }

  var result = parts.join('/');
  if (absolute) result = '/$result';
  result = '$drive$result';
  if (result.isEmpty) result = '/';
  return windows ? result.toLowerCase() : result;
}

/// Имя проекта по умолчанию: последняя папка пути. Корень и `~` дают сам путь.
String projectNameFor(String workspace) {
  final parts = workspace
      .split(RegExp(r'[/\\]'))
      .where((part) => part.isNotEmpty)
      .toList();
  return parts.isEmpty ? workspace : parts.last;
}

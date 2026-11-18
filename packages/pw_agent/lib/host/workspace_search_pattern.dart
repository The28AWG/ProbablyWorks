/// Преобразование пользовательского запроса в шаблоны для поиска файлов.
///
/// Пользователь вводит `rdm` и ждёт `README.md`: это поиск по подпоследовательности,
/// а не по подстроке. Один и тот же запрос компилируется в glob для `find`,
/// regex для git/PowerShell и прямую проверку для виртуального Host.
abstract final class WorkspaceSearchPattern {
  const WorkspaceSearchPattern._();

  /// Каталоги, которые не показываются даже при явном поиске.
  static const noiseDirectories = {
    '.git',
    '.hg',
    '.svn',
    'node_modules',
    'build',
    '.dart_tool',
    '.idea',
    '.vscode',
    'target',
    'dist',
    'venv',
    '.venv',
    '__pycache__',
    '.next',
    '.cache',
  };

  /// Glob вида `*r*d*m*`: `find -iname` и виртуальный матчер.
  static String glob(String query) {
    final chars = _searchChars(query);
    if (chars.isEmpty) return '*';
    final buffer = StringBuffer('*');
    for (final char in chars) {
      buffer
        ..write(_escapeGlob(char))
        ..write('*');
    }
    return buffer.toString();
  }

  /// Regex вида `r.*d.*m`: git/PowerShell и подсказки.
  static String regex(String query) {
    final chars = _searchChars(query);
    if (chars.isEmpty) return '.*';
    return chars.map(RegExp.escape).join('.*');
  }

  /// Совпадает ли путь с запросом. Если запрос содержит `/`, проверяется
  /// полный относительный путь; иначе — только последний сегмент.
  static bool matches(String path, String query) {
    final needle = _searchChars(query);
    if (needle.isEmpty) return true;
    final normalizedPath = path.replaceAll(r'\', '/');
    final haystack = query.contains('/')
        ? normalizedPath
        : normalizedPath.split('/').last;
    final lower = haystack.toLowerCase();
    var index = 0;
    for (final rune in lower.runes) {
      if (index >= needle.length) break;
      if (String.fromCharCode(rune) == needle[index]) index++;
    }
    return index == needle.length;
  }

  /// Скрытый ли путь: любой сегмент начинается с точки. Корень `.` не считается.
  static bool isHidden(String path) => path
      .replaceAll(r'\', '/')
      .split('/')
      .any((segment) => segment.length > 1 && segment.startsWith('.'));

  /// Запрос ищет скрытые файлы: начинается с точки или содержит `/.`.
  static bool searchesHidden(String query) =>
      query.startsWith('.') || query.contains('/.');

  static List<String> _searchChars(String query) => [
    for (final rune in query.trim().toLowerCase().runes)
      if (!_isSpace(rune)) String.fromCharCode(rune),
  ];

  static bool _isSpace(int rune) => String.fromCharCode(rune).trim().isEmpty;

  static String _escapeGlob(String char) => switch (char) {
    '*' || '?' || '[' || ']' || r'\' => '\\$char',
    _ => char,
  };
}

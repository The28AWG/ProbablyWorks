/// Пути виртуальной файловой системы. Канонический путь абсолютный, с разделителем `/`, без `.`, `..`
/// и повторных слэшей. Все проверки и хранение опираются на каноническую форму, поэтому одна и та же
/// запись не может появиться под двумя именами.
abstract final class VfsPath {
  const VfsPath._();

  static const root = '/';

  /// Канонический путь. Относительный [path] считается от [cwd]. `..` над корнем остаётся в корне.
  static String normalize(String path, {String cwd = root}) {
    final full = path.startsWith('/') ? path : '$cwd/$path';
    final parts = <String>[];
    for (final segment in full.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (parts.isNotEmpty) {
          parts.removeLast();
        }
        continue;
      }
      parts.add(segment);
    }
    return parts.isEmpty ? root : '/${parts.join('/')}';
  }

  /// Имена компонентов канонического пути. Для корня — пустой список.
  static List<String> segments(String canonical) =>
      canonical.split('/').where((s) => s.isNotEmpty).toList();

  /// Путь дочернего имени внутри каталога [dir] (канонического).
  static String join(String dir, String name) =>
      dir == root ? '/$name' : '$dir/$name';

  /// Родительский каталог канонического пути. Для корня — сам корень.
  static String parent(String canonical) {
    if (canonical == root) return root;
    final parts = segments(canonical);
    return parts.length <= 1
        ? root
        : '/${parts.sublist(0, parts.length - 1).join('/')}';
  }

  /// Последний компонент канонического пути. Для корня — пустая строка.
  static String name(String canonical) =>
      canonical == root ? '' : segments(canonical).last;
}

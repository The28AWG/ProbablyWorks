// ignore_for_file: avoid-substring
// Причина: пути git — байты ASCII, не текст с эмодзи.
import 'package:virtual_git/src/git_host_io.dart';

/// Пути git всегда с разделителем `/`.
///
/// `package:path` на Windows подставил бы `\`, и та же строка перестала бы быть
/// путём виртуальной ФС. Набор операций — тот, что скопированный репозиторий
/// вызывает как `p.*` и `p.posix.*`.
const posix = GitPosixPath();

/// Соединяет части пути. Абсолютная часть отбрасывает всё, что было левее.
String join(String part1, [String? part2, String? part3, String? part4]) =>
    posix.join(part1, part2, part3, part4);

/// Убирает `.`, `..` и повторные слэши. Относительный путь остаётся относительным.
String normalize(String path) => posix.normalize(path);

/// Абсолютный путь от текущего каталога привязки [GitIo], не от диска машины.
String absolute(String path) => posix.absolute(path);

/// Путь начинается с `/`.
bool isAbsolute(String path) => posix.isAbsolute(path);

/// [child] лежит строго внутри [parent], а не совпадает с ним.
bool isWithin(String parent, String child) => posix.isWithin(parent, child);

/// Последний компонент. Для корня — пустая строка.
String basename(String path) => posix.basename(path);

/// Родительский каталог. У относительного пути без слэша — `.`.
String dirname(String path) => posix.dirname(path);

/// Компоненты в стиле `package:path` для POSIX: корень — отдельный элемент `/`.
List<String> split(String path) => posix.split(path);

/// Путь от [from] к [path]. Одинаковые пути дают `.`.
String relative(String path, {String? from}) =>
    posix.relative(path, from: from);

/// Меняет расширение, включая точку: `pack-a.pack` и `.idx` дают `pack-a.idx`.
String setExtension(String path, String extension) =>
    posix.setExtension(path, extension);

/// Реализация POSIX-путей. Тот же объект торчит как [posix], чтобы вызовы
/// `p.posix.*` из скопированного кода не отличались от `p.*`.
final class GitPosixPath {
  const GitPosixPath();

  String join(String part1, [String? part2, String? part3, String? part4]) {
    final parts = <String>[part1, ?part2, ?part3, ?part4];
    return joinAll(parts);
  }

  String joinAll(Iterable<String> parts) {
    var result = '';
    for (final part in parts) {
      if (part.isEmpty) continue;
      if (isAbsolute(part) || result.isEmpty) {
        result = part;
        continue;
      }
      final left = result.endsWith('/')
          ? result.substring(0, result.length - 1)
          : result;
      final right = part.startsWith('/') ? part.substring(1) : part;
      result = '$left/$right';
    }
    return result;
  }

  String normalize(String path) {
    if (path.isEmpty) return '.';
    final absolutePath = isAbsolute(path);
    final parts = <String>[];
    for (final segment in path.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (parts.isNotEmpty && parts.last != '..') {
          parts.removeLast();
        } else if (!absolutePath) {
          parts.add('..');
        }
        continue;
      }
      parts.add(segment);
    }
    if (parts.isEmpty) return absolutePath ? '/' : '.';
    final joined = parts.join('/');
    return absolutePath ? '/$joined' : joined;
  }

  String absolute(String path) {
    if (isAbsolute(path)) return normalize(path);
    final base = gitIoCwd;
    if (base == '/') return normalize('/$path');
    return normalize('$base/$path');
  }

  bool isAbsolute(String path) => path.startsWith('/');

  bool isWithin(String parent, String child) {
    final parentPath = normalize(parent);
    final childPath = normalize(child);
    if (parentPath == childPath) return false;
    final prefix = parentPath == '/' ? '/' : '$parentPath/';
    return childPath.startsWith(prefix);
  }

  String basename(String path) {
    final normalized = normalize(path);
    if (normalized == '/' || normalized == '.') return '';
    final slash = normalized.lastIndexOf('/');
    if (slash < 0) return normalized;
    return normalized.substring(slash + 1);
  }

  String dirname(String path) {
    final normalized = normalize(path);
    if (normalized == '/' || normalized == '.') return normalized;
    final slash = normalized.lastIndexOf('/');
    if (slash < 0) return '.';
    if (slash == 0) return '/';
    return normalized.substring(0, slash);
  }

  List<String> split(String path) {
    final normalized = normalize(path);
    if (normalized == '/') return const ['/'];
    if (normalized == '.') return const ['.'];
    if (isAbsolute(normalized)) {
      return [
        '/',
        ...normalized.split('/').where((segment) => segment.isNotEmpty),
      ];
    }
    return normalized.split('/');
  }

  String relative(String path, {String? from}) {
    final fromPath = normalize(absolute(from ?? '.'));
    final toPath = normalize(absolute(path));
    if (fromPath == toPath) return '.';
    final fromParts = fromPath == '/'
        ? const <String>[]
        : fromPath.split('/').where((segment) => segment.isNotEmpty).toList();
    final toParts = toPath == '/'
        ? const <String>[]
        : toPath.split('/').where((segment) => segment.isNotEmpty).toList();
    var common = 0;
    while (common < fromParts.length &&
        common < toParts.length &&
        fromParts[common] == toParts[common]) {
      common++;
    }
    final up = fromParts.length - common;
    final down = toParts.sublist(common);
    final segments = <String>[for (var i = 0; i < up; i++) '..', ...down];
    if (segments.isEmpty) return '.';
    return segments.join('/');
  }

  String setExtension(String path, String extension) {
    final slash = path.lastIndexOf('/');
    final name = slash < 0 ? path : path.substring(slash + 1);
    final dot = name.lastIndexOf('.');
    final stem = dot <= 0
        ? path
        : path.substring(0, path.length - (name.length - dot));
    final suffix = extension.isEmpty || extension.startsWith('.')
        ? extension
        : '.$extension';
    return '$stem$suffix';
  }
}

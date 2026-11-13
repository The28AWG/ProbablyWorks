/// Каноническая форма рабочей папки для ключа проекта и каталог команд.
///
/// Ключ проекта — пара «хост + явная папка». Одна и та же папка может быть записана
/// по-разному (`~/repo`, `/home/user/repo/`, `repo/../repo`), поэтому перед поиском проекта
/// путь приводится к лексической форме. Симлинки и `~` на удалённом хосте раскрывает
/// `RealpathOp`, а этот модуль даёт запасной вариант, когда хост недоступен.
///
/// Домашний каталог — только каталог команд, пока пользователь не выбрал папку и хост
/// не задаёт свою. Иначе все чаты без папки делили бы один проект: общую память и доверие
/// к `~/AGENTS.md`.
library;

import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/util/home_path.dart';

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

/// Папка, которую пользователь задал хосту. Null — у хоста нет своей папки,
/// и дом не подставляется в проект.
String? configuredHostWorkspace(Host host) {
  final value = host.defaultWorkspace?.trim();
  if (value == null || value.isEmpty) return null;
  return value;
}

/// Папка, которая выбирает проект: явная папка чата, иначе папка хоста.
/// Null — чат ни в какой проект не входит.
String? explicitProjectWorkspace(Host host, String? workspace) {
  final explicit = workspace?.trim();
  if (explicit != null && explicit.isNotEmpty) return explicit;
  return configuredHostWorkspace(host);
}

/// Каталог команд и относительных путей. Явная папка, затем папка хоста, затем дом.
///
/// Дом сюда входит, даже когда [explicitProjectWorkspace] вернул null: команды
/// должны где-то выполняться. В проект и в доверие к AGENTS.md этот путь не пишется.
String commandWorkspace(Host host, String? workspace) {
  final explicit = workspace?.trim();
  if (explicit != null && explicit.isNotEmpty) return explicit;
  return configuredHostWorkspace(host) ??
      (host.kind == HostKind.local ? expandHomePath('~') : '~');
}

/// Имя проекта по умолчанию: последняя папка пути. Корень и `~` дают сам путь.
String projectNameFor(String workspace) {
  final parts = workspace
      .split(RegExp(r'[/\\]'))
      .where((part) => part.isNotEmpty)
      .toList();
  return parts.isEmpty ? workspace : parts.last;
}

/// Подпись файла в заголовке read/write/edit.
///
/// Внутри [workspace] показывается только имя файла: полный путь в шапке не нужен,
/// папка и так известна. Снаружи папки путь остаётся целиком, иначе чужой файл
/// выглядит как свой. Относительный путь считается от папки, как его разрешает инструмент.
/// `..`, выходящий из папки, снаружи. Без папки путь не сокращается: дом проектом не является.
String projectFileLabel(
  String path, {
  String? workspace,
  bool windows = false,
}) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return path;
  final root = workspace?.trim();
  if (root == null || root.isEmpty) return trimmed;
  if (!_insideWorkspace(trimmed, root, windows: windows)) return trimmed;
  final name = projectNameFor(trimmed);
  return name.isEmpty ? trimmed : name;
}

/// [path] — сам [workspace] или файл внутри него. Сравнение лексическое, без симлинков.
bool _insideWorkspace(String path, String workspace, {required bool windows}) {
  final root = normalizeWorkspacePath(workspace, windows: windows);
  if (root.isEmpty || root == '/') return false;
  final full = _underWorkspace(path, root, windows: windows);
  if (full == root) return true;
  final prefix = root.endsWith('/') ? root : '$root/';
  return full.startsWith(prefix);
}

/// Абсолютный путь и `~` нормализуются как есть. Относительный дописывается к папке.
String _underWorkspace(String path, String root, {required bool windows}) {
  var file = path.trim();
  if (windows) file = file.replaceAll(r'\', '/');
  final drive = windows && RegExp(r'^[A-Za-z]:').hasMatch(file);
  final absolute = file.startsWith('/') || file.startsWith('~') || drive;
  if (absolute) return normalizeWorkspacePath(file, windows: windows);
  return normalizeWorkspacePath('$root/$file', windows: windows);
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:probably_works/host/virtual/shell/shell_arithmetic.dart';
import 'package:probably_works/host/virtual/shell/shell_ast.dart';
import 'package:probably_works/host/virtual/shell/shell_errors.dart';
import 'package:probably_works/host/virtual/shell/shell_state.dart';
import 'package:probably_works/host/virtual/vfs_path.dart';
import 'package:probably_works/host/virtual/vfs_store.dart';
import 'package:probably_works/host/virtual/virtual_fs.dart';

/// Происхождение символа при расширении. От него зависит, что делать дальше: резать по IFS и раскрывать
/// глоб или оставить как есть. Порядок повторяет bash.
enum _Kind {
  /// В кавычках, экранирован или результат тильды: не режется и не глобится.
  quoted,

  /// Литерал вне кавычек: глобится, но не режется (разделители в нём уже выделены лексером).
  literal,

  /// Результат параметра или подстановки вне кавычек: режется по IFS и глобится.
  expanded,

  /// Граница между позиционными параметрами `$@`: всегда разделяет поля, независимо от IFS. Не символ,
  /// в строку не попадает (в `text` превращается в пробел).
  boundary,
}

/// Символ поля с признаком происхождения. Пустой [ch] — маркер «поле существует, но пусто»
/// (`""`, `"$*"`), он нужен, потому что пустое поле из нерасширенного пустого значения не создаётся.
final class _Unit {
  const _Unit(this.ch, this.kind);

  final String ch;
  final _Kind kind;
}

const _marker = _Unit('', _Kind.quoted);

const _boundaryUnit = _Unit('', _Kind.boundary);

/// Раскрытие слов в порядке bash: тильда, параметры, подстановки, разбиение по IFS, глобы, удаление кавычек.
///
/// [fields] даёт поля для команды (с разбиением и глобами). [text] даёт одну строку без разбиения
/// и глобов: присваивания, цели перенаправлений для `<<<`, тело здесь-документа.
final class ShellExpander {
  ShellExpander({
    required this.state,
    required this.fs,
    required this.home,
    required this.substitute,
  });

  final ShellState state;
  final VirtualFs fs;

  /// Домашний каталог Host для `~`, если `$HOME` не задан.
  final String home;

  /// Выполняет подстановку `$(...)` и возвращает её stdout и код выхода.
  final Future<(Uint8List, int)> Function(ScriptNode script) substitute;

  /// Код выхода последней подстановки в слове. Нужен присваиванию без команды (`x=$(false)`).
  int? substitutionStatus;

  static const _defaultIfs = ' \t\n';

  /// Сколько записей прочитано глобом в этом раскрытии. Ограничивает обход больших каталогов.
  var _walked = 0;

  /// Поля слова: разбиение по IFS и раскрытие глобов для нерасширенных частей.
  Future<List<String>> fields(ShellWord word) async {
    final units = await _units(word.parts, quoted: false);
    final result = <String>[];
    for (final field in _split(units, state.get('IFS') ?? _defaultIfs)) {
      result.addAll(await _glob(field));
    }
    return result;
  }

  /// Поля и строка слова за один проход. Нужно цели перенаправления: при неоднозначности bash печатает
  /// исходный текст, а подстановку повторять нельзя (побочные эффекты).
  Future<(List<String>, String)> fieldsAndText(ShellWord word) async {
    final units = await _units(word.parts, quoted: false);
    final result = <String>[];
    for (final field in _split(units, state.get('IFS') ?? _defaultIfs)) {
      result.addAll(await _glob(field));
    }
    return (result, _plain(units));
  }

  /// Строка слова без разбиения и глобов, с удалёнными кавычками. Позиционные параметры склеиваются
  /// пробелами, как в присваивании `x=$@`.
  Future<String> text(ShellWord word) async {
    final units = await _units(word.parts, quoted: false);
    return _plain(units);
  }

  /// Совпадает ли [value] с образцом оператора `case`. Образец раскрывается без разбиения по IFS и без
  /// путей: `*` покрывает любые символы, включая `/`, как в bash.
  Future<bool> matchesPattern(ShellWord pattern, String value) async {
    final units = await _units(pattern.parts, quoted: false);
    return _segmentPattern(units).hasMatch(value);
  }

  static String _plain(List<_Unit> units) =>
      units.map((u) => u.kind == _Kind.boundary ? ' ' : u.ch).join();

  Future<List<_Unit>> _units(
    List<WordPart> parts, {
    required bool quoted,
  }) async {
    final out = <_Unit>[];
    for (final part in parts) {
      await _addPart(part, out, quoted: quoted);
    }
    return out;
  }

  Future<void> _addPart(
    WordPart part,
    List<_Unit> out, {
    required bool quoted,
  }) async {
    switch (part) {
      case LiteralPart(:final text, quoted: final isQuoted):
        final kind = quoted || isQuoted ? _Kind.quoted : _Kind.literal;
        if (text.isEmpty) {
          if (kind == _Kind.quoted) out.add(_marker);
          return;
        }
        _addText(text, kind, out);
      case TildePart():
        _addText(state.get('HOME') ?? home, _Kind.quoted, out);
      case ParamPart(:final name) when name == '@' || name == '*':
        _addPositionals(name, quoted: quoted, out: out);
      case ParamPart(:final name):
        _addText(_param(name), _kindOf(quoted), out);
      case ArithmeticPart(:final expression):
        final source = await text(expression);
        final value = ShellArithmetic.evaluate(
          source,
          (name) => state.get(name),
        );
        _addText('$value', _kindOf(quoted), out);
      case CommandPart(:final script):
        final (bytes, status) = await substitute(script);
        substitutionStatus = status;
        // bash ставит $? по результату подстановки, поэтому `$(exit 3)$?` даёт 3.
        state.lastStatus = status;
        final output = utf8.decode(bytes, allowMalformed: true);
        _addText(
          output.replaceFirst(RegExp(r'\n+$'), ''),
          _kindOf(quoted),
          out,
        );
      case QuotedPart(:final parts):
        final before = out.length;
        for (final inner in parts) {
          await _addPart(inner, out, quoted: true);
        }
        // `"$@"` без параметров не даёт ни одного поля, а любое другое пустое `"..."` даёт одно пустое.
        final onlyAt = switch (parts) {
          [ParamPart(name: '@')] => true,
          _ => false,
        };
        if (out.length == before && !onlyAt) out.add(_marker);
    }
  }

  /// `$@` и `$*` (с [quoted] — внутри кавычек). `"$@"` даёт по полю на каждый параметр, даже пустой; `"$*"`
  /// склеивает их первым символом IFS. Без кавычек параметры режутся по IFS, пустые пропадают, как в bash.
  void _addPositionals(
    String name, {
    required bool quoted,
    required List<_Unit> out,
  }) {
    final args = state.positional;
    if (args.isEmpty) return;
    if (name == '*' && quoted) {
      final ifs = state.get('IFS') ?? _defaultIfs;
      _addText(args.join(ifs.isEmpty ? '' : ifs[0]), _Kind.quoted, out);
      return;
    }
    final kind = quoted ? _Kind.quoted : _Kind.expanded;
    for (var k = 0; k < args.length; k++) {
      if (k > 0) out.add(_boundaryUnit);
      if (args[k].isNotEmpty) {
        _addText(args[k], kind, out);
      } else if (quoted) {
        out.add(_marker);
      }
    }
  }

  _Kind _kindOf(bool quoted) => quoted ? _Kind.quoted : _Kind.expanded;

  void _addText(String text, _Kind kind, List<_Unit> out) {
    for (final rune in text.runes) {
      out.add(_Unit(String.fromCharCode(rune), kind));
    }
  }

  /// Значение параметра. Позиционные (`$1`) берутся из аргументов функции и пусты на верхнем уровне, как у
  /// `bash -c` без аргументов. `$0` — имя оболочки.
  String _param(String name) {
    switch (name) {
      case '?':
        return '${state.lastStatus}';
      case '\$':
        return '1';
      case '0':
        return 'bash';
      case '#':
        return '${state.positional.length}';
      case '-':
        return 'hB';
      case '!':
        return '';
    }
    if (RegExp(r'^[0-9]+$').hasMatch(name)) {
      // Номер за пределами int просто пуст: такого параметра нет.
      final index = (int.tryParse(name) ?? 0) - 1;
      final args = state.positional;
      return index >= 0 && index < args.length ? args[index] : '';
    }
    return state.get(name) ?? '';
  }

  /// Разбивает поля по IFS. Пробельные разделители схлопываются, непробельный ставит границу всегда
  /// (`a::b` даёт три поля, как в bash). Кавычки и литералы не режутся.
  /// Границы [_Kind.boundary] (между параметрами `$@`) делят вход на группы; каждая группа режется по IFS.
  List<List<_Unit>> _split(List<_Unit> units, String ifs) {
    final fields = <List<_Unit>>[];
    var group = <_Unit>[];
    for (final unit in units) {
      if (unit.kind == _Kind.boundary) {
        fields.addAll(_splitByIfs(group, ifs));
        group = <_Unit>[];
      } else {
        group.add(unit);
      }
    }
    fields.addAll(_splitByIfs(group, ifs));
    return fields;
  }

  List<List<_Unit>> _splitByIfs(List<_Unit> units, String ifs) {
    if (ifs.isEmpty) {
      return [if (units.isNotEmpty || units.any((u) => u.ch.isEmpty)) units];
    }
    final fields = <List<_Unit>>[];
    var current = <_Unit>[];
    var marked = false;
    for (final unit in units) {
      if (unit.ch.isEmpty) {
        marked = true;
        continue;
      }
      final isSeparator = unit.kind == _Kind.expanded && ifs.contains(unit.ch);
      if (!isSeparator) {
        current.add(unit);
        if (unit.kind == _Kind.quoted) marked = true;
        continue;
      }
      if (_isWhitespace(unit.ch)) {
        if (current.isNotEmpty || marked) {
          fields.add(current);
          current = <_Unit>[];
          marked = false;
        }
      } else {
        fields.add(current);
        current = <_Unit>[];
        marked = false;
      }
    }
    if (current.isNotEmpty || marked) fields.add(current);
    return fields;
  }

  static bool _isWhitespace(String ch) => ch == ' ' || ch == '\t' || ch == '\n';

  /// Глоб для одного поля. Без активных метасимволов или без совпадений поле возвращается как есть
  /// (`nullglob` выключен, как в bash по умолчанию).
  Future<List<String>> _glob(List<_Unit> field) async {
    final plain = field.map((u) => u.ch).join();
    if (!field.any(_isActiveMeta)) return [plain];
    final matches = await _matches(field);
    if (matches.isEmpty) return [plain];
    matches.sort();
    return matches;
  }

  static bool _isActiveMeta(_Unit u) =>
      u.kind != _Kind.quoted && (u.ch == '*' || u.ch == '?' || u.ch == '[');

  Future<List<String>> _matches(List<_Unit> field) async {
    final absolute = field.isNotEmpty && field.first.ch == '/';
    final dirOnly = field.isNotEmpty && field.last.ch == '/';
    final segments = <List<_Unit>>[[]];
    for (final unit in field) {
      if (unit.ch == '/') {
        segments.add([]);
      } else {
        segments.last.add(unit);
      }
    }
    var candidates = [absolute ? VfsPath.root : ''];
    for (final segment in segments) {
      if (segment.isEmpty) continue;
      final hasMeta = segment.any(_isActiveMeta);
      final literal = segment.map((u) => u.ch).join();
      final pattern = hasMeta ? _segmentPattern(segment) : null;
      // Скрытые имена (с точкой) глоб не раскрывает, если шаблон не начинается с точки.
      final allowHidden = segment.first.ch == '.';
      final next = <String>[];
      for (final base in candidates) {
        if (pattern == null) {
          final path = _join(base, literal);
          if (await fs.stat(path, cwd: state.cwd) != null) next.add(path);
          continue;
        }
        for (final child in await _children(base)) {
          if (child.name.startsWith('.') && !allowHidden) continue;
          if (pattern.hasMatch(child.name)) next.add(_join(base, child.name));
        }
      }
      candidates = next;
    }
    final result = <String>[];
    for (final path in candidates) {
      if (!dirOnly) {
        result.add(path);
        continue;
      }
      final node = await fs.stat(path, cwd: state.cwd);
      if (node?.kind == VfsNodeKind.dir) result.add('$path/');
    }
    return result;
  }

  /// Дети каталога для обхода. Не каталог или отсутствующий путь — пустой список, как у глоба в shell.
  /// Счётчик записей ограничивает обход больших каталогов.
  Future<List<VfsNode>> _children(String base) async {
    final List<VfsNode> children;
    try {
      children = await fs.list(base.isEmpty ? '.' : base, cwd: state.cwd);
    } on VfsException {
      return const [];
    }
    _walked += children.length;
    if (_walked > fs.limits.maxWalkEntries) {
      throw ShellLimitExceeded(
        'glob matches too many files (limit ${fs.limits.maxWalkEntries})',
      );
    }
    return children;
  }

  static String _join(String base, String name) {
    if (base.isEmpty) return name;
    if (base.endsWith('/')) return '$base$name';
    return '$base/$name';
  }

  /// Регулярное выражение для одного сегмента пути. Кавычки делают символ буквальным.
  /// Скобочное выражение без закрывающей `]` трактуется как литерал `[`, как в bash.
  static RegExp _segmentPattern(List<_Unit> segment) {
    final buffer = StringBuffer('^');
    var i = 0;
    while (i < segment.length) {
      final unit = segment[i];
      if (unit.kind == _Kind.quoted) {
        buffer.write(RegExp.escape(unit.ch));
        i++;
        continue;
      }
      if (unit.ch == '*') {
        buffer.write('.*');
      } else if (unit.ch == '?') {
        buffer.write('.');
      } else if (unit.ch == '[') {
        final bracket = _bracket(segment, i);
        if (bracket == null) {
          buffer.write(RegExp.escape('['));
        } else {
          buffer.write(bracket.$1);
          i = bracket.$2;
          continue;
        }
      } else {
        buffer.write(RegExp.escape(unit.ch));
      }
      i++;
    }
    buffer.write(r'$');
    return RegExp(buffer.toString(), dotAll: true);
  }

  /// Скобочное выражение `[...]` начиная с [open]: регулярное выражение и индекс за `]`.
  /// Возвращает null, если выражение не закрыто или пусто.
  static (String, int)? _bracket(List<_Unit> segment, int open) {
    var j = open + 1;
    var negate = false;
    if (j < segment.length && (segment[j].ch == '!' || segment[j].ch == '^')) {
      negate = true;
      j++;
    }
    final content = StringBuffer();
    var first = true;
    while (j < segment.length) {
      final ch = segment[j].ch;
      if (ch == ']' && !first) break;
      first = false;
      // Дефис оставляем как есть, чтобы работали диапазоны `a-z`.
      content.write(ch == '-' ? '-' : RegExp.escape(ch));
      j++;
    }
    if (j >= segment.length || content.isEmpty) return null;
    return ('[${negate ? '^' : ''}$content]', j + 1);
  }
}

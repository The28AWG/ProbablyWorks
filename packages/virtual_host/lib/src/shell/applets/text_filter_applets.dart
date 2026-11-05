import 'dart:convert';
import 'dart:typed_data';

import 'package:virtual_host/src/posix_regex.dart';
import 'package:virtual_host/src/shell/applets/applet.dart';
import 'package:virtual_host/src/shell/applets/applet_args.dart';
import 'package:virtual_host/src/shell/shell_io.dart';
import 'package:virtual_host/src/vfs_store.dart';

/// Фильтры текста: поиск по шаблону, сортировка, уникальные строки, выбор полей и замена символов.
final List<Applet> filterApplets = [
  const _Grep(),
  const _Sort(),
  const _Uniq(),
  const _Cut(),
  const _Tr(),
];

/// `grep [-ivcnlLEFwxoqHhsrR] [-A N] [-B N] [-C N] [-e PATTERN]... [-f FILE] [PATTERN] [FILE...]`.
/// По умолчанию BRE (как у GNU grep), `-E` — расширенный синтаксис, `-F` — строки буквально.
/// Бинарные файлы не выделяются: байты декодируются как UTF-8 с заменой. Код 0 — есть совпадение,
/// 1 — нет, 2 — ошибка.
final class _Grep implements Applet {
  const _Grep();

  @override
  String get name => 'grep';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, flags: 'ivcnlLEFwxoqHhsrR', valued: 'efABC');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    final patterns = <String>[];
    var operands = parsed.operands;
    if (parsed.valuesOf('e').isEmpty && parsed.valuesOf('f').isEmpty) {
      if (operands.isEmpty) return usageError(io, name, 'no pattern given');
      patterns.add(operands.first);
      operands = operands.sublist(1);
    }
    patterns.addAll(parsed.valuesOf('e'));
    for (final file in parsed.valuesOf('f')) {
      final bytes = await readSource(io, name, file);
      if (bytes == null) return 2;
      patterns.addAll(splitText(bytes).lines);
    }
    final RegExp matcher;
    try {
      matcher = _compile(parsed, patterns);
    } on FormatException catch (e) {
      io.stderr.writeText('$name: ${e.message}\n');
      return 2;
    }
    final recursive = parsed.has('r') || parsed.has('R');
    final resolved = await _inputs(io, operands, recursive: recursive);
    final withNames =
        !parsed.has('h') &&
        (parsed.has('H') || resolved.length > 1 || recursive);
    final options = _GrepOptions(
      matcher: matcher,
      invert: parsed.has('v'),
      count: parsed.has('c'),
      number: parsed.has('n'),
      listMatches: parsed.has('l'),
      listNonMatches: parsed.has('L'),
      onlyMatching: parsed.has('o'),
      quiet: parsed.has('q'),
      names: withNames,
      before: _context(parsed.value('B') ?? parsed.value('C'), 'B', io),
      after: _context(parsed.value('A') ?? parsed.value('C'), 'A', io),
    );
    var anySelected = false;
    var status = 0;
    for (final input in resolved) {
      final bytes = input.bytes ?? await readSource(io, name, input.path);
      if (bytes == null) {
        // Код 2 при ошибке остаётся и с `-s`: `-s` прячет только сообщение.
        status = 2;
        continue;
      }
      final selected = _search(
        io,
        input.label,
        splitText(bytes).lines,
        options,
      );
      if (selected) anySelected = true;
      if (options.quiet && anySelected) return 0;
    }
    if (status != 0) return status;
    return anySelected ? 0 : 1;
  }

  /// Файлы для поиска. Каталог без `-r` — ошибка, с `-r` — все обычные файлы внутри (без симлинков).
  /// Без операндов: stdin, а с `-r` — текущий каталог.
  static Future<List<_Input>> _inputs(
    AppletIo io,
    List<String> operands, {
    required bool recursive,
  }) async {
    if (operands.isEmpty) {
      if (recursive) return _walk(io, '.', '');
      return [_Input(path: '-', label: '(standard input)', bytes: io.stdin)];
    }
    final inputs = <_Input>[];
    for (final operand in operands) {
      final node = await io.fs.stat(operand, cwd: io.cwd);
      if (node?.kind == VfsNodeKind.dir) {
        if (recursive) {
          inputs.addAll(await _walk(io, operand, '$operand/'));
        } else {
          io.stderr.writeText('grep: $operand: Is a directory\n');
        }
        continue;
      }
      inputs.add(_Input(path: operand, label: operand));
    }
    return inputs;
  }

  static Future<List<_Input>> _walk(
    AppletIo io,
    String dir,
    String prefix,
  ) async {
    final found = <_Input>[];
    final children = [...await io.fs.list(dir, cwd: io.cwd)]
      ..sort((a, b) => a.name.compareTo(b.name));
    for (final child in children) {
      final display = '$prefix${child.name}';
      if (child.kind == VfsNodeKind.dir) {
        found.addAll(await _walk(io, '$dir/${child.name}', '$display/'));
      } else if (child.kind == VfsNodeKind.file) {
        found.add(_Input(path: '$dir/${child.name}', label: display));
      }
    }
    return found;
  }

  static RegExp _compile(ParsedArgs parsed, List<String> patterns) {
    final alternatives = <String>[];
    for (final pattern in patterns) {
      var source = _source(parsed, pattern);
      if (parsed.has('x')) {
        source = '^(?:$source)\$';
      } else if (parsed.has('w')) {
        source = '(?<![A-Za-z0-9_])(?:$source)(?![A-Za-z0-9_])';
      }
      alternatives.add('(?:$source)');
    }
    // Без шаблонов (пустой -f) ничего не совпадает, а не совпадает всё.
    final combined = alternatives.isEmpty ? r'(?!)' : alternatives.join('|');
    return RegExp(combined, caseSensitive: !parsed.has('i'));
  }

  /// Исходный текст шаблона: `-F` — буквально, `-E` — как Dart (близко к ERE), иначе BRE.
  static String _source(ParsedArgs parsed, String pattern) {
    if (parsed.has('F')) return RegExp.escape(pattern);
    if (parsed.has('E')) return pattern;
    return PosixRegex.breSource(pattern);
  }

  static int _context(String? value, String side, AppletIo io) {
    if (value == null) return 0;
    final count = int.tryParse(value);
    if (count == null || count < 0) {
      io.stderr.writeText('grep: $side: invalid context length argument\n');
      return 0;
    }
    return count;
  }

  /// Печатает результат для одного входа. Возвращает true, если в нём есть выбранные строки.
  static bool _search(
    AppletIo io,
    String label,
    List<String> lines,
    _GrepOptions options,
  ) {
    final selected = <int>[];
    for (var i = 0; i < lines.length; i++) {
      io.checkpoint();
      if (options.matcher.hasMatch(lines[i]) != options.invert) selected.add(i);
    }
    if (options.quiet) return selected.isNotEmpty;
    if (options.count) {
      io.stdout.writeText(
        options.names ? '$label:${selected.length}\n' : '${selected.length}\n',
      );
    }
    if (options.listMatches) {
      if (selected.isNotEmpty) io.stdout.writeText('$label\n');
      return selected.isNotEmpty;
    }
    if (options.listNonMatches) {
      if (selected.isEmpty) io.stdout.writeText('$label\n');
      return selected.isNotEmpty;
    }
    if (options.count) return selected.isNotEmpty;
    // Строки для вывода: выбранные плюс контекст. Разрыв между группами печатается как `--`.
    final shown = <int>{};
    for (final index in selected) {
      final from = index - options.before < 0 ? 0 : index - options.before;
      final to = index + options.after >= lines.length
          ? lines.length - 1
          : index + options.after;
      for (var i = from; i <= to; i++) {
        shown.add(i);
      }
    }
    final selectedSet = selected.toSet();
    final ordered = shown.toList()..sort();
    final contextOn = options.before > 0 || options.after > 0;
    int? last;
    for (final index in ordered) {
      if (contextOn && last != null && index != last + 1) {
        io.stdout.writeText('--\n');
      }
      last = index;
      final isSelected = selectedSet.contains(index);
      final number = options.number
          ? '${index + 1}${isSelected ? ':' : '-'}'
          : '';
      if (options.onlyMatching) {
        if (!isSelected || options.invert) continue;
        for (final match in options.matcher.allMatches(lines[index])) {
          if (match.group(0)!.isEmpty) continue;
          final head = options.names ? '$label:' : '';
          io.stdout.writeText('$head$number${match.group(0)}\n');
        }
        continue;
      }
      final sep = contextOn && !isSelected ? '-' : ':';
      final head = options.names ? '$label$sep' : '';
      final numberPart = options.number ? '${index + 1}$sep' : '';
      io.stdout.writeText('$head$numberPart${lines[index]}\n');
    }
    return selected.isNotEmpty;
  }
}

/// Вход `grep`: путь для чтения, отображаемое имя и уже известные байты (stdin).
final class _Input {
  const _Input({required this.path, required this.label, this.bytes});

  final String path;
  final String label;
  final Uint8List? bytes;
}

/// Параметры поиска `grep`, собранные из опций один раз.
final class _GrepOptions {
  const _GrepOptions({
    required this.matcher,
    required this.invert,
    required this.count,
    required this.number,
    required this.listMatches,
    required this.listNonMatches,
    required this.onlyMatching,
    required this.quiet,
    required this.names,
    required this.before,
    required this.after,
  });

  final RegExp matcher;
  final bool invert;
  final bool count;
  final bool number;
  final bool listMatches;
  final bool listNonMatches;
  final bool onlyMatching;
  final bool quiet;
  final bool names;
  final int before;
  final int after;
}

/// `sort [-rnu] [-t SEP] [-k N[,M]]`: сортировка строк по всей строке или по полю. Порядок — байтовый,
/// как в локали C. Для ключа с `-n` числа сравниваются по значению, нечисловые считаются нулём.
final class _Sort implements Applet {
  const _Sort();

  @override
  String get name => 'sort';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, flags: 'rnu', valued: 'kt');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    final separator = parsed.value('t');
    if (separator != null && separator.length != 1) {
      return usageError(io, name, 'invalid field separator: $separator');
    }
    final keyArg = parsed.value('k');
    final key = keyArg == null ? null : _parseKey(keyArg);
    if (keyArg != null && key == null) {
      return usageError(io, name, "invalid number at field start: '$keyArg'");
    }
    final lines = <String>[];
    final operands = parsed.operands.isEmpty ? ['-'] : parsed.operands;
    for (final operand in operands) {
      io.checkpoint();
      final bytes = await readSource(io, name, operand);
      if (bytes == null) return 2;
      lines.addAll(splitText(bytes).lines);
    }
    final numeric = parsed.has('n');
    final reverse = parsed.has('r');
    final unique = parsed.has('u');
    String keyOf(String line) =>
        key == null ? line : _fieldKey(line, key, separator);
    int compareKeys(String a, String b) {
      final ka = keyOf(a);
      final kb = keyOf(b);
      return numeric
          ? _numericValue(ka).compareTo(_numericValue(kb))
          : ka.compareTo(kb);
    }

    lines.sort((a, b) {
      var result = compareKeys(a, b);
      // Последний довод: при равных ключах порядок по всей строке, как у GNU, если не задан -u.
      if (result == 0 && !unique) result = a.compareTo(b);
      return reverse ? -result : result;
    });
    final out = StringBuffer();
    String? previous;
    for (final line in lines) {
      if (unique && previous != null && compareKeys(previous, line) == 0) {
        continue;
      }
      out.write('$line\n');
      previous = line;
    }
    io.stdout.writeText(out.toString());
    return 0;
  }

  static _Key? _parseKey(String spec) {
    final match = RegExp(r'^(\d+)(?:,(\d+))?$').firstMatch(spec);
    if (match == null) return null;
    final from = int.parse(match.group(1)!);
    final to = match.group(2) == null ? null : int.parse(match.group(2)!);
    if (from < 1 || (to != null && to < from)) return null;
    return _Key(from, to);
  }

  /// Значение поля для `-n`: ведущая часть строки как число, иначе 0.
  static num _numericValue(String text) {
    final match = RegExp(r'^\s*-?\d+(?:\.\d+)?').firstMatch(text);
    return match == null ? 0 : num.parse(match.group(0)!.trim());
  }

  static String _fieldKey(String line, _Key key, String? separator) {
    final fields = separator == null
        ? line.trimLeft().split(RegExp(r'\s+'))
        : line.split(separator);
    final to = key.to ?? fields.length;
    if (key.from > fields.length) return '';
    final picked = fields.sublist(
      key.from - 1,
      to > fields.length ? fields.length : to,
    );
    return picked.join(separator ?? ' ');
  }
}

/// Диапазон полей для `sort -k N[,M]`, 1-based.
final class _Key {
  const _Key(this.from, this.to);

  final int from;
  final int? to;
}

/// `uniq [-cdui]`: схлопывает подряд идущие одинаковые строки. `-c` — счётчик, `-d` — только повторы,
/// `-u` — только строки без повторов, `-i` — сравнение без учёта регистра.
final class _Uniq implements Applet {
  const _Uniq();

  @override
  String get name => 'uniq';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, flags: 'cdui');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    if (parsed.operands.length > 1) {
      return usageError(io, name, "extra operand '${parsed.operands[1]}'");
    }
    final operand = parsed.operands.isEmpty ? '-' : parsed.operands.first;
    final bytes = await readSource(io, name, operand);
    if (bytes == null) return 1;
    final lines = splitText(bytes).lines;
    final ignoreCase = parsed.has('i');
    String fold(String s) => ignoreCase ? s.toLowerCase() : s;
    final groups = <({String line, int count})>[];
    for (final line in lines) {
      if (groups.isNotEmpty && fold(groups.last.line) == fold(line)) {
        groups[groups.length - 1] = (
          line: groups.last.line,
          count: groups.last.count + 1,
        );
      } else {
        groups.add((line: line, count: 1));
      }
    }
    final onlyDuplicates = parsed.has('d');
    final onlyUnique = parsed.has('u');
    final out = StringBuffer();
    for (final group in groups) {
      if (onlyDuplicates && group.count == 1) continue;
      if (onlyUnique && group.count > 1) continue;
      if (parsed.has('c')) {
        out.write('${group.count.toString().padLeft(7)} ${group.line}\n');
      } else {
        out.write('${group.line}\n');
      }
    }
    io.stdout.writeText(out.toString());
    return 0;
  }
}

/// `cut -d SEP -f LIST | -c LIST [-s]`: выбирает поля или символы. LIST: `N`, `N-M`, `-M`, `N-`, через запятую.
/// Без `-f` и `-c` — ошибка. Строки без разделителя печатаются целиком, если не задан `-s`.
final class _Cut implements Applet {
  const _Cut();

  @override
  String get name => 'cut';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, flags: 's', valued: 'dfcb');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    final fields = parsed.value('f');
    final chars = parsed.value('c') ?? parsed.value('b');
    if ((fields == null) == (chars == null)) {
      return usageError(
        io,
        name,
        'you must specify a list of bytes, characters, or fields',
      );
    }
    final delimiter = parsed.value('d') ?? '\t';
    if (delimiter.length != 1) {
      return usageError(io, name, 'the delimiter must be a single character');
    }
    final ranges = _parseList(fields ?? chars!);
    if (ranges == null) {
      return usageError(io, name, 'invalid byte, character or field list');
    }
    final operands = parsed.operands.isEmpty ? ['-'] : parsed.operands;
    final out = StringBuffer();
    for (final operand in operands) {
      final bytes = await readSource(io, name, operand);
      if (bytes == null) return 1;
      for (final line in splitText(bytes).lines) {
        if (chars != null) {
          final runes = line.runes.toList();
          final picked = <int>[];
          for (var i = 0; i < runes.length; i++) {
            if (_inRanges(ranges, i + 1)) picked.add(runes[i]);
          }
          out.write('${String.fromCharCodes(picked)}\n');
          continue;
        }
        if (!line.contains(delimiter)) {
          if (!parsed.has('s')) out.write('$line\n');
          continue;
        }
        final parts = line.split(delimiter);
        final picked = <String>[];
        for (var i = 0; i < parts.length; i++) {
          if (_inRanges(ranges, i + 1)) picked.add(parts[i]);
        }
        out.write('${picked.join(delimiter)}\n');
      }
    }
    io.stdout.writeText(out.toString());
    return 0;
  }

  static bool _inRanges(List<(int, int?)> ranges, int index) {
    for (final (from, to) in ranges) {
      if (index >= from && (to == null || index <= to)) return true;
    }
    return false;
  }

  /// Разбор списка. Ноль, отрицательные и пустые части — ошибка (null).
  static List<(int, int?)>? _parseList(String spec) {
    final ranges = <(int, int?)>[];
    for (final part in spec.split(',')) {
      final match = RegExp(r'^(\d*)(-?)(\d*)$').firstMatch(part);
      if (match == null ||
          (match.group(1)!.isEmpty && match.group(3)!.isEmpty)) {
        return null;
      }
      final hasDash = match.group(2)!.isNotEmpty;
      final from = match.group(1)!.isEmpty ? 1 : int.parse(match.group(1)!);
      final to = match.group(3)!.isEmpty ? null : int.parse(match.group(3)!);
      if (from < 1 || (to != null && to < from)) return null;
      ranges.add((from, hasDash ? to : from));
    }
    return ranges;
  }
}

/// `tr [-cds] SET1 [SET2]`: замена, удаление и сжатие символов на stdin. Наборы: диапазоны `a-z`,
/// escape-последовательности `\n \t \\`, классы `[:alpha:]` `[:digit:]` `[:upper:]` `[:lower:]` `[:space:]`
/// `[:alnum:]` `[:punct:]`. Короче SET2 дополняется её последним символом, как в GNU tr.
final class _Tr implements Applet {
  const _Tr();

  @override
  String get name => 'tr';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, flags: 'cds');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    final operands = parsed.operands;
    final delete = parsed.has('d');
    final squeeze = parsed.has('s');
    final complement = parsed.has('c');
    if (operands.isEmpty) return usageError(io, name, 'missing operand');
    if (!delete && !squeeze && operands.length < 2) {
      return usageError(io, name, 'missing operand after ${operands.first}');
    }
    if (operands.length > 2) {
      return usageError(io, name, "extra operand '${operands[2]}'");
    }
    final set1 = _expand(operands.first);
    final set2 = operands.length > 1 ? _expand(operands[1]) : const <int>[];
    if (set1 == null || set2 == null) {
      return usageError(io, name, 'invalid character class');
    }
    final members = Set<int>.of(set1);
    // Сжатие касается символов второго набора, если он есть (`tr -s a-z ' '`, `tr -ds X Y`), иначе первого.
    final squeezeChars = !squeeze
        ? const <int>{}
        : (operands.length > 1 ? set2 : set1).toSet();
    final source = utf8.decode(io.stdin, allowMalformed: true).runes.toList();
    final out = <int>[];
    int? last;
    for (final rune in source) {
      final inSet = members.contains(rune) != complement;
      if (delete && inSet) continue;
      var mapped = rune;
      if (!delete && set2.isNotEmpty && inSet) {
        mapped = _mapped(set1, set2, rune, complement: complement);
      }
      if (mapped == last && squeezeChars.contains(mapped)) continue;
      out.add(mapped);
      last = mapped;
    }
    io.stdout.writeText(String.fromCharCodes(out));
    return 0;
  }

  /// Символ замены для [rune]: позиция в SET1 даёт символ из SET2; дополнение (-c) — последний символ SET2.
  static int _mapped(
    List<int> set1,
    List<int> set2,
    int rune, {
    required bool complement,
  }) {
    if (complement) return set2.last;
    final index = set1.indexOf(rune);
    return index < set2.length ? set2[index] : set2.last;
  }

  /// Раскрывает набор в список символов в порядке записи. Ошибка — null (неизвестный класс).
  static List<int>? _expand(String spec) {
    final runes = _unescape(spec.runes.toList());
    final out = <int>[];
    var i = 0;
    while (i < runes.length) {
      if (runes[i] == 0x5b && i + 1 < runes.length && runes[i + 1] == 0x3a) {
        final close = _indexOf(runes, [0x3a, 0x5d], i + 2);
        if (close < 0) {
          out.add(runes[i++]);
          continue;
        }
        final name = String.fromCharCodes(runes.sublist(i + 2, close));
        final members = _class(name);
        if (members == null) return null;
        out.addAll(members);
        i = close + 2;
        continue;
      }
      if (i + 2 < runes.length && runes[i + 1] == 0x2d) {
        final from = runes[i];
        final to = runes[i + 2];
        if (from > to) return null;
        for (var r = from; r <= to; r++) {
          out.add(r);
        }
        i += 3;
        continue;
      }
      out.add(runes[i++]);
    }
    return out;
  }

  /// Замена escape-последовательностей до разбора диапазонов: `\n`, `\t`, `\\`, `\NNN` (восьмеричная).
  static List<int> _unescape(List<int> runes) {
    final out = <int>[];
    for (var i = 0; i < runes.length; i++) {
      if (runes[i] != 0x5c || i + 1 >= runes.length) {
        out.add(runes[i]);
        continue;
      }
      final next = runes[++i];
      switch (next) {
        case 0x6e:
          out.add(0x0a);
        case 0x74:
          out.add(0x09);
        case 0x72:
          out.add(0x0d);
        case 0x5c:
          out.add(0x5c);
        default:
          out
            ..add(0x5c)
            ..add(next);
      }
    }
    return out;
  }

  static int _indexOf(List<int> runes, List<int> pattern, int from) {
    for (var i = from; i + pattern.length <= runes.length; i++) {
      var match = true;
      for (var j = 0; j < pattern.length; j++) {
        if (runes[i + j] != pattern[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }

  /// Символы класса POSIX в локали C (ASCII). Неизвестный класс — null.
  static List<int>? _class(String name) => switch (name) {
    'upper' => _range(0x41, 0x5a),
    'lower' => _range(0x61, 0x7a),
    'digit' => _range(0x30, 0x39),
    'alpha' => [..._range(0x41, 0x5a), ..._range(0x61, 0x7a)],
    'alnum' => [
      ..._range(0x30, 0x39),
      ..._range(0x41, 0x5a),
      ..._range(0x61, 0x7a),
    ],
    'space' => [0x20, 0x09, 0x0a, 0x0b, 0x0c, 0x0d],
    'punct' => [
      ..._range(0x21, 0x2f),
      ..._range(0x3a, 0x40),
      ..._range(0x5b, 0x60),
      ..._range(0x7b, 0x7e),
    ],
    _ => null,
  };

  static List<int> _range(int from, int to) => [
    for (var r = from; r <= to; r++) r,
  ];
}

import 'package:virtual_host/src/posix_regex.dart';
import 'package:virtual_host/src/shell/applets/applet.dart';
import 'package:virtual_host/src/shell/applets/applet_args.dart';
import 'package:virtual_host/src/shell/shell_io.dart';

/// Потоковая правка текста: `sed`. Поддерживается подмножество: команда `s/шаблон/замена/флаги` с флагами
/// `g` (все совпадения в строке) и `p` (печатать изменённую строку), опции `-n`, `-e`, `-E`. Адреса,
/// циклы, ветвления, `-i` и остальные команды не реализованы и дают ошибку, а не тихо ничего не делают.
final List<Applet> sedApplets = [const _Sed()];

/// Команда `s` после разбора. [replacement] — части замены: строка — литерал, целое — номер группы
/// (0 — всё совпадение, как `&`).
final class _Substitute {
  const _Substitute({
    required this.pattern,
    required this.replacement,
    required this.global,
    required this.print,
  });

  final RegExp pattern;
  final List<Object> replacement;
  final bool global;
  final bool print;
}

/// Ошибка скрипта. Текст уже в формате GNU sed, без префикса `sed:`.
final class _SedSyntax implements Exception {
  const _SedSyntax(this.message);

  final String message;
}

final class _Sed implements Applet {
  const _Sed();

  @override
  String get name => 'sed';

  /// `sed [-nE] [-e SCRIPT]... [SCRIPT] [FILE...]`. Без `-e` первый операнд — скрипт. Выход: 0 — успех,
  /// 1 — ошибка скрипта, 2 — не прочитан входной файл (как у GNU).
  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, flags: 'nE', valued: 'e');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    final extended = parsed.has('E');
    var operands = parsed.operands;
    var sources = parsed.valuesOf('e');
    if (sources.isEmpty) {
      if (operands.isEmpty) {
        io.stderr.writeText('Usage: sed [-nE] [-e SCRIPT]... [FILE]...\n');
        return 1;
      }
      sources = [operands.first];
      operands = operands.sublist(1);
    }

    final commands = <_Substitute>[];
    for (final source in sources) {
      try {
        commands.addAll(_parseScript(source, extended: extended));
      } on _SedSyntax catch (error) {
        io.stderr.writeText('sed: ${error.message}\n');
        return 1;
      }
    }

    final lines = <String>[];
    var status = 0;
    var terminated = true;
    for (final operand in operands.isEmpty ? const ['-'] : operands) {
      final bytes = await readSource(io, name, operand);
      if (bytes == null) {
        status = 2;
        continue;
      }
      final text = splitText(bytes);
      lines.addAll(text.lines);
      terminated = text.terminated;
    }

    final quiet = parsed.has('n');
    final output = <String>[];
    for (final line in lines) {
      var pattern = line;
      for (final command in commands) {
        final next = _substitute(command, pattern);
        if (next == null) continue;
        pattern = next;
        // `p` печатает строку сразу, в момент команды, а автопечать — в конце цикла: порядок как у GNU.
        if (command.print) output.add(pattern);
      }
      if (!quiet) output.add(pattern);
    }

    final buffer = StringBuffer();
    for (var i = 0; i < output.length; i++) {
      buffer.write(output[i]);
      if (i < output.length - 1 || terminated) buffer.write('\n');
    }
    io.stdout.writeText(buffer.toString());
    return status;
  }
}

/// Разбирает скрипт из команд, разделённых `;` или переводом строки. Позиции в сообщениях — 1-based,
/// как у GNU. Поддерживается только `s`; любая другая команда даёт ошибку с её именем.
List<_Substitute> _parseScript(String script, {required bool extended}) {
  final commands = <_Substitute>[];
  var i = 0;
  while (i < script.length) {
    final c = script[i];
    if (c == ';' || c == '\n' || c == ' ' || c == '\t') {
      i++;
      continue;
    }
    if (c != 's') {
      throw _SedSyntax(
        "-e expression #1, char ${i + 1}: unknown command: '$c'",
      );
    }
    if (i + 1 >= script.length) {
      throw const _SedSyntax(
        '-e expression #1, char 1: unterminated `s\' command',
      );
    }
    final delimiter = script[i + 1];
    if (delimiter == '\\' || delimiter == '\n') {
      throw _SedSyntax(
        "-e expression #1, char ${i + 2}: unterminated `s' command",
      );
    }
    final pattern = _segment(script, i + 2, delimiter);
    final replacement = _segment(script, pattern.end, delimiter);
    final flags = _flags(script, replacement.end);
    final source = extended ? pattern.text : PosixRegex.breSource(pattern.text);
    RegExp? regex;
    try {
      regex = RegExp(source);
    } on FormatException {
      // Ошибку выбрасываем вне catch: сообщение должно указывать позицию в выражении sed.
    }
    if (regex == null) {
      throw _SedSyntax(
        '-e expression #1, char ${replacement.end}: invalid regular expression',
      );
    }
    // Dart не выставляет groupCount у RegExp; пустой матч обёртки `(?:...)|` даёт число групп выражения.
    final groupCount = RegExp('(?:$source)|').firstMatch('')!.groupCount;
    final parts = _parseReplacement(replacement.text);
    for (final part in parts) {
      if (part is int && part > groupCount) {
        throw _SedSyntax(
          "-e expression #1, char ${replacement.end}: invalid reference \\$part on `s' command's RHS",
        );
      }
    }
    commands.add(
      _Substitute(
        pattern: regex,
        replacement: parts,
        global: flags.global,
        print: flags.print,
      ),
    );
    i = flags.end;
  }
  return commands;
}

/// Часть команды `s` до разделителя: текст и позиция после разделителя. `\` перед разделителем даёт сам
/// разделитель; остальные `\x` сохраняются для разбора шаблона и замены.
({String text, int end}) _segment(String script, int start, String delimiter) {
  final buffer = StringBuffer();
  var i = start;
  while (i < script.length) {
    final c = script[i];
    if (c == '\\' && i + 1 < script.length) {
      final next = script[i + 1];
      if (next == delimiter) {
        buffer.write(next);
      } else {
        buffer
          ..write(c)
          ..write(next);
      }
      i += 2;
      continue;
    }
    if (c == delimiter) return (text: buffer.toString(), end: i + 1);
    buffer.write(c);
    i++;
  }
  throw _SedSyntax(
    "-e expression #1, char ${script.length}: unterminated `s' command",
  );
}

/// Флаги после замены: `g`, `p`. Флаги записываются вплотную до `;`, перевода строки или пробела.
({bool global, bool print, int end}) _flags(String script, int start) {
  var global = false;
  var print = false;
  var i = start;
  while (i < script.length) {
    final c = script[i];
    if (c == ';' || c == '\n' || c == ' ' || c == '\t') break;
    if (c == 'g') {
      global = true;
    } else if (c == 'p') {
      print = true;
    } else {
      throw _SedSyntax(
        "-e expression #1, char ${i + 1}: unknown option to `s'",
      );
    }
    i++;
  }
  return (global: global, print: print, end: i);
}

/// Замена: `&` — всё совпадение, `\N` — группа, `\n` — перевод строки, `\x` — буквально `x`.
List<Object> _parseReplacement(String text) {
  final parts = <Object>[];
  final literal = StringBuffer();
  void flush() {
    if (literal.isEmpty) return;
    parts.add(literal.toString());
    literal.clear();
  }

  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c == '&') {
      flush();
      parts.add(0);
    } else if (c == '\\' && i + 1 < text.length) {
      final next = text[i + 1];
      i++;
      final digit = int.tryParse(next);
      if (digit != null) {
        flush();
        parts.add(digit);
      } else {
        literal.write(next == 'n' ? '\n' : next);
      }
    } else {
      literal.write(c);
    }
  }
  flush();
  return parts;
}

/// Применяет команду к строке. Возвращает новую строку или null, если совпадений не было.
/// Пустое совпадение сразу после предыдущего не заменяется: так `s/b*/-/g` даёт `-a-c-`, как GNU.
String? _substitute(_Substitute command, String line) {
  final out = StringBuffer();
  var cursor = 0;
  var previousEnd = -1;
  var changed = false;
  for (final match in command.pattern.allMatches(line)) {
    if (match.start == match.end && match.start == previousEnd) continue;
    out.write(sliceText(line, cursor, match.start));
    for (final part in command.replacement) {
      if (part is String) {
        out.write(part);
      } else if (part is int) {
        out.write(match.group(part) ?? '');
      }
    }
    cursor = match.end;
    previousEnd = match.end;
    changed = true;
    if (!command.global) break;
  }
  if (!changed) return null;
  out.write(sliceText(line, cursor, line.length));
  return out.toString();
}

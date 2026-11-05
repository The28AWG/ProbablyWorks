/// Ввод и форматный вывод: `read`, `mapfile`, `getopts`, `printf`.
library;

import 'package:virtual_host/src/shell/applets/text_applets.dart';
import 'package:virtual_host/src/shell/shell_builtins.dart';
import 'package:virtual_host/src/shell/shell_io.dart';
import 'package:virtual_host/src/shell/shell_state.dart';
import 'package:virtual_host/src/shell/shell_text.dart';

/// Команды, которые читают stdin или печатают по формату. `select` — конструкция языка, не команда.
abstract final class ShellIoBuiltins {
  const ShellIoBuiltins._();

  static final _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  /// `read [-r] [-p текст] [-a имя] [-d разделитель] [-n число] [имя...]`.
  /// Приглашение `-p` не печатается: у виртуального Host нет терминала, и bash в таком случае тоже молчит.
  /// `-a` кладёт поля в массив. `-n` читает не больше N байт. `-d` меняет конец записи.
  static Future<int> read(List<String> args, ShellBuiltinCall call) async {
    var raw = false;
    String? array;
    int? count;
    int? delimiter;
    var index = 0;
    while (index < args.length &&
        args[index].startsWith('-') &&
        args[index] != '-' &&
        args[index].length > 1) {
      if (args[index] == '--') {
        index++;
        break;
      }
      final flags = ShellText.cut(args[index], 1);
      var stop = false;
      for (var k = 0; k < flags.length; k++) {
        final flag = flags[k];
        String? take() {
          final rest = ShellText.cut(flags, k + 1);
          if (rest.isNotEmpty) {
            stop = true;
            return rest;
          }
          index++;
          return index < args.length ? args[index] : null;
        }

        switch (flag) {
          case 'r':
            raw = true;
          case 'p':
            if (take() == null) {
              call.error('read: -p: option requires an argument');
              return 2;
            }
          case 'a':
            array = take();
            if (array == null || !_identifier.hasMatch(array)) {
              call.error('read: -a: option requires an argument');
              return 2;
            }
          case 'n':
            final text = take();
            count = text == null ? null : int.tryParse(text);
            if (count == null || count < 0) {
              call.error('read: -n: option requires an argument');
              return 2;
            }
          case 'd':
            final text = take();
            if (text == null || text.isEmpty) {
              call.error('read: -d: option requires an argument');
              return 2;
            }
            delimiter = text.codeUnitAt(0);
          default:
            call.error('read: -$flag: invalid option');
            return 2;
        }
        if (stop) break;
      }
      index++;
    }
    final names = args.sublist(index);
    for (final name in names) {
      if (!_identifier.hasMatch(name)) {
        call.error("read: `$name': not a valid identifier");
        return 1;
      }
    }
    final state = call.state;
    final ifs = state.get('IFS') ?? ' \t\n';
    if (count != null) {
      final taken = call.stdin.readCount(count);
      final text = taken?.text ?? '';
      if (array != null) {
        state.setArray(array, _splitFields(_chars(text, raw: true), ifs));
      } else {
        state.set(names.isEmpty ? 'REPLY' : names.first, text);
      }
      return (taken?.full ?? false) ? 0 : 1;
    }
    if (delimiter != null) {
      final record = call.stdin.readUntil(delimiter);
      final text = record?.text ?? '';
      final chars = _chars(text, raw: raw);
      if (array != null) {
        state.setArray(array, _splitFields(chars, ifs));
      } else {
        _assign(state, names.isEmpty ? const ['REPLY'] : names, chars, ifs);
      }
      return (record?.found ?? false) ? 0 : 1;
    }
    final record = _readRecord(call.stdin, raw: raw);
    final chars = record?.chars ?? const <(String, bool)>[];
    if (array != null) {
      state.setArray(array, _splitFields(chars, ifs));
    } else {
      _assign(state, names.isEmpty ? const ['REPLY'] : names, chars, ifs);
    }
    return (record?.complete ?? false) ? 0 : 1;
  }

  /// `mapfile` и `readarray`: каждая строка stdin — элемент массива. `-t` убирает перевод строки.
  static int mapfile(List<String> args, ShellBuiltinCall call) {
    var trim = false;
    var index = 0;
    while (index < args.length && args[index].startsWith('-')) {
      if (args[index] == '-t') {
        trim = true;
        index++;
        continue;
      }
      call.error('mapfile: ${args[index]}: invalid option');
      return 2;
    }
    final name = index < args.length ? args[index] : 'MAPFILE';
    if (!_identifier.hasMatch(name)) {
      call.error("mapfile: `$name': not a valid identifier");
      return 1;
    }
    final lines = <String>[];
    while (true) {
      final line = call.stdin.readLine();
      if (line == null) break;
      lines.add(trim || !line.terminated ? line.text : '${line.text}\n');
    }
    call.state.setArray(name, lines);
    return 0;
  }

  /// `getopts строка имя [аргумент...]`. Без аргументов разбирает позиционные параметры.
  /// Буква с `:` в строке опций забирает следующий аргумент в `OPTARG`.
  static int getopts(List<String> args, ShellBuiltinCall call) {
    if (args.length < 2) {
      call.error('getopts: usage: getopts optstring name [arg ...]');
      return 2;
    }
    var optstring = args.first;
    final silent = optstring.startsWith(':');
    if (silent) optstring = ShellText.cut(optstring, 1);
    final name = args[1];
    if (!_identifier.hasMatch(name)) {
      call.error("getopts: `$name': not a valid identifier");
      return 1;
    }
    final state = call.state;
    final words = args.length > 2 ? args.sublist(2) : state.positional;
    var index = int.tryParse(state.get('OPTIND') ?? '1') ?? 1;
    if (index < 1) index = 1;
    while (true) {
      if (index > words.length) {
        state.set(name, '?');
        return 1;
      }
      final word = words[index - 1];
      if (state.optCursor == 0) {
        if (word == '--') {
          state
            ..set('OPTIND', '${index + 1}')
            ..optCursor = 0
            ..set(name, '?');
          return 1;
        }
        if (!word.startsWith('-') || word == '-') {
          state.set(name, '?');
          return 1;
        }
        state.optCursor = 1;
      }
      if (state.optCursor >= word.length) {
        index++;
        state
          ..set('OPTIND', '$index')
          ..optCursor = 0;
        continue;
      }
      final flag = word[state.optCursor];
      state.optCursor++;
      final place = optstring.indexOf(flag);
      if (place < 0) {
        if (!silent) {
          call.stderr.writeText('bash: illegal option -- $flag\n');
        }
        state.set(name, '?');
        if (state.optCursor >= word.length) {
          state
            ..set('OPTIND', '${index + 1}')
            ..optCursor = 0;
        }
        return 0;
      }
      final needsArg =
          place + 1 < optstring.length && optstring[place + 1] == ':';
      if (!needsArg) {
        state
          ..unset('OPTARG')
          ..set(name, flag);
        if (state.optCursor >= word.length) {
          state
            ..set('OPTIND', '${index + 1}')
            ..optCursor = 0;
        }
        return 0;
      }
      final rest = ShellText.cut(word, state.optCursor);
      if (rest.isNotEmpty) {
        state
          ..set('OPTARG', rest)
          ..set('OPTIND', '${index + 1}')
          ..optCursor = 0
          ..set(name, flag);
        return 0;
      }
      if (index >= words.length) {
        if (!silent) {
          call.stderr.writeText('bash: option requires an argument -- $flag\n');
        }
        state
          ..set(name, silent ? ':' : '?')
          ..set('OPTIND', '${index + 1}')
          ..optCursor = 0;
        return 0;
      }
      state
        ..set('OPTARG', words[index])
        ..set('OPTIND', '${index + 2}')
        ..optCursor = 0
        ..set(name, flag);
      return 0;
    }
  }

  /// Одна логическая строка для `read`: без `-r` строка, оканчивающаяся на нечётное число `\`, продолжается
  /// на следующей строке. Символы помечены, экранирован ли он: экранированный разделитель не делит поле.
  static ({List<(String, bool)> chars, bool complete})? _readRecord(
    ShellInput input, {
    required bool raw,
  }) {
    final first = input.readLine();
    if (first == null) return null;
    var text = first.text;
    var complete = first.terminated;
    if (!raw) {
      while (complete && _oddTrailingBackslash(text)) {
        // Последний символ — обратный слеш (ASCII), поэтому срез по единицам UTF-16 безопасен.
        text = String.fromCharCodes(text.codeUnits, 0, text.length - 1);
        final next = input.readLine();
        if (next == null) {
          complete = false;
          break;
        }
        text += next.text;
        complete = next.terminated;
      }
    }
    final units = [for (final rune in text.runes) String.fromCharCode(rune)];
    final chars = <(String, bool)>[];
    var i = 0;
    while (i < units.length) {
      if (!raw && units[i] == r'\' && i + 1 < units.length) {
        chars.add((units[i + 1], true));
        i += 2;
      } else if (!raw && units[i] == r'\') {
        i++;
      } else {
        chars.add((units[i], false));
        i++;
      }
    }
    return (chars: chars, complete: complete);
  }

  static bool _oddTrailingBackslash(String text) {
    var count = 0;
    for (var i = text.length - 1; i >= 0 && text[i] == r'\'; i--) {
      count++;
    }
    return count.isOdd;
  }

  /// Делит символы по IFS и присваивает имена. Пробельные разделители схлопываются, непробельный ставит
  /// границу; последнее имя получает остаток с обрезанными пробелами в конце.
  static void _assign(
    ShellState state,
    List<String> names,
    List<(String, bool)> chars,
    String ifs,
  ) {
    bool isIfs((String, bool) unit) => !unit.$2 && ifs.contains(unit.$1);
    bool isSpace((String, bool) unit) =>
        !unit.$2 && ' \t\n'.contains(unit.$1) && ifs.contains(unit.$1);
    var i = 0;
    for (var k = 0; k < names.length; k++) {
      final isLast = k == names.length - 1;
      while (i < chars.length && isSpace(chars[i])) {
        i++;
      }
      if (isLast) {
        var end = chars.length;
        while (end > i && isSpace(chars[end - 1])) {
          end--;
        }
        state.set(names[k], _text(chars.sublist(i, end)));
        break;
      }
      final start = i;
      while (i < chars.length && !isIfs(chars[i])) {
        i++;
      }
      state.set(names[k], _text(chars.sublist(start, i)));
      if (i < chars.length) i++;
    }
  }

  static String _text(List<(String, bool)> chars) =>
      chars.map((c) => c.$1).join();

  static List<(String, bool)> _chars(String text, {required bool raw}) {
    final units = [for (final rune in text.runes) String.fromCharCode(rune)];
    final chars = <(String, bool)>[];
    var i = 0;
    while (i < units.length) {
      if (!raw && units[i] == r'\' && i + 1 < units.length) {
        chars.add((units[i + 1], true));
        i += 2;
      } else if (!raw && units[i] == r'\') {
        i++;
      } else {
        chars.add((units[i], false));
        i++;
      }
    }
    return chars;
  }

  /// Все поля строки, а не только именованные слоты `read`. Нужно `read -a` и проверке хвоста.
  static List<String> _splitFields(List<(String, bool)> chars, String ifs) {
    bool isIfs((String, bool) unit) => !unit.$2 && ifs.contains(unit.$1);
    bool isSpace((String, bool) unit) =>
        !unit.$2 && ' \t\n'.contains(unit.$1) && ifs.contains(unit.$1);
    final fields = <String>[];
    var i = 0;
    while (i < chars.length && isSpace(chars[i])) {
      i++;
    }
    while (i < chars.length) {
      final start = i;
      while (i < chars.length && !isIfs(chars[i])) {
        i++;
      }
      fields.add(_text(chars.sublist(start, i)));
      if (i >= chars.length) break;
      i++;
      while (i < chars.length && isSpace(chars[i])) {
        i++;
      }
    }
    return fields;
  }

  /// `printf [-v NAME] FORMAT [ARG...]`. Без `-v` пишет в stdout, с `-v` — в переменную.
  /// Разбор формата общий с апплетом, поэтому сообщения об ошибках чисел те же.
  static int printf(List<String> args, ShellBuiltinCall call) {
    var index = 0;
    String? target;
    if (args.isNotEmpty && args.first == '-v') {
      if (args.length < 3) {
        call.error('printf: -v: option requires an argument');
        return 2;
      }
      target = args[1];
      if (!_identifier.hasMatch(target)) {
        call.error("printf: `$target': not a valid identifier");
        return 2;
      }
      index = 2;
    }
    if (index >= args.length) {
      call.stderr.writeText('printf: missing format\n');
      return 2;
    }
    final result = formatPrintf(args[index], args.sublist(index + 1));
    if (target == null) {
      call.stdout.writeText(result.text);
    } else {
      call.state.set(target, result.text);
    }
    final error = result.error;
    if (error != null) {
      call.stderr.writeText('printf: $error\n');
      return 1;
    }
    return 0;
  }
}

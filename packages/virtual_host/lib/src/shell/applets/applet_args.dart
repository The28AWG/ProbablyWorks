import 'dart:convert';
import 'dart:typed_data';

import 'package:virtual_host/src/shell/applets/applet.dart';
import 'package:virtual_host/src/shell/shell_io.dart';
import 'package:virtual_host/src/vfs_store.dart';
import 'package:virtual_host/src/virtual_fs.dart';

/// Результат разбора аргументов апплета. [error] — текст ошибки в формате getopt (`invalid option -- 'x'`),
/// если разбор не удался; тогда остальные поля не нужно читать.
final class ParsedArgs {
  const ParsedArgs({
    required this.flags,
    required this.values,
    required this.allValues,
    required this.operands,
    this.error,
  });

  /// Включённые флаги без значения (например, `-l`).
  final Set<String> flags;

  /// Значения опций со значением (например, `-n 5` дают `n: 5`). Последнее вхождение побеждает.
  final Map<String, String> values;

  /// Все значения опции в порядке появления: нужно `grep -e A -e B`. Ключи совпадают с [values].
  final Map<String, List<String>> allValues;

  /// Позиционные аргументы в исходном порядке.
  final List<String> operands;

  final String? error;

  bool has(String flag) => flags.contains(flag);

  String? value(String option) => values[option];

  /// Все значения опции `option` в порядке появления, пустой список если опции не было.
  List<String> valuesOf(String option) => allValues[option] ?? const [];
}

/// Разбор аргументов в стиле getopt: короткие флаги склеиваются (`-la`), опция со значением берёт
/// остаток слова или следующий аргумент (`-n5`, `-n 5`), `--` завершает опции, `-` — операнд.
/// Длинных опций нет: апплеты поддерживают только то, что описано в их документации.
ParsedArgs parseArgs(
  List<String> args, {
  String flags = '',
  String valued = '',
}) {
  final found = <String>{};
  final values = <String, String>{};
  final allValues = <String, List<String>>{};
  final operands = <String>[];
  var onlyOperands = false;
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (onlyOperands || arg == '-' || !arg.startsWith('-')) {
      operands.add(arg);
      continue;
    }
    if (arg == '--') {
      onlyOperands = true;
      continue;
    }
    for (var j = 1; j < arg.length; j++) {
      final ch = arg[j];
      if (valued.contains(ch)) {
        final rest = String.fromCharCodes(arg.codeUnits.sublist(j + 1));
        if (rest.isNotEmpty || i + 1 < args.length) {
          final value = rest.isNotEmpty ? rest : args[++i];
          values[ch] = value;
          allValues.putIfAbsent(ch, () => []).add(value);
        } else {
          return ParsedArgs(
            flags: found,
            values: values,
            allValues: allValues,
            operands: operands,
            error: "option requires an argument -- '$ch'",
          );
        }
        break;
      }
      if (!flags.contains(ch)) {
        return ParsedArgs(
          flags: found,
          values: values,
          allValues: allValues,
          operands: operands,
          error: "invalid option -- '$ch'",
        );
      }
      found.add(ch);
    }
  }
  return ParsedArgs(
    flags: found,
    values: values,
    allValues: allValues,
    operands: operands,
  );
}

/// Печатает ошибку разбора и подсказку, как GNU: `name: сообщение` и `Try 'name --help'`. Код 2.
Future<int> usageError(AppletIo io, String name, String message) async {
  io.stderr.writeText(
    "$name: $message\nTry '$name --help' for more information.\n",
  );
  return 2;
}

/// Читает байты источника: файл относительно `io.cwd` или, для `-` и без операндов, stdin.
/// Ошибка чтения печатается как `name: operand: сообщение` и возвращает null.
Future<Uint8List?> readSource(AppletIo io, String name, String operand) async {
  if (operand == '-') return io.stdin;
  try {
    return await io.fs.readBytes(operand, cwd: io.cwd);
  } on VfsException catch (e) {
    io.stderr.writeText('$name: $operand: ${e.message}\n');
    return null;
  }
}

/// Строки текста без переводов строк и признак, что последняя строка завершена `\n`. Нужен, чтобы
/// `head`, `tail`, `cat` возвращали байты как есть: без лишнего перевода строки в конце.
({List<String> lines, bool terminated}) splitText(Uint8List bytes) {
  final text = utf8.decode(bytes, allowMalformed: true);
  if (text.isEmpty) return (lines: const [], terminated: true);
  final terminated = text.endsWith('\n');
  final body = terminated ? text.replaceFirst(RegExp(r'\n$'), '') : text;
  return (lines: body.split('\n'), terminated: terminated);
}

/// Путь без завершающих `/` (кроме корня). Пустой результат не возникает: корень остаётся `/`.
String trimSlashes(String path) {
  final trimmed = path.replaceFirst(RegExp(r'/+$'), '');
  return trimmed.isEmpty ? '/' : trimmed;
}

/// Последний компонент пути, как у `basename`: без завершающих `/`. Для `/` — `/`.
String baseOf(String path) {
  final trimmed = trimSlashes(path);
  if (trimmed == '/') return '/';
  return trimmed.split('/').last;
}

/// Путь без последнего компонента, как у `dirname`: без слэшей — `.`, корень — `/`.
String dirOf(String path) {
  final trimmed = trimSlashes(path);
  if (!trimmed.contains('/')) return '.';
  final parent = trimmed.replaceFirst(RegExp(r'/[^/]*$'), '');
  return parent.isEmpty ? '/' : trimSlashes(parent);
}

/// Шаблон shell-glob (`*`, `?`, `[...]`, `[!...]`) в регулярное выражение, привязанное к обоим концам.
/// Используется `find -name` и `ls`-подобными фильтрами; разбор кавычек уже сделан интерпретатором.
RegExp globToRegExp(String pattern, {bool caseInsensitive = false}) {
  final out = StringBuffer('^');
  for (var i = 0; i < pattern.length; i++) {
    final ch = pattern[i];
    switch (ch) {
      case '*':
        out.write('.*');
      case '?':
        out.write('.');
      case '[':
        final close = pattern.indexOf(']', i + 2);
        if (close < 0) {
          out.write(r'\[');
          continue;
        }
        final negate = pattern[i + 1] == '!';
        out.write(negate ? '[^' : '[');
        for (var j = negate ? i + 2 : i + 1; j < close; j++) {
          out.write(pattern[j] == r'\' ? r'\\' : pattern[j]);
        }
        out.write(']');
        i = close;
      default:
        out.write(RegExp.escape(ch));
    }
  }
  out.write(r'$');
  return RegExp(out.toString(), caseSensitive: !caseInsensitive, dotAll: true);
}

/// Номера пользователя и группы агента. Те же значения, что [vfsAgentUid] и [vfsAgentGid]:
/// `id` показывает агента, а не владельца конкретного файла.
const hostUid = vfsAgentUid;
const hostGid = vfsAgentGid;

/// Фрагмент строки по единицам кода UTF-16 от [start] до [end]. Вместо `substring` (его запрещает DCM):
/// границы здесь всегда на позициях, которые вычислил сам апплет по `codeUnits`, поэтому суррогатные пары
/// не разрываются.
String sliceText(String text, int start, int end) =>
    String.fromCharCodes(text.codeUnits.getRange(start, end));

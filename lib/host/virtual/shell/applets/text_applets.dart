import 'dart:convert';
import 'dart:typed_data';

import 'package:probably_works/host/virtual/shell/applets/applet.dart';
import 'package:probably_works/host/virtual/shell/applets/applet_args.dart';
import 'package:probably_works/host/virtual/shell/shell_io.dart';
import 'package:probably_works/host/virtual/shell/shell_text.dart';
import 'package:probably_works/host/virtual/virtual_fs.dart';

/// Текстовые апплеты: вывод строк, преобразование и счёт. Фильтры по шаблону и сортировка — в
/// `text_filter_applets.dart`.
final List<Applet> textApplets = [
  const _Echo(),
  const _Printf(),
  const _Cat(),
  const _Head(),
  const _Tail(),
  const _Wc(),
  const _Tee(),
  const _Seq(),
  const _Basename(),
  const _Dirname(),
];

/// `echo [-neE] [STRING...]`: `-n` без перевода строки, `-e` раскрывает escape-последовательности,
/// `-E` (по умолчанию) — нет. `\c` в режиме `-e` обрывает вывод.
final class _Echo implements Applet {
  const _Echo();

  @override
  String get name => 'echo';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    var newline = true;
    var escapes = false;
    var index = 0;
    while (index < args.length && _echoOption.hasMatch(args[index])) {
      final option = args[index];
      if (option.contains('n')) newline = false;
      if (option.contains('e')) escapes = true;
      if (option.contains('E')) escapes = false;
      index++;
    }
    final text = args.skip(index).join(' ');
    if (!escapes) {
      io.stdout.writeText(newline ? '$text\n' : text);
      return 0;
    }
    final decoded = _unescape(text, stopAtC: true);
    io.stdout.writeText(
      newline && !decoded.stopped ? '${decoded.text}\n' : decoded.text,
    );
    return 0;
  }
}

final _echoOption = RegExp(r'^-[neE]+$');

/// Раскрывает escape-последовательности, как `echo -e` и `printf`. [stopAtC] — `\c` обрывает вывод.
({String text, bool stopped}) _unescape(String input, {required bool stopAtC}) {
  final out = StringBuffer();
  for (var i = 0; i < input.length; i++) {
    final ch = input[i];
    if (ch != r'\' || i + 1 >= input.length) {
      out.write(ch);
      continue;
    }
    final next = input[++i];
    switch (next) {
      case 'n':
        out.write('\n');
      case 't':
        out.write('\t');
      case 'r':
        out.write('\r');
      case 'a':
        out.write('\x07');
      case 'b':
        out.write('\b');
      case 'f':
        out.write('\f');
      case 'v':
        out.write('\v');
      case r'\':
        out.write(r'\');
      case 'c' when stopAtC:
        return (text: out.toString(), stopped: true);
      case '0':
        var value = 0;
        var digits = 0;
        while (digits < 3 && i + 1 < input.length && _isOctal(input[i + 1])) {
          value = value * 8 + int.parse(input[++i]);
          digits++;
        }
        out.writeCharCode(value);
      default:
        out.write('\\$next');
    }
  }
  return (text: out.toString(), stopped: false);
}

bool _isOctal(String ch) =>
    ch.length == 1 && ch.codeUnitAt(0) >= 0x30 && ch.codeUnitAt(0) <= 0x37;

/// `printf FORMAT [ARG...]`: `%s %d %i %u %x %X %o %c %b %f %%` с шириной, точностью и флагами `-+ 0`.
/// Формат повторяется, пока остаются аргументы, как в bash. Неверное число — код 1 и сообщение.
final class _Printf implements Applet {
  const _Printf();

  @override
  String get name => 'printf';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    if (args.isEmpty) return usageError(io, name, 'missing format');
    final result = _format(args.first, args.skip(1).toList());
    io.stdout.writeText(result.text);
    if (result.error != null) {
      io.stderr.writeText('$name: ${result.error}\n');
      return 1;
    }
    return 0;
  }
}

/// Форматирует аргументы как `printf`. Текст и первая ошибка числа, если она была.
/// Встроенная команда `printf -v` пользуется тем же разбором, что и апплет.
({String text, String? error}) formatPrintf(String format, List<String> args) =>
    _format(format, args);

/// Результат форматирования: текст и первая ошибка числа, если была.
({String text, String? error}) _format(String format, List<String> args) {
  final out = StringBuffer();
  String? error;
  var argIndex = 0;
  final unescaped = _unescape(format, stopAtC: false).text;
  do {
    final startIndex = argIndex;
    var i = 0;
    while (i < unescaped.length) {
      final ch = unescaped[i];
      if (ch != '%') {
        out.write(ch);
        i++;
        continue;
      }
      if (i + 1 < unescaped.length && unescaped[i + 1] == '%') {
        out.write('%');
        i += 2;
        continue;
      }
      final spec = _parseSpec(unescaped, i);
      if (spec == null) {
        out.write(ch);
        i++;
        continue;
      }
      i = spec.end;
      final arg = argIndex < args.length ? args[argIndex] : null;
      argIndex++;
      final rendered = _render(spec, arg);
      out.write(rendered.text);
      error ??= rendered.error;
    }
    if (argIndex == startIndex) break;
  } while (argIndex < args.length);
  return (text: out.toString(), error: error);
}

/// Спецификатор `%[flags][width][.precision]conv`.
final class _Spec {
  const _Spec({
    required this.end,
    required this.conv,
    required this.leftAlign,
    required this.zeroPad,
    required this.plus,
    required this.space,
    required this.width,
    required this.precision,
  });

  final int end;
  final String conv;
  final bool leftAlign;
  final bool zeroPad;
  final bool plus;
  final bool space;
  final int width;
  final int? precision;
}

/// Разбирает спецификатор, начинающийся с [start] (знак `%`). Неизвестный или незавершённый — null.
_Spec? _parseSpec(String format, int start) {
  var i = start + 1;
  var leftAlign = false;
  var zeroPad = false;
  var plus = false;
  var space = false;
  while (i < format.length && '-0+ '.contains(format[i])) {
    switch (format[i]) {
      case '-':
        leftAlign = true;
      case '0':
        zeroPad = true;
      case '+':
        plus = true;
      case _:
        space = true;
    }
    i++;
  }
  var width = 0;
  while (i < format.length && _isDigit(format[i])) {
    width = width * 10 + int.parse(format[i]);
    i++;
  }
  int? precision;
  if (i < format.length && format[i] == '.') {
    i++;
    precision = 0;
    while (i < format.length && _isDigit(format[i])) {
      precision = precision! * 10 + int.parse(format[i]);
      i++;
    }
  }
  if (i >= format.length || !'sdiuxXocbfegq'.contains(format[i])) return null;
  return _Spec(
    end: i + 1,
    conv: format[i],
    leftAlign: leftAlign,
    zeroPad: zeroPad,
    plus: plus,
    space: space,
    width: width,
    precision: precision,
  );
}

bool _isDigit(String ch) =>
    ch.length == 1 && ch.codeUnitAt(0) >= 0x30 && ch.codeUnitAt(0) <= 0x39;

({String text, String? error}) _render(_Spec spec, String? arg) {
  String? error;
  String body;
  var numeric = false;
  switch (spec.conv) {
    case 's':
      body = arg ?? '';
      if (spec.precision != null && body.length > spec.precision!) {
        body = String.fromCharCodes(body.runes.take(spec.precision!));
      }
    case 'b':
      body = _unescape(arg ?? '', stopAtC: true).text;
    case 'c':
      body = (arg == null || arg.isEmpty) ? '' : arg[0];
    case 'f':
      final value = _double(arg, (e) => error ??= e);
      final negative = value < 0 || (value == 0 && value.isNegative);
      final digits = value.abs().toStringAsFixed(spec.precision ?? 6);
      return (
        text: _pad(spec, _signed(spec, negative, digits), numeric: true),
        error: error,
      );
    case 'e':
      final value = _double(arg, (e) => error ??= e);
      return (
        text: _pad(
          spec,
          _exponential(value, spec.precision ?? 6),
          numeric: true,
        ),
        error: error,
      );
    case 'g':
      final value = _double(arg, (e) => error ??= e);
      return (
        text: _pad(spec, _general(value, spec.precision ?? 6), numeric: true),
        error: error,
      );
    case 'q':
      body = _quote(arg ?? '');
    default:
      numeric = true;
      final value = _number(arg, (e) => error ??= e);
      final digits = switch (spec.conv) {
        'x' => value.abs().toRadixString(16),
        'X' => value.abs().toRadixString(16).toUpperCase(),
        'o' => value.abs().toRadixString(8),
        _ => value.abs().toString(),
      };
      final precise = spec.precision == null
          ? digits
          : digits.padLeft(spec.precision!, '0');
      body = (spec.conv == 'd' || spec.conv == 'i')
          ? _signed(spec, value < 0, precise)
          : precise;
  }
  return (text: _pad(spec, body, numeric: numeric), error: error);
}

String _signed(_Spec spec, bool negative, String digits) {
  if (negative) return '-$digits';
  if (spec.plus) return '+$digits';
  if (spec.space) return ' $digits';
  return digits;
}

String _pad(_Spec spec, String body, {required bool numeric}) {
  if (body.length >= spec.width) return body;
  if (spec.leftAlign) return body.padRight(spec.width);
  if (spec.zeroPad && numeric) {
    final signed = body.startsWith('-') || body.startsWith('+');
    final sign = signed ? body[0] : '';
    final digits = signed ? body.replaceFirst(RegExp(r'^[-+]'), '') : body;
    return '$sign${digits.padLeft(spec.width - sign.length, '0')}';
  }
  return body.padLeft(spec.width);
}

/// Целое из аргумента printf. Пусто — 0. Неверный ввод — 0 и сообщение (через [onError]).
/// Форма `'c` даёт код символа, как в bash.
int _number(String? arg, void Function(String) onError) {
  if (arg == null || arg.isEmpty) return 0;
  if (arg.startsWith("'") && arg.length > 1) return arg.codeUnitAt(1);
  final value = int.tryParse(arg);
  if (value == null) {
    onError("'$arg': expected a numeric value");
    return 0;
  }
  return value;
}

/// Дробное из аргумента printf для `%f`. Правила ошибок те же, что у [_number].
double _double(String? arg, void Function(String) onError) {
  if (arg == null || arg.isEmpty) return 0;
  final value = double.tryParse(arg);
  if (value == null) {
    onError("'$arg': expected a numeric value");
    return 0;
  }
  return value;
}

/// `%e`: мантисса с точкой и показатель из двух цифр (`1.250000e+01`). Округление до 10 поднимает степень.
String _exponential(double value, int precision) {
  if (value.isNaN) return 'nan';
  if (value.isInfinite) return value.isNegative ? '-inf' : 'inf';
  final negative = value < 0 || (value == 0 && value.isNegative);
  var mantissa = value.abs();
  var exponent = 0;
  if (mantissa != 0) {
    while (mantissa >= 10) {
      mantissa /= 10;
      exponent++;
    }
    while (mantissa < 1) {
      mantissa *= 10;
      exponent--;
    }
  }
  var digits = mantissa.toStringAsFixed(precision);
  if (digits.startsWith('10')) {
    digits = 1.toStringAsFixed(precision);
    exponent++;
  }
  final sign = exponent < 0 ? '-' : '+';
  final shown = exponent.abs().toString().padLeft(2, '0');
  return '${negative ? '-' : ''}${digits}e$sign$shown';
}

/// `%g`: более короткая из форм `%f` и `%e`, без хвостовых нулей. Точность — число значащих цифр.
String _general(double value, int precision) {
  final digits = precision == 0 ? 1 : precision;
  if (value == 0) return '0';
  var scaled = value.abs();
  var exponent = 0;
  while (scaled >= 10) {
    scaled /= 10;
    exponent++;
  }
  while (scaled < 1) {
    scaled *= 10;
    exponent--;
  }
  if (exponent < -4 || exponent >= digits) {
    return _trimExponent(_exponential(value, digits - 1));
  }
  final places = digits - exponent - 1;
  var fixed = value.abs().toStringAsFixed(places < 0 ? 0 : places);
  if (fixed.startsWith('10')) {
    return _trimExponent(_exponential(value, digits - 1));
  }
  final dot = fixed.indexOf('.');
  if (dot >= 0) {
    var end = fixed.length;
    while (end > dot + 1 && fixed[end - 1] == '0') {
      end--;
    }
    if (end == dot + 1) end = dot;
    fixed = ShellText.cut(fixed, 0, end);
  }
  return value < 0 ? '-$fixed' : fixed;
}

String _trimExponent(String text) {
  final mark = text.indexOf('e');
  if (mark < 0) return text;
  var mantissa = ShellText.cut(text, 0, mark);
  final exponent = ShellText.cut(text, mark);
  final dot = mantissa.indexOf('.');
  if (dot < 0) return text;
  var end = mantissa.length;
  while (end > dot + 1 && mantissa[end - 1] == '0') {
    end--;
  }
  if (end == dot + 1) end = dot;
  mantissa = ShellText.cut(mantissa, 0, end);
  return '$mantissa$exponent';
}

/// `%q`: форма, которую оболочка прочитает как ту же строку. Управляющие байты — в `$'\ldots'`.
String _quote(String value) {
  if (value.isEmpty) return "''";
  final bytes = utf8.encode(value);
  for (final unit in bytes) {
    if (unit < 0x20 || unit > 0x7e) return _ansiQuote(bytes);
  }
  const safe =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789%+./:@=-_';
  final buffer = StringBuffer();
  for (final unit in bytes) {
    final ch = String.fromCharCode(unit);
    if (!safe.contains(ch)) buffer.write(r'\');
    buffer.write(ch);
  }
  return buffer.toString();
}

String _ansiQuote(List<int> bytes) {
  final buffer = StringBuffer(r"$'");
  for (final unit in bytes) {
    switch (unit) {
      case 0x07:
        buffer.write(r'\a');
      case 0x08:
        buffer.write(r'\b');
      case 0x09:
        buffer.write(r'\t');
      case 0x0a:
        buffer.write(r'\n');
      case 0x0b:
        buffer.write(r'\v');
      case 0x0c:
        buffer.write(r'\f');
      case 0x0d:
        buffer.write(r'\r');
      case 0x5c:
        buffer.write(r'\\');
      case 0x27:
        buffer.write(r"\'");
      default:
        if (unit < 0x20 || unit > 0x7e) {
          buffer.write('\\${unit.toRadixString(8).padLeft(3, '0')}');
        } else {
          buffer.writeCharCode(unit);
        }
    }
  }
  buffer.write("'");
  return buffer.toString();
}

/// `cat [-n] [FILE...]`: файлы подряд, без операндов или для `-` — stdin. `-n` нумерует все строки.
/// Ошибка одного файла не останавливает остальные, итог — код 1.
final class _Cat implements Applet {
  const _Cat();

  @override
  String get name => 'cat';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, flags: 'n');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    final operands = parsed.operands.isEmpty ? ['-'] : parsed.operands;
    var status = 0;
    var number = 0;
    for (final operand in operands) {
      io.checkpoint();
      final bytes = await readSource(io, name, operand);
      if (bytes == null) {
        status = 1;
        continue;
      }
      if (!parsed.has('n')) {
        io.stdout.write(bytes);
        continue;
      }
      final text = splitText(bytes);
      for (final line in text.lines) {
        io.checkpoint();
        number++;
        io.stdout.writeText('${number.toString().padLeft(6)}\t$line\n');
      }
    }
    return status;
  }
}

/// `head [-n N] [FILE...]`: первые N строк (по умолчанию 10). Несколько файлов — с заголовками.
final class _Head implements Applet {
  const _Head();

  @override
  String get name => 'head';

  @override
  Future<int> run(AppletIo io, List<String> args) =>
      _windowed(io, name, args, fromEnd: false);
}

/// `tail [-n N] [FILE...]`: последние N строк. `-n +N` — с N-й строки.
final class _Tail implements Applet {
  const _Tail();

  @override
  String get name => 'tail';

  @override
  Future<int> run(AppletIo io, List<String> args) =>
      _windowed(io, name, args, fromEnd: true);
}

/// Старая форма `head -5` (= `-n 5`), которую поддерживает GNU. Переписываем до разбора, иначе цифры
/// выглядят как неизвестные опции. После `--` ничего не меняем, и значение `-n -3` не трогаем: это
/// значение опции, а не старая форма.
List<String> _legacyCount(List<String> args) {
  final out = <String>[];
  var endOfOptions = false;
  var valueExpected = false;
  for (final arg in args) {
    if (valueExpected) {
      valueExpected = false;
      out.add(arg);
      continue;
    }
    if (arg == '--') endOfOptions = true;
    if (!endOfOptions && (arg == '-n' || arg == '-c')) valueExpected = true;
    if (!endOfOptions && _legacyCountOption.hasMatch(arg)) {
      out
        ..add('-n')
        ..add(arg.replaceFirst('-', ''));
    } else {
      out.add(arg);
    }
  }
  return out;
}

final _legacyCountOption = RegExp(r'^-\d+$');

Future<int> _windowed(
  AppletIo io,
  String name,
  List<String> rawArgs, {
  required bool fromEnd,
}) async {
  final parsed = parseArgs(_legacyCount(rawArgs), valued: 'nc');
  if (parsed.error != null) return usageError(io, name, parsed.error!);
  final bytesMode = parsed.value('c');
  final raw = parsed.value('n') ?? '10';
  final fromLine = raw.startsWith('+') && fromEnd;
  final count = int.tryParse(fromLine ? raw.replaceFirst('+', '') : raw);
  final amount = int.tryParse(bytesMode ?? '');
  if (bytesMode != null && (amount == null || amount < 0)) {
    return usageError(io, name, "invalid number of bytes: '$bytesMode'");
  }
  if (bytesMode == null && count == null) {
    return usageError(io, name, "invalid number of lines: '$raw'");
  }
  final operands = parsed.operands.isEmpty ? ['-'] : parsed.operands;
  final multi = operands.length > 1;
  var status = 0;
  for (var index = 0; index < operands.length; index++) {
    final operand = operands[index];
    final bytes = await readSource(io, name, operand);
    if (bytes == null) {
      status = 1;
      continue;
    }
    if (multi) {
      if (index > 0) io.stdout.writeText('\n');
      io.stdout.writeText(
        '==> ${operand == '-' ? 'standard input' : operand} <==\n',
      );
    }
    if (amount != null) {
      io.stdout.write(_bytesWindow(bytes, amount, fromEnd: fromEnd));
      continue;
    }
    final text = splitText(bytes);
    final lines = text.lines;
    final List<String> selected;
    if (fromLine) {
      selected = count! <= 1 ? lines : lines.skip(count - 1).toList();
    } else if (fromEnd) {
      selected = lines
          .skip((lines.length - count!.abs()).clamp(0, lines.length))
          .toList();
    } else if (count! < 0) {
      // `head -n -N`: всё, кроме последних N строк.
      selected = lines
          .take((lines.length + count).clamp(0, lines.length))
          .toList();
    } else {
      selected = lines.take(count).toList();
    }
    // Последняя строка файла без `\n` выводится без него, как в исходнике. Это касается только
    // случая, когда выбор доходит до конца файла.
    final reachesEnd =
        selected.isNotEmpty && (fromEnd || selected.length == lines.length);
    for (var i = 0; i < selected.length; i++) {
      final unterminated =
          reachesEnd && !text.terminated && i == selected.length - 1;
      io.stdout.writeText(unterminated ? selected[i] : '${selected[i]}\n');
    }
  }
  return status;
}

/// Первые или последние [amount] байтов для `head -c` и `tail -c`.
Uint8List _bytesWindow(Uint8List bytes, int amount, {required bool fromEnd}) {
  final size = amount.clamp(0, bytes.length);
  return fromEnd
      ? Uint8List.sublistView(bytes, bytes.length - size)
      : Uint8List.sublistView(bytes, 0, size);
}

/// `wc [-lwc] [FILE...]`: строки, слова и байты. Без опций — все три. Для нескольких файлов — итог.
final class _Wc implements Applet {
  const _Wc();

  @override
  String get name => 'wc';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, flags: 'lwc');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    final all = !parsed.has('l') && !parsed.has('w') && !parsed.has('c');
    final operands = parsed.operands.isEmpty ? ['-'] : parsed.operands;
    final counts = <({int lines, int words, int bytes, String? name})>[];
    var status = 0;
    for (final operand in operands) {
      final bytes = await readSource(io, name, operand);
      if (bytes == null) {
        status = 1;
        continue;
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      counts.add((
        lines: '\n'.allMatches(text).length,
        words: text.trim().isEmpty
            ? 0
            : text.trim().split(RegExp(r'\s+')).length,
        bytes: bytes.length,
        name: operand == '-' ? null : operand,
      ));
    }
    var sumLines = 0;
    var sumWords = 0;
    var sumBytes = 0;
    for (final c in counts) {
      sumLines += c.lines;
      sumWords += c.words;
      sumBytes += c.bytes;
    }
    final total = counts.length > 1
        ? (lines: sumLines, words: sumWords, bytes: sumBytes, name: 'total')
        : null;
    // Ширина колонки — по самому большому числу, как у GNU wc для нескольких файлов.
    final width = counts.length > 1 ? sumBytes.toString().length : 1;
    for (final c in [...counts, ?total]) {
      final fields = [
        if (all || parsed.has('l')) '${c.lines}',
        if (all || parsed.has('w')) '${c.words}',
        if (all || parsed.has('c')) '${c.bytes}',
      ];
      final padded = fields.map((f) => f.padLeft(width)).join(' ');
      io.stdout.writeText(c.name == null ? '$padded\n' : '$padded ${c.name}\n');
    }
    return status;
  }
}

/// `tee [-a] [FILE...]`: копирует stdin в stdout и в файлы. `-a` дописывает в конец файла.
final class _Tee implements Applet {
  const _Tee();

  @override
  String get name => 'tee';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, flags: 'a');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    io.stdout.write(io.stdin);
    var status = 0;
    for (final operand in parsed.operands) {
      try {
        var content = io.stdin;
        if (parsed.has('a') && await io.fs.stat(operand, cwd: io.cwd) != null) {
          content = Uint8List.fromList([
            ...await io.fs.readBytes(operand, cwd: io.cwd),
            ...io.stdin,
          ]);
        }
        await io.fs.writeBytes(operand, content, cwd: io.cwd);
      } on VfsException catch (e) {
        io.stderr.writeText('$name: $operand: ${e.message}\n');
        status = 1;
      }
    }
    return status;
  }
}

/// `seq [FIRST [INCREMENT]] LAST`: целые числа. Дробные значения не поддерживаются и дают ошибку.
final class _Seq implements Applet {
  const _Seq();

  @override
  String get name => 'seq';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    // Отрицательные числа — операнды (`seq 5 -2 1`), поэтому аргументы не разбираются как опции.
    final numbers = args.map(int.tryParse).toList();
    if (numbers.isEmpty || numbers.length > 3 || numbers.contains(null)) {
      return usageError(io, name, 'invalid arguments');
    }
    final (first, step, last) = switch (numbers.cast<int>()) {
      [final end] => (1, 1, end),
      [final start, final end] => (start, 1, end),
      [final start, final increment, final end] => (start, increment, end),
      _ => (1, 1, 0),
    };
    if (step == 0) return usageError(io, name, 'increment must not be zero');
    const limit = 100000;
    var count = 0;
    for (
      var value = first;
      step > 0 ? value <= last : value >= last;
      value += step
    ) {
      if (++count > limit) {
        io.stderr.writeText('$name: more than $limit numbers requested\n');
        return 1;
      }
      io.stdout.writeText('$value\n');
    }
    return 0;
  }
}

/// `basename NAME [SUFFIX]`: последний компонент пути; суффикс снимается, если совпадает с концом.
final class _Basename implements Applet {
  const _Basename();

  @override
  String get name => 'basename';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args);
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    if (parsed.operands.isEmpty) return usageError(io, name, 'missing operand');
    final base = baseOf(parsed.operands.first);
    final suffix = parsed.operands.length > 1 ? parsed.operands[1] : '';
    final trimmed = suffix.isNotEmpty && base != suffix && base.endsWith(suffix)
        ? base.replaceFirst(RegExp('${RegExp.escape(suffix)}\$'), '')
        : base;
    io.stdout.writeText('$trimmed\n');
    return 0;
  }
}

/// `dirname NAME...`: путь без последнего компонента. Без слэшей — `.`, корень — `/`.
final class _Dirname implements Applet {
  const _Dirname();

  @override
  String get name => 'dirname';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args);
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    if (parsed.operands.isEmpty) return usageError(io, name, 'missing operand');
    for (final operand in parsed.operands) {
      io.stdout.writeText('${dirOf(operand)}\n');
    }
    return 0;
  }
}

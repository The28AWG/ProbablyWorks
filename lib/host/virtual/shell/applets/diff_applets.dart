import 'dart:convert';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:probably_works/core/util/line_diff.dart';
import 'package:probably_works/host/virtual/shell/applets/applet.dart';
import 'package:probably_works/host/virtual/shell/applets/applet_args.dart';
import 'package:probably_works/host/virtual/shell/shell_io.dart';

/// Сравнение файлов: `diff -u` (единственный формат, который поддерживается) и `cmp`.
final List<Applet> diffApplets = [const _Diff(), const _Cmp()];

/// Контекст вокруг изменения в unified-формате, как у GNU по умолчанию.
const _context = 3;

/// `diff -u FILE1 FILE2`. Выход: 0 — одинаково, 1 — различаются, 2 — ошибка (как у GNU). Обычный
/// (не unified) формат не реализован: без `-u` выводится ошибка, а не чужой вывод.
final class _Diff implements Applet {
  const _Diff();

  @override
  String get name => 'diff';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, flags: 'u');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    if (!parsed.has('u')) {
      io.stderr.writeText('diff: only the unified format (-u) is supported\n');
      return 2;
    }
    if (parsed.operands.length != 2) {
      io.stderr.writeText('diff: two file operands are required\n');
      return 2;
    }
    final [first, second] = parsed.operands;
    final before = await readSource(io, name, first);
    final after = await readSource(io, name, second);
    if (before == null || after == null) return 2;

    final oldLabel = await _label(io, first);
    final newLabel = await _label(io, second);
    final hunks = _unified(_text(before), _text(after));
    if (hunks.isEmpty) return 0;
    io.stdout.writeText('--- $oldLabel\n+++ $newLabel\n${hunks.join()}');
    return 1;
  }

  /// Заголовок файла: путь и время изменения, как в GNU (`2023-11-14 22:13:20.000000000 +0000`).
  /// Для stdin время текущее, потому что у потока его нет.
  Future<String> _label(AppletIo io, String operand) async {
    if (operand == '-') return '-\t${_stamp(io.fs.now())}';
    final node = await io.fs.stat(operand, cwd: io.cwd);
    return '$operand\t${_stamp(node?.mtime ?? io.fs.now())}';
  }
}

/// Текст файла без одного завершающего `\n`: построчный diff делит по `\n`, и пустой хвост дал бы
/// ложную строку. Признак отсутствующего `\n` в конце файла GNU печатает отдельно; здесь он не выводится.
String _text(Uint8List bytes) {
  final text = utf8.decode(bytes, allowMalformed: true);
  return text.endsWith('\n') ? sliceText(text, 0, text.length - 1) : text;
}

/// Номер строки (с единицы) для байта [index], как у GNU cmp: строка — всё до очередного `\n`
/// включительно, поэтому сам `\n` относится к строке, которую он завершает.
int _lineOf(Uint8List bytes, int index) {
  var line = 1;
  for (var j = 0; j < index; j++) {
    if (bytes[j] == 0x0a) line++;
  }
  return line;
}

/// Формат времени GNU diff: `YYYY-MM-DD HH:MM:SS.000000000 +0000` в UTC.
String _stamp(int seconds) {
  final time = DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}:${two(time.second)}.000000000 +0000';
}

/// Hunks unified-формата: изменения группируются, контекст [_context] строк, соседние участки
/// с перекрытием объединяются. Пустой список — файлы одинаковы.
List<String> _unified(String before, String after) {
  final lines = LineDiff.compute(before, after);
  if (lines.every((line) => line.kind == DiffKind.same)) return const [];

  // Сколько строк каждого файла стоит до позиции i: нужно для номеров в заголовке `@@`.
  final oldBefore = List<int>.filled(lines.length + 1, 0);
  final newBefore = List<int>.filled(lines.length + 1, 0);
  for (var i = 0; i < lines.length; i++) {
    oldBefore[i + 1] = oldBefore[i] + (lines[i].kind == DiffKind.add ? 0 : 1);
    newBefore[i + 1] =
        newBefore[i] + (lines[i].kind == DiffKind.remove ? 0 : 1);
  }

  final ranges = <(int, int)>[];
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].kind == DiffKind.same) continue;
    final start = i - _context < 0 ? 0 : i - _context;
    final end = min(lines.length - 1, i + _context);
    if (ranges.isNotEmpty && start <= ranges.last.$2 + 1) {
      ranges[ranges.length - 1] = (ranges.last.$1, end);
    } else {
      ranges.add((start, end));
    }
  }

  final hunks = <String>[];
  for (final (start, end) in ranges) {
    final oldCount = oldBefore[end + 1] - oldBefore[start];
    final newCount = newBefore[end + 1] - newBefore[start];
    final buffer = StringBuffer(
      '@@ -${_range(oldBefore[start], oldCount)} '
      '+${_range(newBefore[start], newCount)} @@\n',
    );
    for (var i = start; i <= end; i++) {
      final line = lines[i];
      final prefix = switch (line.kind) {
        DiffKind.same => ' ',
        DiffKind.add => '+',
        DiffKind.remove => '-',
      };
      buffer.write('$prefix${line.text}\n');
    }
    hunks.add(buffer.toString());
  }
  return hunks;
}

/// Диапазон `start,count` в заголовке hunk. Один элемент — без счётчика; пустой — `start-1,0`, как у GNU.
String _range(int before, int count) {
  if (count == 0) return '$before,0';
  final start = before + 1;
  return count == 1 ? '$start' : '$start,$count';
}

/// `cmp [-s] FILE1 FILE2`. Выход: 0 — одинаковы, 1 — различаются, 2 — ошибка. Без `-s` печатает первое
/// различие: байт и строку, как GNU.
final class _Cmp implements Applet {
  const _Cmp();

  @override
  String get name => 'cmp';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, flags: 's');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    if (parsed.operands.length < 2) {
      final after = parsed.operands.isEmpty ? name : parsed.operands.first;
      io.stderr.writeText("cmp: missing operand after '$after'\n");
      return 2;
    }
    final [first, second] = parsed.operands;
    final a = await readSource(io, name, first);
    final b = await readSource(io, name, second);
    if (a == null || b == null) return 2;

    final silent = parsed.has('s');
    final limit = min(a.length, b.length);
    for (var i = 0; i < limit; i++) {
      if (a[i] == b[i]) continue;
      if (!silent) {
        io.stdout.writeText(
          '$first $second differ: char ${i + 1}, line ${_lineOf(a, i)}\n',
        );
      }
      return 1;
    }
    if (a.length == b.length) return 0;
    if (!silent) {
      // Пустой короткий файл GNU описывает отдельно: позиции в нём нет, номер строки не определён.
      final shorter = a.length < b.length ? first : second;
      final shorterBytes = a.length < b.length ? a : b;
      if (limit == 0) {
        io.stderr.writeText('cmp: EOF on $shorter which is empty\n');
      } else {
        io.stderr.writeText(
          'cmp: EOF on $shorter after byte $limit, '
          'line ${_lineOf(shorterBytes, limit - 1)}\n',
        );
      }
    }
    return 1;
  }
}

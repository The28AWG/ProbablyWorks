/// Разбор и применение unified diff к одному текстовому файлу.
///
/// Формат намеренно уже `git apply`: поддерживаются заголовки `@@`, строки
/// контекста, удаления и добавления. Заголовки файлов (`diff --git`, `---`, `+++`)
/// до первого хунка игнорируются. Несколько файлов в одном патче не
/// поддерживаются: инструмент применяет патч к одному пути.
library;

import 'package:probably_works/core/util/char_substring.dart';

enum UnifiedDiffLineKind { context, addition, deletion }

/// Одна строка хунка без префикса ` `, `+` или `-`.
final class UnifiedDiffLine {
  const UnifiedDiffLine(this.kind, this.text);

  final UnifiedDiffLineKind kind;
  final String text;
}

/// Один блок `@@ -old +new @@` с проверенными счётчиками строк.
final class UnifiedDiffHunk {
  const UnifiedDiffHunk({
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
    required this.lines,
  });

  final int oldStart;
  final int oldCount;
  final int newStart;
  final int newCount;
  final List<UnifiedDiffLine> lines;

  String get header => '@@ -$oldStart,$oldCount +$newStart,$newCount @@';
}

/// Патч одного файла.
final class UnifiedDiff {
  const UnifiedDiff(this.hunks);

  final List<UnifiedDiffHunk> hunks;

  bool get isEmpty => hunks.isEmpty;
}

final _hunkHeader = RegExp(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@');

/// Разбирает unified diff. Бросает [FormatException] с понятной причиной:
/// неизвестная строка, неверный заголовок или несовпадение счётчиков.
UnifiedDiff parseUnifiedDiff(String patch) {
  if (patch.trim().isEmpty) {
    throw const FormatException('patch is empty');
  }
  final rawLines = patch.replaceAll('\r\n', '\n').split('\n');
  final hunks = <UnifiedDiffHunk>[];
  var index = 0;

  // Заголовки одного файла до первого хунка не нужны: путь задаётся отдельно.
  while (index < rawLines.length && !rawLines[index].startsWith('@@')) {
    final line = rawLines[index];
    if (line.trim().isEmpty ||
        line.startsWith('diff --git ') ||
        line.startsWith('index ') ||
        line.startsWith('new file mode ') ||
        line.startsWith('deleted file mode ') ||
        line.startsWith('--- ') ||
        line.startsWith('+++ ')) {
      index++;
      continue;
    }
    throw FormatException('expected a hunk header, got: $line');
  }

  while (index < rawLines.length) {
    final headerLine = rawLines[index];
    final match = _hunkHeader.firstMatch(headerLine);
    if (match == null) {
      throw FormatException('invalid hunk header: $headerLine');
    }
    final oldStart = int.parse(match.group(1)!);
    final oldCount = int.tryParse(match.group(2) ?? '') ?? 1;
    final newStart = int.parse(match.group(3)!);
    final newCount = int.tryParse(match.group(4) ?? '') ?? 1;
    index++;

    final lines = <UnifiedDiffLine>[];
    while (index < rawLines.length && !rawLines[index].startsWith('@@')) {
      final raw = rawLines[index];
      // Пустая последняя строка — хвостовой перевод строки самого патча,
      // а не пустая строка контекста (её пишут как ` `).
      if (raw.isEmpty && index == rawLines.length - 1) {
        index++;
        continue;
      }
      if (raw.startsWith('\\')) {
        // `\ No newline at end of file` не меняет содержимое строки.
        index++;
        continue;
      }
      if (raw.isEmpty) {
        lines.add(const UnifiedDiffLine(UnifiedDiffLineKind.context, ''));
        index++;
        continue;
      }
      switch (raw[0]) {
        case ' ':
          lines.add(
            UnifiedDiffLine(UnifiedDiffLineKind.context, charFrom(raw, 1)),
          );
        case '+':
          lines.add(
            UnifiedDiffLine(UnifiedDiffLineKind.addition, charFrom(raw, 1)),
          );
        case '-':
          lines.add(
            UnifiedDiffLine(UnifiedDiffLineKind.deletion, charFrom(raw, 1)),
          );
        default:
          throw FormatException('invalid hunk line: $raw');
      }
      index++;
    }

    final actualOld = lines
        .where((line) => line.kind != UnifiedDiffLineKind.addition)
        .length;
    final actualNew = lines
        .where((line) => line.kind != UnifiedDiffLineKind.deletion)
        .length;
    if (actualOld != oldCount || actualNew != newCount) {
      throw FormatException(
        'hunk "$headerLine" declares -$oldCount/+$newCount, '
        'but contains -$actualOld/+$actualNew lines',
      );
    }
    hunks.add(
      UnifiedDiffHunk(
        oldStart: oldStart,
        oldCount: oldCount,
        newStart: newStart,
        newCount: newCount,
        lines: lines,
      ),
    );
  }

  if (hunks.isEmpty) {
    throw const FormatException('patch has no hunks');
  }
  return UnifiedDiff(hunks);
}

/// Применяет патч ко всему тексту сразу. Любое несовпадение контекста или
/// счётчиков бросает [FormatException]; частично изменённый текст не возвращается.
///
/// Хунки применяются снизу вверх, поэтому номера строк в патче относятся к
/// исходному файлу и не сдвигаются от предыдущих добавлений.
/// Индекс вставки для пустого хунка (`-N,0`) и начала удаления для непустого.
int _oldIndex(UnifiedDiffHunk hunk) =>
    hunk.oldCount == 0 ? hunk.oldStart : hunk.oldStart - 1;

String applyUnifiedDiff(String text, UnifiedDiff diff) {
  if (diff.hunks.isEmpty) {
    throw const FormatException('patch has no hunks');
  }
  final eol = text.contains('\r\n') ? '\r\n' : '\n';
  final normalized = text.replaceAll('\r\n', '\n');
  final hasTrailingNewline = normalized.endsWith('\n');
  final lines = normalized.isEmpty ? <String>[] : normalized.split('\n');
  if (hasTrailingNewline && lines.isNotEmpty) lines.removeLast();

  final ordered = List<UnifiedDiffHunk>.of(diff.hunks)
    ..sort((a, b) => a.oldStart.compareTo(b.oldStart));
  var previousEnd = 0;
  for (final hunk in ordered) {
    if (hunk.oldStart == 0 && hunk.oldCount != 0) {
      throw FormatException(
        'hunk "${hunk.header}" starts at 0 but removes ${hunk.oldCount} lines',
      );
    }
    final start = _oldIndex(hunk);
    if (start < previousEnd) {
      throw FormatException('hunks overlap at "${hunk.header}"');
    }
    if (start + hunk.oldCount > lines.length) {
      throw FormatException(
        'hunk "${hunk.header}" is outside the file '
        '(${lines.length} lines)',
      );
    }
    previousEnd = start + hunk.oldCount;
  }

  final result = List<String>.of(lines);
  for (final hunk in ordered.reversed) {
    final start = _oldIndex(hunk);
    var cursor = start;
    final replacement = <String>[];
    for (final line in hunk.lines) {
      if (line.kind == UnifiedDiffLineKind.addition) {
        replacement.add(line.text);
        continue;
      }
      if (cursor >= result.length || result[cursor] != line.text) {
        final actual = cursor < result.length
            ? result[cursor]
            : '(end of file)';
        throw FormatException(
          'context mismatch at line ${cursor + 1} in "${hunk.header}": '
          'expected "$line.text", got "$actual"',
        );
      }
      if (line.kind == UnifiedDiffLineKind.context) {
        replacement.add(line.text);
      }
      cursor++;
    }
    if (cursor - start != hunk.oldCount ||
        replacement.length != hunk.newCount) {
      throw FormatException(
        'hunk "${hunk.header}" does not match the file after validation',
      );
    }
    result.replaceRange(start, cursor, replacement);
  }

  if (result.isEmpty) return '';
  final joined = result.join('\n');
  final withNewline = hasTrailingNewline ? '$joined\n' : joined;
  return eol == '\n' ? withNewline : withNewline.replaceAll('\n', eol);
}

import 'dart:convert';

import 'package:probably_works/app/ui/file_change_view.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/tools/tool_catalog.dart';
import 'package:pw_agent/core/util/ansi_text.dart';
import 'package:pw_agent/core/util/line_diff.dart';
import 'package:pw_agent/core/util/unified_diff.dart';

/// Сколько строк изменения рисуем в ленте. Дальше карточка скроллится уже по построенным
/// строкам, а тысячи виджетов на длинной записи подвешивают ленту. Счётчики в заголовке
/// остаются по полному изменению.
const _maxShownLines = 400;

final _finalNewline = RegExp(r'\n$');

/// Изменение файла для журнала шага. `null`, если это не запись и не правка или аргументы не разобрать:
/// тогда шаг остаётся обычной командой.
///
/// `write_file` показывается как новый файл git. Инструмент записывает содержимое целиком, а предыдущий
/// текст в запуске не хранится, поэтому каждая строка — добавление, даже если файл уже существовал.
/// `edit_file` — unified diff фрагмента `old_string` → `new_string`. Номера идут с 1 внутри фрагмента:
/// окружающего файла в аргументах нет. Общий хвостовой перевод строки не считается отдельной строкой.
/// [maxLines] ограничивает число нарисованных строк; счётчики считаются по всему изменению.
FileChange? fileChangeOf(ToolRun run, {int maxLines = _maxShownLines}) {
  final kind = switch (run.toolName) {
    ToolNames.writeFile => FileChangeKind.created,
    ToolNames.editFile || ToolNames.applyPatch => FileChangeKind.edited,
    _ => null,
  };
  if (kind == null) return null;
  final args = _args(run.argsJson);
  if (args == null) return null;
  final path = _path(run, args);
  return switch (kind) {
    FileChangeKind.created => _created(path, args, maxLines),
    FileChangeKind.edited =>
      run.toolName == ToolNames.applyPatch
          ? _patched(path, args, maxLines)
          : _edited(path, args, maxLines),
  };
}

Map<String, dynamic>? _args(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } on FormatException {
    return null;
  }
  return null;
}

/// Команда запуска хранит уже разрешённый путь (`write /abs/...`). Относительный путь из аргументов
/// остаётся запасным: у старых строк команды может не быть.
String _path(ToolRun run, Map<String, dynamic> args) {
  final command = run.command;
  const prefix = 'write ';
  if (command != null && command.startsWith(prefix)) {
    final resolved = command.replaceFirst(prefix, '');
    if (resolved.isNotEmpty) return resolved;
  }
  final path = args['path'];
  if (path is String) return path;
  return '';
}

String? _text(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value is! String) return null;
  return plainTerminalText(value);
}

String _withoutFinalNewline(String text) =>
    text.endsWith('\n') ? text.replaceFirst(_finalNewline, '') : text;

List<String> _lines(String text) => text.isEmpty ? const [] : text.split('\n');

String _hunk(int oldCount, int newCount) {
  if (oldCount == 0 && newCount == 0) return '';
  final oldStart = oldCount == 0 ? 0 : 1;
  final newStart = newCount == 0 ? 0 : 1;
  return '@@ -$oldStart,$oldCount +$newStart,$newCount @@';
}

FileChange? _created(String path, Map<String, dynamic> args, int maxLines) {
  final content = _text(args, 'content');
  if (content == null) return null;
  final raw = _lines(_withoutFinalNewline(content));
  final shown = raw.length <= maxLines ? raw : raw.sublist(0, maxLines);
  return FileChange(
    kind: FileChangeKind.created,
    path: path,
    lines: [
      for (var i = 0; i < shown.length; i++)
        FileChangeLine(
          kind: FileChangeLineKind.addition,
          text: shown[i],
          newNumber: i + 1,
        ),
    ],
    added: raw.length,
    removed: 0,
    copyText: content,
    totalLines: raw.length,
    hunkHeader: _hunk(0, raw.length),
  );
}

FileChange? _patched(String path, Map<String, dynamic> args, int maxLines) {
  final raw = args['patch'];
  if (raw is! String) return null;
  final UnifiedDiff diff;
  try {
    diff = parseUnifiedDiff(raw);
  } on FormatException {
    return null;
  }
  final lines = <FileChangeLine>[];
  var added = 0;
  var removed = 0;
  var total = 0;
  for (final hunk in diff.hunks) {
    var oldNumber = hunk.oldStart == 0 ? 1 : hunk.oldStart;
    var newNumber = hunk.newStart == 0 ? 1 : hunk.newStart;
    for (final line in hunk.lines) {
      total++;
      final text = plainTerminalText(line.text);
      switch (line.kind) {
        case UnifiedDiffLineKind.context:
          if (lines.length < maxLines) {
            lines.add(
              FileChangeLine(
                kind: FileChangeLineKind.context,
                text: text,
                oldNumber: oldNumber,
                newNumber: newNumber,
              ),
            );
          }
          oldNumber++;
          newNumber++;
        case UnifiedDiffLineKind.deletion:
          if (lines.length < maxLines) {
            lines.add(
              FileChangeLine(
                kind: FileChangeLineKind.removal,
                text: text,
                oldNumber: oldNumber,
              ),
            );
          }
          oldNumber++;
          removed++;
        case UnifiedDiffLineKind.addition:
          if (lines.length < maxLines) {
            lines.add(
              FileChangeLine(
                kind: FileChangeLineKind.addition,
                text: text,
                newNumber: newNumber,
              ),
            );
          }
          newNumber++;
          added++;
      }
    }
  }
  return FileChange(
    kind: FileChangeKind.edited,
    path: path,
    lines: lines,
    added: added,
    removed: removed,
    copyText: raw,
    totalLines: total,
    hunkHeader: diff.hunks.length == 1
        ? diff.hunks.single.header
        : '${diff.hunks.length} hunks',
  );
}

FileChange? _edited(String path, Map<String, dynamic> args, int maxLines) {
  final before = _text(args, 'old_string');
  final after = _text(args, 'new_string');
  if (before == null || after == null) return null;
  final diff = LineDiff.compute(
    _withoutFinalNewline(before),
    _withoutFinalNewline(after),
  );
  final lines = <FileChangeLine>[];
  final body = StringBuffer();
  var oldNumber = 1;
  var newNumber = 1;
  var added = 0;
  var removed = 0;
  for (final line in diff) {
    switch (line.kind) {
      case DiffKind.same:
        body.writeln(' ${line.text}');
        if (lines.length < maxLines) {
          lines.add(
            FileChangeLine(
              kind: FileChangeLineKind.context,
              text: line.text,
              oldNumber: oldNumber,
              newNumber: newNumber,
            ),
          );
        }
        oldNumber++;
        newNumber++;
      case DiffKind.remove:
        body.writeln('-${line.text}');
        if (lines.length < maxLines) {
          lines.add(
            FileChangeLine(
              kind: FileChangeLineKind.removal,
              text: line.text,
              oldNumber: oldNumber,
            ),
          );
        }
        oldNumber++;
        removed++;
      case DiffKind.add:
        body.writeln('+${line.text}');
        if (lines.length < maxLines) {
          lines.add(
            FileChangeLine(
              kind: FileChangeLineKind.addition,
              text: line.text,
              newNumber: newNumber,
            ),
          );
        }
        newNumber++;
        added++;
    }
  }
  final header = _hunk(oldNumber - 1, newNumber - 1);
  return FileChange(
    kind: FileChangeKind.edited,
    path: path,
    lines: lines,
    added: added,
    removed: removed,
    copyText: header.isEmpty
        ? ''
        : '$header\n${_withoutFinalNewline(body.toString())}',
    totalLines: diff.length,
    hunkHeader: header,
    replaceAll: args['replace_all'] == true,
  );
}

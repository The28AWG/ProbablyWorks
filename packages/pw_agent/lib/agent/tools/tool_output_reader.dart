/// Общее чтение сохранённого длинного текста: вывода запуска, содержимого
/// вложения. Один формат ответа на все источники, чтобы модель учила одно
/// правило, а не отдельное для каждого инструмента.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:pw_agent/agent/tools/tool_args.dart';
import 'package:pw_agent/agent/tools/tool_types.dart';
import 'package:pw_agent/core/util/ansi_text.dart';
import 'package:pw_agent/core/util/char_substring.dart';

/// Сколько символов сохранённого текста отдаётся по умолчанию. Меньше предела
/// удержания: прочитанное остаётся в истории хода и тратит окно модели.
const defaultOutputReadChars = 8000;

/// Потолок одного чтения. Больше не полезно: столько же максимум отдаётся
/// модели за один инструментальный вызов.
const maxOutputReadChars = 60000;

/// Сколько символов одной строки показывает поиск: длинные JSON-логи не
/// должны съедать весь лимит ответа.
const _grepLineChars = 500;

/// Максимум строк окружения вокруг совпадения.
const _grepContextMax = 50;

/// Максимум совпадений за один вызов поиска.
const _grepMatchesMax = 200;

/// Единый формат чтения сохранённого текста.
///
/// `tail` показывает конец, `chunk` читает окно по точному смещению, `grep`
/// ищет строки с окружением. Смещения считаются в символах (не в байтах):
/// так их понимает и `mode=chunk`, и навигация `tail`.
final class ToolOutputReader {
  const ToolOutputReader(this.target);

  /// Как продолжить чтение без параметров режима: например
  /// `read_run_output run_id=abc`. К подсказке добавляются `mode`, `offset` и `limit`.
  final String target;

  /// Читает [text] по аргументам вызова. [header] описывает источник: строки
  /// попадают в ответ перед телом, чтобы модель видела, что именно она читает.
  /// Шапка копируется: вызывающий код не должен зависеть от того, что режим
  /// чтения дописал в неё свои поля.
  ToolResult read(Map<String, dynamic> args, String text, List<String> header) {
    final lines = [...header];
    final limit = toolIntArg(
      args,
      'limit',
      min: 1,
      max: maxOutputReadChars,
      fallback: defaultOutputReadChars,
    );
    if (text.isEmpty) {
      lines.add('no text');
      return ToolResult(lines.join('\n'));
    }
    return switch (modeOf(args)) {
      'grep' => _grep(args, text, lines, limit),
      'chunk' => _chunk(args, text, lines, limit),
      _ => _tail(text, lines, limit),
    };
  }

  /// Режим чтения. Неизвестное значение — ошибка аргумента, а не молчаливый `tail`.
  static String modeOf(Map<String, dynamic> args) {
    final value = args['mode'];
    if (value == null) return 'tail';
    if (value is! String || !const {'tail', 'chunk', 'grep'}.contains(value)) {
      throw ArgumentError.value(value, 'mode', 'tail, chunk or grep expected');
    }
    return value;
  }

  /// Последние [limit] символов. Смещение отдаётся явно, чтобы можно было
  /// продолжить вглубь через `mode=chunk`.
  ToolResult _tail(String text, List<String> header, int limit) {
    final total = text.characters.length;
    final start = total > limit ? total - limit : 0;
    final body = charFrom(text, start);
    header
      ..add('start_offset: $start')
      ..add('total: $total chars');
    final nav = start > 0
        ? '[earlier text: $target mode=chunk offset=${math.max(0, start - limit)} '
              'limit=$limit]'
        : '[start of retained text]';
    return ToolResult('${header.join('\n')}\n\n$body\n\n$nav');
  }

  /// Окно [limit] символов с точного смещения [offset].
  ToolResult _chunk(
    Map<String, dynamic> args,
    String text,
    List<String> header,
    int limit,
  ) {
    final offset = toolIntArg(args, 'offset', min: 0, fallback: 0);
    final total = text.characters.length;
    if (offset >= total) {
      header.add('offset $offset is past the end ($total chars)');
      return ToolResult(header.join('\n'));
    }
    final body = charPrefix(charFrom(text, offset), limit);
    final next = offset + body.characters.length;
    header
      ..add('offset: $offset')
      ..add('total: $total chars');
    final nav = next < total
        ? '[more: continue with $target mode=chunk offset=$next limit=$limit]'
        : '[end]';
    return ToolResult('${header.join('\n')}\n\n$body\n\n$nav');
  }

  /// Поиск по строкам. Совпадение отдаётся с окружением и точным смещением:
  /// по нему можно перейти в `mode=chunk` и прочитать окно целиком.
  ToolResult _grep(
    Map<String, dynamic> args,
    String text,
    List<String> header,
    int limit,
  ) {
    final pattern = toolStringArg(args, 'pattern');
    final regex = args['regex'] != false;
    final ignoreCase = args['ignore_case'] == true;
    final context = toolIntArg(
      args,
      'context',
      min: 0,
      max: _grepContextMax,
      fallback: 2,
    );
    final maxMatches = toolIntArg(
      args,
      'max_matches',
      min: 1,
      max: _grepMatchesMax,
      fallback: 30,
    );
    final matchOffset = toolIntArg(args, 'match_offset', min: 0, fallback: 0);
    final RegExp expression;
    try {
      expression = RegExp(
        regex ? pattern : RegExp.escape(pattern),
        caseSensitive: !ignoreCase,
      );
    } on FormatException catch (error) {
      return ToolResult('invalid pattern: ${error.message}', isError: true);
    }
    final lines = text.split('\n');
    // Смещения считаются в символах, как их принимает mode=chunk: та же
    // единица, что отдаёт charFrom/charPrefix.
    final starts = <int>[];
    var position = 0;
    for (final line in lines) {
      starts.add(position);
      position += line.characters.length + 1;
    }
    final hits = <int>[];
    for (var i = 0; i < lines.length; i++) {
      // ANSI-последовательности не должны мешать ни шаблону, ни чтению.
      if (expression.hasMatch(plainTerminalText(lines[i]))) hits.add(i);
    }
    header
      ..add(
        'pattern: ${jsonEncode(pattern)} '
        '(${regex ? 'regex' : 'literal'}, '
        '${ignoreCase ? 'case-insensitive' : 'case-sensitive'})',
      )
      ..add('matches: ${hits.length}');
    if (hits.isEmpty) {
      header.add(
        'no matches; try ignore_case, regex=false or a shorter pattern',
      );
      return ToolResult(header.join('\n'));
    }
    if (matchOffset >= hits.length) {
      header.add('match_offset $matchOffset is past the last match');
      return ToolResult(header.join('\n'));
    }
    final groups = <String>[];
    var covered = 0;
    var length = 0;
    var cut = false;
    var index = matchOffset;
    while (index < hits.length && covered < maxMatches) {
      final match = hits[index];
      final first = math.max(0, match - context);
      var last = math.min(lines.length - 1, match + context);
      final matchLines = <int>{match};
      var scan = index + 1;
      // Пересекающиеся или соседние окружения склеиваются: иначе следующая
      // страница повторила бы те же строки как контекст.
      while (scan < hits.length) {
        final next = hits[scan];
        if (next - context > last + 1) break;
        matchLines.add(next);
        last = math.max(last, math.min(lines.length - 1, next + context));
        scan++;
      }
      final group = _group(lines, starts, matchLines, first, last);
      if (groups.isEmpty && group.characters.length > limit) {
        // Даже один фрагмент не влез: отдаём начало и честно предупреждаем.
        groups.add(charPrefix(group, limit));
        cut = true;
        covered = scan - matchOffset;
        break;
      }
      if (length + group.characters.length > limit) break;
      groups.add(group);
      length += group.characters.length + 4;
      covered = scan - matchOffset;
      index = scan;
    }
    header.add('showing: ${matchOffset + 1}-${matchOffset + covered}');
    final next = matchOffset + covered;
    final nav = [
      if (cut) '[cut by the character limit; narrow the pattern]',
      if (next < hits.length) '[more matches: match_offset=$next]' else '[end]',
    ].join('\n');
    return ToolResult(
      '${header.join('\n')}\n\n${groups.join('\n--\n')}\n\n$nav',
    );
  }

  /// Одна группа строк с пометкой совпадений и смещением начала каждой строки.
  String _group(
    List<String> lines,
    List<int> starts,
    Set<int> matchLines,
    int first,
    int last,
  ) {
    final buffer = StringBuffer();
    for (var i = first; i <= last; i++) {
      if (buffer.isNotEmpty) buffer.writeln();
      final plain = plainTerminalText(lines[i]);
      final shown = plain.characters.length > _grepLineChars
          ? '${charPrefix(plain, _grepLineChars)}…'
          : plain;
      buffer.write(
        matchLines.contains(i)
            ? '[line ${i + 1}, offset ${starts[i]}] $shown'
            : '[line ${i + 1}] $shown',
      );
    }
    return buffer.toString();
  }
}

/// Текст результата для модели с общим пределом.
///
/// Полный текст сохраняется в запуске и доступен через [target]; модели уходит
/// хвост, как терминальный scrollback. Так один результат инструмента не может
/// занять всё окно модели. Короткий текст возвращается как есть вместе с
/// [header]: шапка описывает источник, а не объём.
String clampToolText({
  required String text,
  required int maxChars,
  required List<String> header,
  required String target,
}) {
  final total = text.characters.length;
  final body = total <= maxChars ? text : charSuffix(text, maxChars);
  final shown = body.characters.length;
  final lines = [
    ...header,
    'output: $total chars',
    if (shown < total) 'showing: last $shown chars',
    if (shown < total) 'read more: $target (mode=chunk or grep)',
  ];
  return body.isEmpty ? lines.join('\n') : '${lines.join('\n')}\n$body';
}

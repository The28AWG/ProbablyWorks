import 'package:probably_works/host/virtual/shell/shell_ast.dart';
import 'package:probably_works/host/virtual/shell/shell_errors.dart';
import 'package:probably_works/host/virtual/shell/shell_parser.dart';
import 'package:probably_works/host/virtual/shell/shell_scan.dart';
import 'package:probably_works/host/virtual/shell/shell_text.dart';
import 'package:probably_works/host/virtual/virtual_limits.dart';

/// Разбор сырого текста слова на части: кавычки, `$`-подстановки, `$(...)`, тильда и экранирование.
///
/// Порядок и правила совпадают с bash: одинарные кавычки ничего не раскрывают, в двойных работают `$`
/// и `\` (только перед `$`, `` ` ``, `"`, `\` и переводом строки), вне кавычек `\` экранирует любой символ.
/// Здесь-документ без кавычек в разделителе разбирается как содержимое двойных кавычек, но `"` в нём литерал.
///
/// Вся грамматика `${...}` разбирается здесь: индекс, длина, косвенность, ключи, имена и модификаторы.
/// Операнды модификаторов — вложенные слова, поэтому внутри них работают кавычки, `$` и подстановки.
/// Внутри двойных кавычек операнд разбирается как содержимое кавычек: `'` в нём литерал, как в bash.
final class ShellWordParser {
  ShellWordParser({required this.depth, required this.limits});

  /// Глубина вложенности подстановок. Нужна, чтобы `$(...)` внутри `$(...)` не уходило в бесконечность.
  final int depth;
  final VirtualLimits limits;

  static final _nameStart = RegExp('[A-Za-z_]');
  static final _nameChar = RegExp('[A-Za-z0-9_]');
  static final _digit = RegExp('[0-9]');

  /// Разбирает слово командной строки. Тильда раскрывается только в самом начале слова.
  ShellWord parse(String raw) =>
      ShellWord(_parts(raw, dq: false, heredoc: false));

  /// Разбирает значение присваивания (`x=...`): значение уже начинается после `=`, поэтому тильда в начале
  /// раскрывается, а после каждого `:` тоже, как в bash (`PATH=/bin:~/bin`).
  ShellWord parseAssignmentValue(String raw) =>
      ShellWord(_parts(raw, dq: false, heredoc: false, assignment: true));

  /// Тело здесь-документа с расширениями.
  ShellWord parseHeredoc(String body) =>
      ShellWord(_parts(body, dq: true, heredoc: true));

  /// Выражение арифметики (`$((...))`, `((...))`, `for ((...))`, срезы `${x:...}`) как слово. `$VAR` и
  /// подстановки раскрываются до вычисления. Кавычки `"..."` снимаются, `'` остаётся литерой: так bash
  /// принимает `$(( "3" + 1 ))` и отвергает `$(( '3' + 1 ))`. Тильда не раскрывается.
  ShellWord parseArithmetic(String raw) =>
      ShellWord(_parts(raw, dq: false, heredoc: false, inDq: true));

  /// Части текста. [dq] — текст внутри двойных кавычек целиком (`"..."`): тогда `'` и `"` литеральны.
  /// [inDq] — операнд `${...}`, стоящий внутри двойных кавычек: `'` литеральна, `"` открывает вложенные
  /// кавычки, а `\` экранирует только `$`, `` ` ``, `"` и `\`.
  List<WordPart> _parts(
    String raw, {
    required bool dq,
    required bool heredoc,
    bool assignment = false,
    bool inDq = false,
  }) {
    final parts = <WordPart>[];
    final buffer = StringBuffer();
    void flush() {
      if (buffer.isEmpty) return;
      parts.add(LiteralPart(buffer.toString(), quoted: dq));
      buffer.clear();
    }

    var i = 0;
    while (i < raw.length) {
      final c = raw[i];
      if (!dq) {
        if (c == "'" && !inDq) {
          flush();
          final end = ShellScan.singleQuoteEnd(raw, i);
          parts.add(LiteralPart(_slice(raw, i + 1, end - 1), quoted: true));
          i = end;
          continue;
        }
        if (c == '"') {
          flush();
          final end = ShellScan.doubleQuoteEnd(raw, i);
          final inner = _parts(
            _slice(raw, i + 1, end - 1),
            dq: true,
            heredoc: false,
          );
          parts.add(QuotedPart(inner));
          i = end;
          continue;
        }
        if (c == r'\') {
          if (inDq) {
            // Внутри двойных кавычек `\` работает по правилам кавычек: экранирует только спецсимволы.
            final next = i + 1 < raw.length ? raw[i + 1] : '';
            if (next == '\n') {
              i += 2;
            } else if (next.isNotEmpty && r'$`"\'.contains(next)) {
              buffer.write(next);
              i += 2;
            } else {
              buffer.write(c);
              i++;
            }
            continue;
          }
          flush();
          if (i + 1 >= raw.length) {
            parts.add(const LiteralPart(r'\', quoted: true));
            i++;
          } else if (raw[i + 1] == '\n') {
            i += 2;
          } else {
            parts.add(LiteralPart(raw[i + 1], quoted: true));
            i += 2;
          }
          continue;
        }
        if (c == '~' &&
            !inDq &&
            (i == 0 || (assignment && raw[i - 1] == ':'))) {
          final next = i + 1 < raw.length ? raw[i + 1] : '';
          if (next.isEmpty || next == '/') {
            flush();
            parts.add(const TildePart());
            i++;
            continue;
          }
          if (_nameStart.hasMatch(next) || next == '+' || next == '-') {
            throw ShellSyntaxException.unsupported(
              'tilde expansion other than ~ and ~/',
            );
          }
        }
      } else if (c == r'\') {
        final next = i + 1 < raw.length ? raw[i + 1] : '';
        final escapable = heredoc ? r'$`\' : r'$`"\';
        if (next == '\n') {
          i += 2;
        } else if (next.isNotEmpty && escapable.contains(next)) {
          buffer.write(next);
          i += 2;
        } else {
          buffer.write(c);
          i++;
        }
        continue;
      }

      if (c == r'$') {
        final expansion = _expansion(raw, i, inDq: dq || inDq);
        if (expansion != null) {
          flush();
          parts.add(expansion.$1);
          i = expansion.$2;
          continue;
        }
      } else if (c == '`') {
        flush();
        final end = ShellScan.backquoteEnd(raw, i);
        final inner = _unescapeBackquote(_slice(raw, i + 1, end - 1));
        parts.add(
          CommandPart(ShellParser.parseNested(inner, depth + 1, limits)),
        );
        i = end;
        continue;
      }
      buffer.write(c);
      i++;
    }
    flush();
    return parts;
  }

  /// Внутри обратных кавычек `\` экранирует только `$`, `` ` `` и `\`, как в bash. Остальные `\` остаются:
  /// от них зависит текст команды (`\n` в `echo`).
  static String _unescapeBackquote(String text) {
    final out = StringBuffer();
    var i = 0;
    while (i < text.length) {
      final c = text[i];
      final next = i + 1 < text.length ? text[i + 1] : '';
      if (c == r'\' && next.isNotEmpty && '\$`\\'.contains(next)) {
        out.write(next);
        i += 2;
      } else {
        out.write(c);
        i++;
      }
    }
    return out.toString();
  }

  /// Подстановка, начинающаяся с `$` в позиции [i]. Возвращает часть и индекс после неё, либо null,
  /// если `$` стоит как обычный символ (в конце слова или перед пробелом). [inDq] — `$` внутри кавычек.
  (WordPart, int)? _expansion(String raw, int i, {required bool inDq}) {
    final next = i + 1 < raw.length ? raw[i + 1] : '';
    if (next == '(') {
      final end = ShellScan.parenEnd(raw, i + 1);
      final inner = _slice(raw, i + 2, end - 1);
      if (inner.startsWith('(')) {
        // `$((...))`: внешние скобки относятся к синтаксису, внутри — выражение. Разбор выражения как
        // слова даёт `$VAR` и подстановки, которые раскрываются до вычисления.
        final expression = _slice(inner, 1, inner.length - 1);
        return (ArithmeticPart(parseArithmetic(expression)), end);
      }
      final script = ShellParser.parseNested(inner, depth + 1, limits);
      return (CommandPart(script), end);
    }
    if (next == '{') {
      final end = ShellScan.braceEnd(raw, i + 1);
      final body = _slice(raw, i + 2, end - 1);
      return (_braced(body, inDq: inDq), end);
    }
    if (next == "'") {
      throw const ShellSyntaxException.unsupported("ANSI-C quoting \$'...'");
    }
    if (next.isNotEmpty && _nameStart.hasMatch(next)) {
      var end = i + 1;
      while (end < raw.length && _nameChar.hasMatch(raw[end])) {
        end++;
      }
      return (ParamPart(_slice(raw, i + 1, end)), end);
    }
    if (next.isNotEmpty &&
        (_digit.hasMatch(next) || '?!#@*-\$'.contains(next))) {
      return (ParamPart(next), i + 2);
    }
    return null;
  }

  /// Содержимое `${...}` без скобок. Порядок разбора повторяет bash: сначала префикс `#` или `!`, затем
  /// имя с необязательным индексом, затем модификатор. Недопустимая форма даёт [BadSubstitutionPart],
  /// которая падает при раскрытии, как в bash. Неподдерживаемый модификатор (`@A`) — явный отказ.
  WordPart _braced(String body, {required bool inDq}) {
    if (body.isEmpty) return BadSubstitutionPart(body);
    var at = 0;
    var kind = ParamKind.value;
    if (body.length > 1 && body[0] == '#') {
      kind = ParamKind.length;
      at = 1;
    } else if (body.length > 1 && body[0] == '!') {
      kind = ParamKind.indirect;
      at = 1;
    }
    if (kind == ParamKind.indirect) {
      // `${!prefix*}` и `${!prefix@}` — имена переменных, а не косвенность.
      final prefixEnd = _identifierEnd(body, at);
      if (prefixEnd > at &&
          prefixEnd == body.length - 1 &&
          (body[prefixEnd] == '*' || body[prefixEnd] == '@')) {
        return ParamPart(
          ShellText.cut(body, at, prefixEnd),
          subscript: AllElements(star: body[prefixEnd] == '*'),
          kind: ParamKind.names,
        );
      }
    }
    final ref = _reference(body, at, inDq: inDq);
    if (ref == null) return BadSubstitutionPart(body);
    if (ref.end == body.length) {
      final sub = ref.subscript;
      // `${!x[@]}` — ключи массива, а не косвенность по элементу.
      final resolvedKind = kind == ParamKind.indirect && sub is AllElements
          ? ParamKind.keys
          : kind;
      return ParamPart(ref.name, subscript: sub, kind: resolvedKind);
    }
    // Длина допускает только имя без модификатора: `${#x:-y}` — недопустимо.
    if (kind == ParamKind.length) return BadSubstitutionPart(body);
    final op = _operator(body, ref.end, inDq: inDq);
    if (op == null) return BadSubstitutionPart(body);
    return ParamPart(ref.name, subscript: ref.subscript, kind: kind, op: op);
  }

  /// Имя с необязательным `[...]` начиная с [at]. Null, если имени нет или `[` не закрыта.
  _Ref? _reference(String body, int at, {required bool inDq}) {
    if (at >= body.length) return null;
    final identEnd = _identifierEnd(body, at);
    if (identEnd > at) {
      final name = ShellText.cut(body, at, identEnd);
      if (identEnd < body.length && body[identEnd] == '[') {
        final close = ShellScan.indexOfTop(body, ']', identEnd + 1);
        if (close < 0) return null;
        final raw = ShellText.cut(body, identEnd + 1, close);
        return _Ref(name, _subscript(raw, inDq: inDq), close + 1);
      }
      return _Ref(name, null, identEnd);
    }
    var end = at;
    while (end < body.length && _digit.hasMatch(body[end])) {
      end++;
    }
    if (end > at) return _Ref(ShellText.cut(body, at, end), null, end);
    if ('@*#?-\$!'.contains(body[at])) return _Ref(body[at], null, at + 1);
    return null;
  }

  /// Индекс в `[...]`: `@` и `*` выбирают все элементы, остальное — выражение или ключ. Операнд индекса
  /// разбирается без удаления кавычек в арифметике, но ключ ассоциативного массива берёт кавычки как в bash.
  ParamSubscript _subscript(String raw, {required bool inDq}) => switch (raw) {
    '@' => const AllElements(star: false),
    '*' => const AllElements(star: true),
    _ => IndexElement(
      ShellWord(_parts(raw, dq: false, heredoc: false, inDq: inDq)),
      raw,
    ),
  };

  /// Модификатор, начинающийся с [pos] в [body]. Null — синтаксис не распознан (тогда `${...}` недопустим).
  /// Бросает [ShellSyntaxException.unsupported] для преобразований, которые не моделируются.
  ParamOp? _operator(String body, int pos, {required bool inDq}) {
    final c = body[pos];
    final next = pos + 1 < body.length ? body[pos + 1] : '';
    ShellWord operand(int from) => ShellWord(
      _parts(ShellText.cut(body, from), dq: false, heredoc: false, inDq: inDq),
    );
    if (c == ':') {
      if (next.isNotEmpty && '-=?+'.contains(next)) {
        return ParamDefaultOp(
          _defaultKind(next),
          operand(pos + 2),
          nullIsUnset: true,
        );
      }
      // `:offset[:length]`: двоеточие внутри выражений смещения и длины не разделяет.
      final rest = ShellText.cut(body, pos + 1);
      final colon = ShellScan.indexOfTop(rest, ':', 0);
      final offsetText = colon < 0 ? rest : ShellText.cut(rest, 0, colon);
      final lengthText = colon < 0 ? null : ShellText.cut(rest, colon + 1);
      if (offsetText.isEmpty || lengthText == '') return null;
      return ParamSliceOp(
        parseArithmetic(offsetText),
        lengthText == null ? null : parseArithmetic(lengthText),
      );
    }
    if ('-=?+'.contains(c)) {
      return ParamDefaultOp(
        _defaultKind(c),
        operand(pos + 1),
        nullIsUnset: false,
      );
    }
    if (c == '#' || c == '%') {
      final longest = next == c;
      return ParamTrimOp(
        prefix: c == '#',
        longest: longest,
        pattern: operand(pos + (longest ? 2 : 1)),
      );
    }
    if (c == '/') {
      var mode = ReplaceMode.first;
      var from = pos + 1;
      if (next == '/') {
        mode = ReplaceMode.all;
        from = pos + 2;
      } else if (next == '#') {
        mode = ReplaceMode.prefix;
        from = pos + 2;
      } else if (next == '%') {
        mode = ReplaceMode.suffix;
        from = pos + 2;
      }
      final split = ShellScan.indexOfTop(body, '/', from);
      final patternEnd = split < 0 ? body.length : split;
      final pattern = ShellWord(
        _parts(
          ShellText.cut(body, from, patternEnd),
          dq: false,
          heredoc: false,
          inDq: inDq,
        ),
      );
      final replacement = split < 0 ? const ShellWord([]) : operand(split + 1);
      return ParamReplaceOp(mode, pattern, replacement);
    }
    if (c == '^' || c == ',' || c == '~') {
      final all = next == c;
      final from = pos + (all ? 2 : 1);
      final mode = switch (c) {
        '^' => all ? ParamCaseMode.upperAll : ParamCaseMode.upperFirst,
        ',' => all ? ParamCaseMode.lowerAll : ParamCaseMode.lowerFirst,
        _ => all ? ParamCaseMode.toggleAll : ParamCaseMode.toggleFirst,
      };
      return ParamCaseOp(mode, from < body.length ? operand(from) : null);
    }
    if (c == '@' && body.length - pos == 2) {
      final letter = body[pos + 1];
      if ('AaP'.contains(letter)) {
        throw ShellSyntaxException.unsupported(
          'parameter transformation @$letter',
        );
      }
      if ('QEULul'.contains(letter)) return ParamTransformOp(letter);
    }
    return null;
  }

  static ParamDefaultKind _defaultKind(String op) => switch (op) {
    '-' => ParamDefaultKind.useDefault,
    '=' => ParamDefaultKind.assign,
    '?' => ParamDefaultKind.error,
    _ => ParamDefaultKind.alternative,
  };

  /// Позиция после идентификатора, начинающегося с [at], или [at], если идентификатора нет.
  static int _identifierEnd(String text, int at) {
    if (at >= text.length || !_nameStart.hasMatch(text[at])) return at;
    var end = at + 1;
    while (end < text.length && _nameChar.hasMatch(text[end])) {
      end++;
    }
    return end;
  }

  static String _slice(String text, int start, int end) =>
      String.fromCharCodes(text.codeUnits, start, end);
}

/// Имя параметра из `${...}`: [name], индекс [subscript] (null — без индекса) и позиция сразу после него.
final class _Ref {
  const _Ref(this.name, this.subscript, this.end);

  final String name;
  final ParamSubscript? subscript;
  final int end;
}

import 'package:probably_works/host/virtual/shell/shell_ast.dart';
import 'package:probably_works/host/virtual/shell/shell_errors.dart';
import 'package:probably_works/host/virtual/shell/shell_parser.dart';
import 'package:probably_works/host/virtual/shell/shell_scan.dart';
import 'package:probably_works/host/virtual/virtual_limits.dart';

/// Разбор сырого текста слова на части: кавычки, `$`-подстановки, `$(...)`, тильда и экранирование.
///
/// Порядок и правила совпадают с bash: одинарные кавычки ничего не раскрывают, в двойных работают `$`
/// и `\` (только перед `$`, `` ` ``, `"`, `\` и переводом строки), вне кавычек `\` экранирует любой символ.
/// Здесь-документ без кавычек в разделителе разбирается как содержимое двойных кавычек, но `"` в нём литерал.
final class ShellWordParser {
  ShellWordParser({required this.depth, required this.limits});

  /// Глубина вложенности подстановок. Нужна, чтобы `$(...)` внутри `$(...)` не уходило в бесконечность.
  final int depth;
  final VirtualLimits limits;

  static final _nameStart = RegExp('[A-Za-z_]');
  static final _nameChar = RegExp('[A-Za-z0-9_]');
  static final _digit = RegExp('[0-9]');
  static final _paramName = RegExp(
    r'^([A-Za-z_][A-Za-z0-9_]*|[0-9]+|[?$!@*#-])$',
  );

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

  List<WordPart> _parts(
    String raw, {
    required bool dq,
    required bool heredoc,
    bool assignment = false,
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
        if (c == "'") {
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
        if (c == '~' && (i == 0 || (assignment && raw[i - 1] == ':'))) {
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
        final expansion = _expansion(raw, i);
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
  /// если `$` стоит как обычный символ (в конце слова или перед пробелом).
  (WordPart, int)? _expansion(String raw, int i) {
    final next = i + 1 < raw.length ? raw[i + 1] : '';
    if (next == '(') {
      final end = ShellScan.parenEnd(raw, i + 1);
      final inner = _slice(raw, i + 2, end - 1);
      if (inner.startsWith('(')) {
        // `$((...))`: внешние скобки относятся к синтаксису, внутри — выражение. Разбор выражения как
        // слова даёт `$VAR` и подстановки, которые раскрываются до вычисления.
        final expression = _slice(inner, 1, inner.length - 1);
        return (
          ArithmeticPart(
            ShellWord(_parts(expression, dq: true, heredoc: false)),
          ),
          end,
        );
      }
      final script = ShellParser.parseNested(inner, depth + 1, limits);
      return (CommandPart(script), end);
    }
    if (next == '{') {
      final end = ShellScan.braceEnd(raw, i + 1);
      final name = _slice(raw, i + 2, end - 1);
      if (!_paramName.hasMatch(name)) {
        throw ShellSyntaxException.unsupported('parameter expansion \${$name}');
      }
      return (ParamPart(name), end);
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

  static String _slice(String text, int start, int end) =>
      String.fromCharCodes(text.codeUnits, start, end);
}

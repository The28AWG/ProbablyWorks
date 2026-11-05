import 'package:virtual_host/src/shell/shell_errors.dart';

/// Границы конструкций shell: кавычки, `$(...)`, `${...}`. Используются и лексером (чтобы найти конец слова),
/// и разбором слов (чтобы найти конец подстановки). Один алгоритм на оба случая: слово не может закончиться
/// внутри кавычек или подстановки, и обе стороны это понимают одинаково.
///
/// Каждая функция принимает индекс открывающего символа и возвращает индекс сразу за закрывающим.
abstract final class ShellScan {
  const ShellScan._();

  /// Конец `'...'`. Внутри одинарных кавычек ничего не экранируется.
  static int singleQuoteEnd(String text, int open) {
    final close = text.indexOf("'", open + 1);
    if (close < 0) throw _eof("'");
    return close + 1;
  }

  /// Конец `"..."`. Внутри подстановки `$(...)` кавычки считаются отдельно, поэтому вложенность проходит.
  static int doubleQuoteEnd(String text, int open) {
    var i = open + 1;
    while (true) {
      if (i >= text.length) throw _eof('"');
      final c = text[i];
      if (c == '"') return i + 1;
      if (c == r'\') {
        i += 2;
      } else if (c == '`') {
        i = backquoteEnd(text, i);
      } else if (c == r'$' && _next(text, i) == '(') {
        i = parenEnd(text, i + 1);
      } else if (c == r'$' && _next(text, i) == '{') {
        i = braceEnd(text, i + 1);
      } else {
        i++;
      }
    }
  }

  /// Конец обратных кавычек `` `...` ``, открытых в [open]. Внутри `\` экранирует следующий символ, поэтому
  /// закрывающая кавычка — первая неэкранированная.
  static int backquoteEnd(String text, int open) {
    var i = open + 1;
    while (i < text.length) {
      final c = text[i];
      if (c == r'\') {
        i += 2;
      } else if (c == '`') {
        return i + 1;
      } else {
        i++;
      }
    }
    throw _eof('`');
  }

  /// Конец скобок `(...)`, начинающихся с [open]. Учитывает кавычки и вложенные скобки.
  static int parenEnd(String text, int open) {
    var depth = 0;
    var i = open;
    while (true) {
      if (i >= text.length) throw _eof(')');
      final c = text[i];
      if (c == r'\') {
        i += 2;
        continue;
      }
      if (c == "'") {
        i = singleQuoteEnd(text, i);
        continue;
      }
      if (c == '"') {
        i = doubleQuoteEnd(text, i);
        continue;
      }
      if (c == '`') {
        i = backquoteEnd(text, i);
        continue;
      }
      if (c == '(') {
        depth++;
      } else if (c == ')') {
        depth--;
        if (depth == 0) return i + 1;
      }
      i++;
    }
  }

  /// Конец `{...}` параметра, открытого `{` в [open]. Внутри учитываются кавычки, `\`, `$(...)`, обратные
  /// кавычки и вложенные `${...}`: `${x:-${y:-}}` закрывается последней `}`, а `${x:-'}'}` — не первой.
  /// Литеральная `{` без `$` в операнде не меняет вложенность, как в bash.
  static int braceEnd(String text, int open) {
    var i = open + 1;
    while (true) {
      if (i >= text.length) throw _eof('}');
      final c = text[i];
      if (c == '}') return i + 1;
      if (c == r'\') {
        i += 2;
      } else if (c == "'") {
        i = singleQuoteEnd(text, i);
      } else if (c == '"') {
        i = doubleQuoteEnd(text, i);
      } else if (c == '`') {
        i = backquoteEnd(text, i);
      } else if (c == r'$' && _next(text, i) == '(') {
        i = parenEnd(text, i + 1);
      } else if (c == r'$' && _next(text, i) == '{') {
        i = braceEnd(text, i + 1);
      } else {
        i++;
      }
    }
  }

  /// Индекс первого символа [stop], начиная с [from], который стоит вне кавычек, подстановок и `${}`.
  /// Возвращает -1, если такого нет. Нужно, чтобы найти `/` в образце замены или `:` в срезе, не путая
  /// их с разделителями внутри вложенных конструкций.
  static int indexOfTop(String text, String stop, int from) {
    var i = from;
    while (i < text.length) {
      final c = text[i];
      if (c == stop) return i;
      if (c == r'\') {
        i += 2;
      } else if (c == "'") {
        i = singleQuoteEnd(text, i);
      } else if (c == '"') {
        i = doubleQuoteEnd(text, i);
      } else if (c == '`') {
        i = backquoteEnd(text, i);
      } else if (c == r'$' && _next(text, i) == '(') {
        i = parenEnd(text, i + 1);
      } else if (c == r'$' && _next(text, i) == '{') {
        i = braceEnd(text, i + 1);
      } else {
        i++;
      }
    }
    return -1;
  }

  /// Символ после [i] или null, если это конец строки.
  static String? _next(String text, int i) =>
      i + 1 < text.length ? text[i + 1] : null;

  static ShellSyntaxException _eof(String closing) => ShellSyntaxException(
    "unexpected EOF while looking for matching `$closing'",
  );
}

/// Перевод регулярных выражений POSIX BRE (диалект GNU, как у `grep` без `-E`) в Dart [RegExp].
///
/// Модель пишет `grep 'a\|b'` и `grep 'x\{2\}'` так же, как на реальном Linux, поэтому синтаксис должен
/// совпадать с BRE, а не с Dart. Различия, которые здесь закрыты: скобки, `|`, `+`, `?` и `{` без обратного
/// слэша — обычные символы; `\(`, `\|`, `\{` — операторы; `*` в начале выражения — литерал; `^` и `$`
/// якоря только в позициях, где они работают в BRE; классы `[[:alpha:]]` раскрываются в диапазоны.
abstract final class PosixRegex {
  const PosixRegex._();

  /// Компилирует BRE в [RegExp]. Некорректное выражение даёт [FormatException] с текстом, близким к grep.
  static RegExp fromBre(String bre) => RegExp(_translate(bre));

  /// Исходный текст Dart-выражения для BRE. Нужен `grep`, который оборачивает шаблон для `-w` и `-x`,
  /// и сочетает несколько шаблонов через `|`. Ошибки те же, что у [fromBre].
  static String breSource(String bre) => _translate(bre);

  /// Компилирует POSIX ERE (как `[[ =~ ]]` и `grep -E`). Скобки, `|`, `+`, `?` и `{m,n}` — операторы
  /// без обратного слэша. Некорректное выражение даёт [FormatException].
  static RegExp fromEre(String ere) => RegExp(ereSource(ere));

  /// Исходный текст Dart-выражения для ERE. Ошибки те же, что у [fromEre].
  static String ereSource(String ere) => _translate(ere, ere: true);

  /// Классы POSIX, раскрытые в диапазоны Dart. Незнакомое имя класса — ошибка.
  static const _classes = {
    'alpha': 'a-zA-Z',
    'digit': '0-9',
    'alnum': 'a-zA-Z0-9',
    'upper': 'A-Z',
    'lower': 'a-z',
    'space': r' \t\n\r\x0b\x0c',
    'blank': r' \t',
    'punct': r'!-\/:-@\[-`{-~',
    'xdigit': '0-9A-Fa-f',
    'cntrl': r'\x00-\x1f\x7f',
    'print': r'\x20-\x7e',
    'graph': r'\x21-\x7e',
  };

  static String _translate(String source, {bool ere = false}) {
    final out = StringBuffer();
    // true там, где `*` литерал, а `^` — якорь: в начале, после группы или `|` и после самого `^`.
    var atStart = true;
    var i = 0;
    while (i < source.length) {
      final c = source[i];
      if (c == r'\') {
        if (i + 1 >= source.length) {
          throw const FormatException('Trailing backslash');
        }
        final next = source[i + 1];
        out.write(ere ? _ereEscaped(next) : _escaped(next));
        atStart = !ere && (next == '(' || next == '|');
        i += 2;
        continue;
      }
      if (ere) {
        final op = _ereOperator(source, i);
        if (op != null) {
          out.write(op.text);
          atStart = op.opens;
          i = op.next;
          continue;
        }
      }
      if (c == '[') {
        final (cls, after) = _bracket(source, i);
        out.write(cls);
        atStart = false;
        i = after;
        continue;
      }
      if (c == '^' && atStart) {
        out.write('^');
        i++;
        continue;
      }
      if (c == r'$') {
        out.write(_isAnchorEnd(source, i, ere: ere) ? r'$' : r'\$');
      } else if (c == '*' && atStart) {
        out.write(r'\*');
      } else if (c == '.' || c == '*') {
        out.write(c);
      } else {
        out.write(RegExp.escape(c));
      }
      atStart = false;
      i++;
    }
    return out.toString();
  }

  /// Оператор ERE без обратного слэша. `{` без корректного интервала — литерал, его возвращает null.
  static ({String text, int next, bool opens})? _ereOperator(
    String source,
    int i,
  ) {
    final c = source[i];
    if (c == '(' || c == '|') {
      return (text: c, next: i + 1, opens: true);
    }
    if (c == ')' || c == '+' || c == '?') {
      return (text: c, next: i + 1, opens: false);
    }
    if (c != '{') return null;
    final interval = _interval(source, i);
    if (interval == null) return null;
    return (text: interval.$1, next: interval.$2, opens: false);
  }

  /// `{m}`, `{m,}` или `{m,n}` с `n >= m`. Иначе `{` — обычный символ, как в bash.
  static (String, int)? _interval(String source, int i) {
    final match = RegExp(r'^\{([0-9]+)(,([0-9]+)?)?\}')
        .matchAsPrefix(source, i);
    if (match == null) return null;
    final from = int.parse(match.group(1)!);
    final to = match.group(3);
    if (to != null && int.parse(to) < from) return null;
    final text = match.group(0)!;
    return (text, i + text.length);
  }

  /// Экранированный символ ERE: операторы со слэшем — литералы, `\1` — обратная ссылка.
  static String _ereEscaped(String next) => switch (next) {
    '(' ||
    ')' ||
    '{' ||
    '}' ||
    '|' ||
    '+' ||
    '?' ||
    '.' ||
    '*' ||
    '[' ||
    ']' ||
    '^' ||
    r'$' ||
    r'\' => '\\$next',
    '1' || '2' || '3' || '4' || '5' || '6' || '7' || '8' || '9' => '\\$next',
    _ => RegExp.escape(next),
  };

  /// Экранированный в BRE символ. `\(`, `\)`, `\{`, `\}`, `\|`, `\+`, `\?` — операторы, у них в Dart
  /// тот же смысл без обратного слэша.
  static String _escaped(String next) => switch (next) {
    '(' || ')' || '{' || '}' || '|' || '+' || '?' => next,
    '<' || '>' => r'\b',
    'w' || 'W' || 's' || 'S' || 'b' || 'B' => '\\$next',
    '1' || '2' || '3' || '4' || '5' || '6' || '7' || '8' || '9' => '\\$next',
    '.' || '*' || '[' || ']' || '^' || r'$' || r'\' => '\\$next',
    _ => RegExp.escape(next),
  };

  /// `$` — якорь только в конце выражения или перед закрывающей группой и `|`. В BRE эти операторы
  /// записаны со слэшем. В остальных местах это литерал.
  static bool _isAnchorEnd(String source, int i, {required bool ere}) {
    if (i == source.length - 1) return true;
    if (ere) {
      final next = source[i + 1];
      return next == ')' || next == '|';
    }
    return source.startsWith(r'\)', i + 1) || source.startsWith(r'\|', i + 1);
  }

  /// Разбирает выражение в скобках, начинающееся с `[` в позиции [start]. Возвращает Dart-класс и позицию
  /// после закрывающей `]`. Внутри класса обратный слэш — литерал, поэтому он экранируется.
  static (String, int) _bracket(String bre, int start) {
    final out = StringBuffer('[');
    var j = start + 1;
    if (j < bre.length && bre[j] == '^') {
      out.write('^');
      j++;
    }
    var first = true;
    while (true) {
      if (j >= bre.length) {
        throw const FormatException('Unmatched [, [^, [:, [., or [=');
      }
      final ch = bre[j];
      if (ch == ']' && !first) break;
      if (ch == '[' && j + 1 < bre.length && bre[j + 1] == ':') {
        final name = StringBuffer();
        var k = j + 2;
        while (!bre.startsWith(':]', k)) {
          if (k >= bre.length) {
            throw const FormatException('Unmatched [, [^, [:, [., or [=');
          }
          name.write(bre[k]);
          k++;
        }
        final cls = _classes[name.toString()];
        if (cls == null) {
          throw const FormatException('Invalid character class name');
        }
        out.write(cls);
        j = k + 2;
        first = false;
        continue;
      }
      out.write(ch == r'\' || ch == '[' || ch == ']' ? '\\$ch' : ch);
      first = false;
      j++;
    }
    out.write(']');
    return (out.toString(), j + 1);
  }
}

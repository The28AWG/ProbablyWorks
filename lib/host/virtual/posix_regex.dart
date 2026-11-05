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

  static String _translate(String bre) {
    final out = StringBuffer();
    // true там, где `*` литерал, а `^` — якорь: в начале, после `\(`, `\|` и после самого `^`.
    var atStart = true;
    var i = 0;
    while (i < bre.length) {
      final c = bre[i];
      if (c == r'\') {
        if (i + 1 >= bre.length) {
          throw const FormatException('Trailing backslash');
        }
        final next = bre[i + 1];
        out.write(_escaped(next));
        atStart = next == '(' || next == '|';
        i += 2;
        continue;
      }
      if (c == '[') {
        final (cls, after) = _bracket(bre, i);
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
        out.write(_isAnchorEnd(bre, i) ? r'$' : r'\$');
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

  /// `$` — якорь только в конце выражения или перед `\)` и `\|`. В остальных местах это литерал.
  static bool _isAnchorEnd(String bre, int i) {
    if (i == bre.length - 1) return true;
    return bre.startsWith(r'\)', i + 1) || bre.startsWith(r'\|', i + 1);
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

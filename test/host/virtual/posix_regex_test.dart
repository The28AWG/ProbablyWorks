import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/host/virtual/posix_regex.dart';

/// Перевод BRE проверяется на любой платформе: здесь нет зависимости от утилит ОС.
void main() {
  bool matches(String bre, String text) =>
      PosixRegex.fromBre(bre).hasMatch(text);

  test('скобки, |, + и ? в BRE — обычные символы', () {
    expect(matches('a+b', 'a+b'), isTrue);
    expect(matches('a+b', 'aab'), isFalse);
    expect(matches('(x)', '(x)'), isTrue);
    expect(matches('a|b', 'a|b'), isTrue);
    expect(matches('a|b', 'a'), isFalse);
  });

  test('\\| и \\( \\) — операторы GNU', () {
    expect(matches(r'foo\|bar', 'bar'), isTrue);
    expect(matches(r'\(ab\)\{2\}', 'abab'), isTrue);
    expect(matches(r'\(ab\)\{2\}', 'ab'), isFalse);
  });

  test('звёздочка в начале выражения — литерал', () {
    expect(matches('*a', '*a'), isTrue);
    expect(matches('*a', 'a'), isFalse);
    expect(matches('a*', 'aaa'), isTrue);
  });

  test('якоря ^ и конец выражения работают только в позициях BRE', () {
    expect(matches('^b', 'baz'), isTrue);
    expect(matches('^b', 'abz'), isFalse);
    expect(matches(r'a$', 'ba'), isTrue);
    expect(matches(r'a$b', 'a\$b'), isTrue);
  });

  test('классы POSIX раскрываются в диапазоны', () {
    expect(matches('[[:digit:]]', 'x7'), isTrue);
    expect(matches('[[:digit:]]', 'xy'), isFalse);
    expect(matches('[[:alpha:]]', '1a'), isTrue);
  });

  test('обратный слэш внутри скобок — литерал', () {
    expect(matches(r'[\]', r'\'), isTrue);
  });

  test('ошибки разметки — FormatException', () {
    expect(() => PosixRegex.fromBre('[abc'), throwsFormatException);
    expect(() => PosixRegex.fromBre(r'abc\'), throwsFormatException);
    expect(() => PosixRegex.fromBre('[[:nope:]]'), throwsFormatException);
  });
}

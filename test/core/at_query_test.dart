import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/util/at_query.dart';

void main() {
  test('tokens start at the beginning or after a space', () {
    expect(AtQuery.isTokenStart('@free', 0), isTrue);
    expect(AtQuery.isTokenStart('foo @free', 4), isTrue);
    expect(AtQuery.isTokenStart('user@mail', 4), isFalse);
  });

  test('tokenEnd respects quotes and escapes', () {
    expect(AtQuery.tokenEnd('@free gpt', 0), 5);
    expect(AtQuery.tokenEnd('@project:"two words" text', 0), 20);
    expect(AtQuery.tokenEnd(r'@project:"two \" words" text', 0), 23);
  });

  test('a token is split into name and unquoted value', () {
    final token = AtQuery.tokens('@provider:"llama.cpp" gpt').single;
    expect(token.name, 'provider');
    expect(token.value, 'llama.cpp');
    expect(token.hasValue, isTrue);
    expect(token.start, 0);
    expect(token.end, 21);

    final flag = AtQuery.tokens('@Free').single;
    expect(flag.name, 'free');
    expect(flag.value, isEmpty);
    expect(flag.hasValue, isFalse);
  });

  test('an unclosed quote keeps the value as typed', () {
    final token = AtQuery.tokens('@provider:"ll').single;
    expect(token.value, '"ll');
  });

  test('escaped quotes are unescaped', () {
    final token = AtQuery.tokens(r'@project:"two \" words"').single;
    expect(token.value, 'two " words');
  });

  test('tokens are returned in order', () {
    final tokens = AtQuery.tokens('gpt @free @provider:openai');
    expect([for (final token in tokens) token.name], ['free', 'provider']);
  });

  test('textOf slices by UTF-16 offsets', () {
    expect(AtQuery.textOf('@provider:ab', 1, 9), 'provider');
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/util/search_text.dart';

void main() {
  test('normalization lowercases, replaces ё and removes punctuation', () {
    expect(normalizeSearchText('  GPT-4o  '), 'gpt 4o');
    expect(normalizeSearchText('Ёлка / дерево'), 'елка дерево');
    expect(normalizeSearchText('a_b.c'), 'a b c');
  });

  test('an exact match scores highest', () {
    expect(scoreSearchText('GPT-4o', 'gpt 4o'), 1);
  });

  test('a prefix of the field or a word scores high', () {
    expect(scoreSearchText('Gemini Free', 'gem'), 0.95);
    expect(scoreSearchText('Gemini Free', 'fre'), 0.9);
  });

  test('a substring scores lower than a prefix', () {
    expect(scoreSearchText('Llama 3 8B', '3 8'), 0.8);
  });

  test('a short term without a match is not fuzzy', () {
    expect(scoreSearchText('Llama', 'lm'), 0);
  });

  test('a typo is tolerated for a long enough term', () {
    expect(scoreSearchText('Anthropic', 'anthropik'), greaterThan(0));
    expect(scoreSearchText('gpt 4o', 'gpt4'), greaterThan(0));
  });
}

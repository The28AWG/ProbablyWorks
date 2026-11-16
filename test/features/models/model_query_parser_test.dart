import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/features/models/domain/model_query_parser.dart';

const _providers = ['llama.cpp', 'llamadart', 'openai'];

void main() {
  test('keeps the free text and removes @free', () {
    final parse = ModelQueryParser.parse('@free gpt-4o');

    expect(parse.query.search, 'gpt-4o');
    expect(parse.query.freeOnly, isTrue);
    expect(parse.providerProblem, isNull);
  });

  test('supports Russian aliases', () {
    final parse = ModelQueryParser.parse(
      '@бесплатные @провайдер:openai',
      providers: _providers,
    );

    expect(parse.query.freeOnly, isTrue);
    expect(parse.query.provider, 'openai');
    expect(parse.query.search, isEmpty);
  });

  test('@tools hides models without tool calling', () {
    final parse = ModelQueryParser.parse('@tools gpt');
    expect(parse.query.toolsOnly, isTrue);
    expect(parse.query.search, 'gpt');
  });

  test('a unique provider prefix is applied', () {
    final parse = ModelQueryParser.parse(
      '@provider:open',
      providers: _providers,
    );
    expect(parse.query.provider, 'openai');
    expect(parse.providerProblem, isNull);
  });

  test('a quoted provider is matched exactly', () {
    final parse = ModelQueryParser.parse(
      '@provider:"llama.cpp" модел',
      providers: _providers,
    );
    expect(parse.query.provider, 'llama.cpp');
    expect(parse.query.search, 'модел');
  });

  test('an ambiguous prefix is reported and not applied', () {
    final parse = ModelQueryParser.parse(
      '@provider:llama gpt',
      providers: _providers,
    );

    expect(parse.query.provider, isEmpty);
    expect(parse.query.search, 'gpt');
    final problem = parse.providerProblem;
    expect(problem?.kind, ModelProviderProblemKind.ambiguous);
    expect(problem?.value, 'llama');
    expect(problem?.candidates, ['llama.cpp', 'llamadart']);
  });

  test('an unknown provider is reported and not applied', () {
    final parse = ModelQueryParser.parse(
      '@provider:nope gpt',
      providers: _providers,
    );
    expect(parse.query.provider, isEmpty);
    expect(parse.query.search, 'gpt');
    expect(parse.providerProblem?.kind, ModelProviderProblemKind.unknown);
  });

  test('the last provider filter wins', () {
    final parse = ModelQueryParser.parse(
      '@provider:openai @provider:llama.cpp',
      providers: _providers,
    );
    expect(parse.query.provider, 'llama.cpp');
    expect(parse.providerProblem, isNull);
  });

  test('an unknown filter stays plain text', () {
    final parse = ModelQueryParser.parse('@unknown gpt');
    expect(parse.query.search, '@unknown gpt');
    expect(parse.query.freeOnly, isFalse);
  });

  test('a filter with a value stays plain text', () {
    final parse = ModelQueryParser.parse('@free:yes gpt');
    expect(parse.query.search, '@free:yes gpt');
    expect(parse.query.freeOnly, isFalse);
  });

  test('an empty provider filter stays plain text', () {
    final parse = ModelQueryParser.parse('@provider: gpt');
    expect(parse.query.search, '@provider: gpt');
    expect(parse.query.provider, isEmpty);
  });

  test('an @ inside a word is not a filter', () {
    final parse = ModelQueryParser.parse('user@mail @free');
    expect(parse.query.search, 'user@mail');
    expect(parse.query.freeOnly, isTrue);
  });
}

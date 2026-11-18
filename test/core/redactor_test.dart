import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/core/util/redactor.dart';

void main() {
  setUp(Redactor.clearRegisteredSecrets);
  tearDown(Redactor.clearRegisteredSecrets);

  test('masks authorization schemes without leaking credentials', () {
    final cases = {
      'Authorization: Basic dXNlcjpwYXNz': 'Basic ***',
      'Proxy-Authorization: Token abcdefghijkl': 'Token ***',
      'Authorization: Bearer abcdefghijkl': 'Bearer ***',
    };
    for (final entry in cases.entries) {
      final redacted = Redactor.redact(entry.key);
      expect(redacted, contains(entry.value));
      expect(redacted, isNot(contains('abcdefghijkl')));
      expect(redacted, isNot(contains('dXNlcjpwYXNz')));
    }
  });

  test('masks digest parameters', () {
    final redacted = Redactor.redact(
      'Authorization: Digest username="user", response="abc123"',
    );
    expect(redacted, contains('Authorization: Digest ***'));
    expect(redacted, isNot(contains('response')));
  });

  test('masks provider variables and Hugging Face tokens', () {
    const text =
        'PROBABLY_WORKS_LLAMACPP_KEY=supersecret123\n'
        'LLAMACPP_KEY=anothersecret\n'
        'HF_TOKEN=hf_abcdefghijklmnopqrstuvwxyz1234567890\n'
        'bare hf_abcdefghijklmnopqrstuvwxyz1234567890 value';
    final redacted = Redactor.redact(text);
    expect(redacted, isNot(contains('supersecret123')));
    expect(redacted, isNot(contains('anothersecret')));
    expect(
      redacted,
      isNot(contains('hf_abcdefghijklmnopqrstuvwxyz1234567890')),
    );
    expect(redacted, contains('hf_***'));
  });

  test('does not mistake ordinary words for secret assignments', () {
    expect(Redactor.redact('monkey=banana'), 'monkey=banana');
    expect(Redactor.redact('keyboard layout'), 'keyboard layout');
  });

  test('masks registered values of arbitrary format', () {
    Redactor.registerSecret('q7Yp2Lm9RandomToken');
    final redacted = Redactor.redact('the value is q7Yp2Lm9RandomToken here');
    expect(redacted, 'the value is *** here');
  });

  test('masks longer registered values before shorter ones', () {
    Redactor.registerSecret('short-secret');
    Redactor.registerSecret('short-secret-with-suffix');
    final redacted = Redactor.redact('short-secret-with-suffix');
    expect(redacted, '***');
  });

  test('does not register too short values', () {
    Redactor.registerSecret('abc');
    expect(Redactor.redact('abc'), 'abc');
  });

  test('keeps ordinary text', () {
    expect(Redactor.redact('ls -la /tmp'), 'ls -la /tmp');
  });
}

import 'dart:io';

import 'package:pw_agent/core/security/file_secret_store.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/core/util/redactor.dart';
import 'package:test/test.dart';

/// Проверяет, что SecretStore передаёт значения в Redactor.
void main() {
  setUp(Redactor.clearRegisteredSecrets);
  tearDown(Redactor.clearRegisteredSecrets);

  test('memory store registers values written and read', () async {
    final store = MemorySecretStore();
    const secret = 'q7Yp2Lm9RandomToken';

    await store.write('provider.custom.apiKey', secret);
    expect(Redactor.redact('before $secret after'), 'before *** after');

    Redactor.clearRegisteredSecrets();
    expect(await store.read('provider.custom.apiKey'), secret);
    expect(Redactor.redact('x $secret y'), isNot(contains(secret)));
  });

  test('file store registers values written and loaded from disk', () async {
    final dir = Directory.systemTemp.createTempSync('pw_redactor_');
    addTearDown(() => dir.deleteSync(recursive: true));
    const secret = 'file-secret-value-123';

    final store = FileSecretStore(dir);
    await store.write('provider.custom.apiKey', secret);
    expect(Redactor.redact('before $secret after'), 'before *** after');

    Redactor.clearRegisteredSecrets();
    final reloaded = FileSecretStore(dir);
    expect(await reloaded.read('provider.custom.apiKey'), secret);
    expect(Redactor.redact('x $secret y'), isNot(contains(secret)));
  });
}

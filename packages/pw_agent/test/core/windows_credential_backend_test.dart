@TestOn('windows')
library;

import 'package:pw_agent/core/security/windows_credential_backend.dart';
import 'package:test/test.dart';

void main() {
  test('writes, reads and deletes a Credential Manager entry', () async {
    final backend = WindowsCredentialBackend();
    final key = 'test.${DateTime.now().microsecondsSinceEpoch}';
    addTearDown(() => backend.delete(key));

    await backend.write(key, 'secret-value');

    expect(await backend.read(key), 'secret-value');

    await backend.delete(key);

    expect(await backend.read(key), isNull);
  });
}

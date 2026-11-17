import 'dart:io';

import 'package:pw_agent/core/security/file_secret_store.dart';
import 'package:test/test.dart';

/// Проверяет файловый fallback: конкурентные записи не должны терять ключи.
void main() {
  late Directory support;
  late FileSecretStore store;

  setUp(() {
    support = Directory.systemTemp.createTempSync('pw_file_secrets_');
    store = FileSecretStore(support);
    addTearDown(() => support.deleteSync(recursive: true));
  });

  test('concurrent writes keep both secrets', () async {
    await Future.wait([
      store.write('first', 'one'),
      store.write('second', 'two'),
    ]);

    final reloaded = FileSecretStore(support);
    expect(await reloaded.read('first'), 'one');
    expect(await reloaded.read('second'), 'two');
  });

  test('a write after a failed one still reaches the file', () async {
    final blocker = File('${support.path}/not-a-directory')
      ..writeAsStringSync('block');
    final broken = FileSecretStore(Directory('${blocker.path}/nested'));

    await expectLater(broken.write('lost', 'value'), throwsA(anything));
    await store.write('kept', 'value');

    final reloaded = FileSecretStore(support);
    expect(await reloaded.read('lost'), isNull);
    expect(await reloaded.read('kept'), 'value');
  });

  test('concurrent writes and deletes keep a consistent file', () async {
    await store.write('prefix', 'kept');

    await Future.wait([
      store.write('first', 'one'),
      store.write('second', 'two'),
      store.delete('prefix'),
    ]);

    final reloaded = FileSecretStore(support);
    expect(await reloaded.read('prefix'), isNull);
    expect(await reloaded.read('first'), 'one');
    expect(await reloaded.read('second'), 'two');
  });
}

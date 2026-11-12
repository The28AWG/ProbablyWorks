import 'package:pw_agent/core/security/file_secret_store.dart';
import 'package:pw_agent/core/security/keyring_backend.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/core/security/system_secret_store.dart';
import 'package:test/test.dart';

void main() {
  test('writes secrets to the keyring and removes the file copy', () async {
    final fallback = MemorySecretStore();
    final backend = _FakeKeyring();
    final store = SystemSecretStore(fallback: fallback, backend: backend);

    await store.write('openrouter.apiKey', 'secret');

    expect(backend.values['openrouter.apiKey'], 'secret');
    expect(await fallback.read('openrouter.apiKey'), isNull);
    expect(store.kind, SecretStoreKind.osKeychain);
  });

  test('migrates a legacy file secret into the keyring', () async {
    final fallback = MemorySecretStore()
      ..values['openrouter.apiKey'] = 'legacy';
    final backend = _FakeKeyring();
    final store = SystemSecretStore(fallback: fallback, backend: backend);

    expect(await store.read('openrouter.apiKey'), 'legacy');
    expect(backend.values['openrouter.apiKey'], 'legacy');
    expect(fallback.values['openrouter.apiKey'], isNull);
  });

  test('can read a legacy value without migrating it', () async {
    final fallback = MemorySecretStore()..values['key'] = 'legacy';
    final backend = _FakeKeyring();
    final store = SystemSecretStore(
      fallback: fallback,
      backend: backend,
      migrate: false,
    );

    expect(await store.read('key'), 'legacy');
    expect(backend.values, isEmpty);
    expect(fallback.values['key'], 'legacy');
  });

  test('falls back to the fallback store when the keyring throws', () async {
    final fallback = MemorySecretStore()..values['openrouter.apiKey'] = 'file';
    final backend = _FakeKeyring(fail: true);
    final store = SystemSecretStore(fallback: fallback, backend: backend);

    expect(await store.read('openrouter.apiKey'), 'file');
    expect(store.kind, SecretStoreKind.memory);

    await store.write('openrouter.apiKey', 'updated');
    expect(fallback.values['openrouter.apiKey'], 'updated');
    expect(backend.values, isEmpty);
  });

  test('deletes from both the keyring and the file', () async {
    final fallback = MemorySecretStore()..values['key'] = 'file';
    final backend = _FakeKeyring()..values['key'] = 'keyring';
    final store = SystemSecretStore(fallback: fallback, backend: backend);

    await store.delete('key');

    expect(backend.values, isEmpty);
    expect(fallback.values, isEmpty);
  });

  test('environment override wins over the keyring', () async {
    final backend = _FakeKeyring()..values[openRouterKeyName] = 'keyring';
    final store = SystemSecretStore(
      fallback: MemorySecretStore(),
      backend: backend,
      environment: const {FileSecretStore.openRouterEnvironment: 'environment'},
    );

    expect(await store.read(openRouterKeyName), 'environment');
  });
}

final class _FakeKeyring implements KeyringBackend {
  _FakeKeyring({this.fail = false});

  final bool fail;
  final Map<String, String> values = {};

  void _check() {
    if (fail) throw StateError('keyring unavailable');
  }

  @override
  String get name => 'fake';

  @override
  Future<String?> read(String key) async {
    _check();
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    _check();
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _check();
    values.remove(key);
  }
}

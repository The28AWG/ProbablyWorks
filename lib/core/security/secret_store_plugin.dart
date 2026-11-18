import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:injectable/injectable.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/core/util/redactor.dart';

/// `SecretStore` поверх хранилища ОС (libsecret, Keychain, DPAPI).
@LazySingleton(as: SecretStore)
class FlutterSecretStore implements SecretStore {
  FlutterSecretStore(this._storage);

  final FlutterSecureStorage _storage;

  @override
  SecretStoreKind get kind => SecretStoreKind.osKeychain;

  @override
  Future<String?> read(String key) async {
    final value = await _storage.read(key: key);
    Redactor.registerSecret(value);
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    Redactor.registerSecret(value);
    await _storage.write(key: key, value: value);
  }

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

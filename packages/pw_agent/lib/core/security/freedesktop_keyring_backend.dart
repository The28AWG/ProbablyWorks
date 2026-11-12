import 'package:freedesktop_secret/freedesktop_secret.dart';
import 'package:pw_agent/core/security/keyring_backend.dart';

/// Linux backend через Freedesktop Secret Service.
///
/// Работает с GNOME Keyring, KWallet и другими совместимыми сервисами.
/// Требует доступ к пользовательской D-Bus-сессии; в headless-окружении
/// [SystemSecretStore] откатится на файл.
final class FreedesktopKeyringBackend implements KeyringBackend {
  FreedesktopKeyringBackend({SecretServiceClient? client})
    : _client = client ?? SecretServiceClient();

  static const _schema = 'com.the28awg.probably_works';

  final SecretServiceClient _client;
  Future<void>? _initialized;

  @override
  String get name => 'Freedesktop Secret Service';

  Future<void> _ensureInitialized() => _initialized ??= _client.initialize();

  Map<String, String> _attributes(String key) => {
    'xdg:schema': _schema,
    'key': key,
  };

  @override
  Future<String?> read(String key) async {
    await _ensureInitialized();
    final item = await _client.lookupSecret(
      attributes: _attributes(key),
      duplicateStrategy: LookupSecretDuplicateStrategy.newestCreated,
    );
    return item?.secretAsText();
  }

  @override
  Future<void> write(String key, String value) async {
    await _ensureInitialized();
    await _client.storeSecretText(
      attributes: _attributes(key),
      secret: value,
      label: 'ProbablyWorks: $key',
      replace: true,
    );
  }

  @override
  Future<void> delete(String key) async {
    await _ensureInitialized();
    await _client.deleteSecret(
      attributes: _attributes(key),
      duplicateStrategy: DeleteSecretDuplicateStrategy.deleteAll,
    );
  }
}

import 'dart:io';

import 'package:pw_agent/core/logging/app_log.dart';
import 'package:pw_agent/core/security/file_secret_store.dart';
import 'package:pw_agent/core/security/freedesktop_keyring_backend.dart';
import 'package:pw_agent/core/security/keyring_backend.dart';
import 'package:pw_agent/core/security/macos_keyring_backend.dart';
import 'package:pw_agent/core/security/secret_store.dart';

/// Секреты в системном keyring с файловым fallback.
///
/// Записи, оставшиеся в старом `secrets.json`, переносятся в keyring при
/// первом чтении. Если keyring недоступен (headless, нет D-Bus-сессии,
/// пользователь отклонил разблокировку), прозрачно используется файл `0600`.
final class SystemSecretStore implements SecretStore {
  SystemSecretStore({
    required this.fallback,
    required this.backend,
    this.environment = const {},
    this.migrate = true,
  });

  final SecretStore fallback;
  final KeyringBackend backend;
  final Map<String, String> environment;

  /// Переносить ли старые значения из файла в keyring при чтении.
  final bool migrate;
  bool _usingKeyring = true;

  static const _keyringTimeout = Duration(seconds: 5);

  @override
  SecretStoreKind get kind =>
      _usingKeyring ? SecretStoreKind.osKeychain : fallback.kind;

  @override
  Future<String?> read(String key) async {
    final fromEnvironment = secretFromEnvironment(key, environment);
    if (fromEnvironment != null) return fromEnvironment;
    if (!_usingKeyring) return fallback.read(key);

    try {
      final value = await backend.read(key).timeout(_keyringTimeout);
      if (value != null && value.isNotEmpty) return value;
      return await _migrateFromFallback(key);
    } on Object catch (error) {
      _disableKeyring('read', error);
      return fallback.read(key);
    }
  }

  @override
  Future<void> write(String key, String value) async {
    if (!_usingKeyring) {
      await fallback.write(key, value);
      return;
    }
    try {
      await backend.write(key, value).timeout(_keyringTimeout);
      await fallback.delete(key);
    } on Object catch (error) {
      _disableKeyring('write', error);
      await fallback.write(key, value);
    }
  }

  @override
  Future<void> delete(String key) async {
    if (_usingKeyring) {
      try {
        await backend.delete(key).timeout(_keyringTimeout);
      } on Object catch (error) {
        _disableKeyring('delete', error);
      }
    }
    await fallback.delete(key);
  }

  Future<String?> _migrateFromFallback(String key) async {
    final legacy = await fallback.read(key);
    if (legacy == null) return null;
    if (!migrate) return legacy;
    try {
      await backend.write(key, legacy).timeout(_keyringTimeout);
      await fallback.delete(key);
      AppLog.root.info('migrated secret $key to ${backend.name}');
      return legacy;
    } on Object catch (error) {
      _disableKeyring('migration', error);
      return legacy;
    }
  }

  void _disableKeyring(String operation, Object error) {
    _usingKeyring = false;
    AppLog.root.warning(
      'OS keyring $operation failed, using file fallback',
      error,
    );
  }
}

/// Переменная для детерминированного отключения keyring в тестах и headless.
const noKeyringEnvironment = 'PROBABLY_WORKS_NO_KEYRING';

/// Создаёт keyring-store для текущей ОС или файловый fallback.
///
/// На Windows пока возвращается файловый store; Credential Manager будет
/// отдельным шагом вместе с подписью установщика.
SecretStore createSystemSecretStore({
  required Directory support,
  Map<String, String>? environment,
  KeyringBackend? keyring,
  bool migrate = true,
}) {
  final env = environment ?? Platform.environment;
  final fallback = FileSecretStore(support, environment: env);
  if (env[noKeyringEnvironment] == '1') return fallback;
  final backend = keyring ?? _defaultKeyringBackend();
  if (backend == null) return fallback;
  return SystemSecretStore(
    fallback: fallback,
    backend: backend,
    environment: env,
    migrate: migrate,
  );
}

KeyringBackend? _defaultKeyringBackend() {
  if (Platform.isLinux) return FreedesktopKeyringBackend();
  if (Platform.isMacOS) return MacOsKeyringBackend();
  return null;
}

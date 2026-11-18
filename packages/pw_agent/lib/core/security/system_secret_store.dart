import 'dart:io';

import 'package:pw_agent/core/logging/app_log.dart';
import 'package:pw_agent/core/security/file_secret_store.dart';
import 'package:pw_agent/core/security/freedesktop_keyring_backend.dart';
import 'package:pw_agent/core/security/keyring_backend.dart';
import 'package:pw_agent/core/security/macos_keyring_backend.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/core/security/windows_credential_backend.dart';
import 'package:pw_agent/core/util/redactor.dart';

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
    this.keyringRetryDelay = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final SecretStore fallback;
  final KeyringBackend backend;
  final Map<String, String> environment;

  /// Переносить ли старые значения из файла в keyring при чтении.
  final bool migrate;

  /// Через сколько снова пробовать keyring после сбоя.
  ///
  /// Ноль допустим для тестов: следующая же операция повторит keyring.
  final Duration keyringRetryDelay;
  final DateTime Function() _now;

  DateTime? _keyringDownUntil;

  static const _keyringTimeout = Duration(seconds: 5);

  /// Пока keyring временно недоступен, честно показываем fallback.
  bool get _usingKeyring {
    final until = _keyringDownUntil;
    return until == null || !_now().isBefore(until);
  }

  @override
  SecretStoreKind get kind =>
      _usingKeyring ? SecretStoreKind.osKeychain : fallback.kind;

  @override
  Future<String?> read(String key) async {
    final fromEnvironment = secretFromEnvironment(key, environment);
    if (fromEnvironment != null) {
      Redactor.registerSecret(fromEnvironment);
      return fromEnvironment;
    }
    if (!_usingKeyring) {
      final value = await fallback.read(key);
      Redactor.registerSecret(value);
      return value;
    }

    try {
      final value = await backend.read(key).timeout(_keyringTimeout);
      _markKeyringOk();
      if (value != null && value.isNotEmpty) {
        Redactor.registerSecret(value);
        return value;
      }
      return await _migrateFromFallback(key);
    } on Object catch (error) {
      _markKeyringFailure('read', error);
      final value = await fallback.read(key);
      Redactor.registerSecret(value);
      return value;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    Redactor.registerSecret(value);
    if (!_usingKeyring) {
      await fallback.write(key, value);
      return;
    }
    try {
      await backend.write(key, value).timeout(_keyringTimeout);
    } on Object catch (error) {
      _markKeyringFailure('write', error);
      await fallback.write(key, value);
      return;
    }
    _markKeyringOk();
    await fallback.delete(key);
  }

  @override
  Future<void> delete(String key) async {
    if (_usingKeyring) {
      try {
        await backend.delete(key).timeout(_keyringTimeout);
        _markKeyringOk();
      } on Object catch (error) {
        _markKeyringFailure('delete', error);
      }
    }
    await fallback.delete(key);
  }

  Future<String?> _migrateFromFallback(String key) async {
    final legacy = await fallback.read(key);
    Redactor.registerSecret(legacy);
    if (legacy == null) return null;
    if (!migrate) return legacy;
    try {
      await backend.write(key, legacy).timeout(_keyringTimeout);
    } on Object catch (error) {
      _markKeyringFailure('migration', error);
      return legacy;
    }
    _markKeyringOk();
    await fallback.delete(key);
    AppLog.root.info('migrated secret $key to ${backend.name}');
    return legacy;
  }

  /// Запоминает временную недоступность keyring и предупреждает один раз
  /// за период сбоя. Следующая операция после паузы снова пробует keyring.
  void _markKeyringFailure(String operation, Object error) {
    final wasDown = !_usingKeyring;
    _keyringDownUntil = _now().add(keyringRetryDelay);
    if (wasDown) return;
    AppLog.root.warning(
      'OS keyring $operation failed, using file fallback '
      'for ${keyringRetryDelay.inSeconds}s',
      error,
    );
  }

  void _markKeyringOk() {
    if (_keyringDownUntil == null) return;
    _keyringDownUntil = null;
    AppLog.root.info('OS keyring is available again');
  }
}

/// Переменная для детерминированного отключения keyring в тестах и headless.
const noKeyringEnvironment = 'PROBABLY_WORKS_NO_KEYRING';

/// Создаёт keyring-store для текущей ОС или файловый fallback.
///
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
  if (Platform.isWindows) return WindowsCredentialBackend();
  return null;
}

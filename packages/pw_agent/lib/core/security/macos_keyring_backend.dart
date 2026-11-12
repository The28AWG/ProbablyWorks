import 'dart:io';

import 'package:pw_agent/core/security/keyring_backend.dart';

/// macOS backend через встроенную утилиту `security`.
///
/// `security` есть в базовой поставке macOS. Значение передаётся аргументом
/// `-w`; это видно процессам того же пользователя, но не другим пользователям
/// и не попадает в файлы.
final class MacOsKeyringBackend implements KeyringBackend {
  static const _service = 'com.the28awg.probably_works';

  @override
  String get name => 'macOS Keychain';

  @override
  Future<String?> read(String key) async {
    final result = await Process.run('security', [
      'find-generic-password',
      '-s',
      _service,
      '-a',
      key,
      '-w',
    ]);
    if (result.exitCode != 0) return null;
    return (result.stdout as String).trim();
  }

  @override
  Future<void> write(String key, String value) async {
    final result = await Process.run('security', [
      'add-generic-password',
      '-U',
      '-s',
      _service,
      '-a',
      key,
      '-w',
      value,
    ]);
    if (result.exitCode != 0) {
      throw StateError(
        'security add-generic-password failed: ${result.stderr}',
      );
    }
  }

  @override
  Future<void> delete(String key) async {
    // Отсутствующая запись — не ошибка.
    await Process.run('security', [
      'delete-generic-password',
      '-s',
      _service,
      '-a',
      key,
    ]);
  }
}

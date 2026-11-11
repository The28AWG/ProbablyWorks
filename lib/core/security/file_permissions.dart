import 'dart:io';

/// Права на файлы приложения.
///
/// Dart не умеет задавать POSIX-режим в момент создания файла: `FileMode`
/// описывает только чтение/запись. Поэтому файл создаётся обычным способом,
/// а затем ему выставляется режим через системный `chmod`.
abstract final class FilePermissions {
  const FilePermissions._();

  static void file(File file) => _set(file.path, '600');

  static void directory(Directory dir) => _set(dir.path, '700');

  static void _set(String path, String mode) {
    if (Platform.isWindows) return;
    try {
      Process.runSync('chmod', [mode, path]);
    } on Object {
      // Права — дополнительная защита. Если chmod недоступен, приложение
      // продолжает работать: каталог данных всё равно закрыт для других.
    }
  }
}

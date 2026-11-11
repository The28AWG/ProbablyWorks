import 'dart:io';

/// Права на файлы приложения.
///
/// Dart не умеет задавать права в момент создания: `FileMode` описывает только
/// чтение/запись. Поэтому после создания вызывается системная утилита:
/// `chmod` на POSIX и `icacls` на Windows. На macOS дополнительно снимаются
/// унаследованные ACL: `chmod` меняет только mode bits.
abstract final class FilePermissions {
  const FilePermissions._();

  /// Оставляет владельцу чтение и запись, остальным — ничего.
  static void file(File file) => _set(file.path, directory: false);

  /// Оставляет владельцу полный доступ, остальным — ничего.
  static void directory(Directory dir) => _set(dir.path, directory: true);

  static void _set(String path, {required bool directory}) {
    // На iOS нельзя порождать процессы, а каталог приложения и так закрыт
    // песочницей ОС.
    if (Platform.isIOS) return;
    try {
      if (Platform.isWindows) {
        _setWindowsAcl(path, directory: directory);
      } else {
        _setPosixMode(path, directory: directory);
      }
    } on Object {
      // Права — дополнительная защита. Если утилита недоступна, приложение
      // продолжает работать: на мобильных доступ и так закрыт песочницей.
    }
  }

  static void _setPosixMode(String path, {required bool directory}) {
    // `chmod` меняет только mode bits, но не снимает ACL.
    if (Platform.isMacOS) Process.runSync('chmod', ['-N', path]);
    Process.runSync('chmod', [directory ? '700' : '600', path]);
  }

  static void _setWindowsAcl(String path, {required bool directory}) {
    final principal = _windowsPrincipal();
    if (principal == null) return;
    // Наследование от родителя отключается, явные разрешения других
    // пользователей не добавляются. Для каталога права наследуются детьми.
    final grant = directory ? '$principal:(OI)(CI)F' : '$principal:F';
    Process.runSync('icacls', [path, '/inheritance:r', '/grant:r', grant]);
  }

  /// `DOMAIN\user` в том виде, в каком его принимает `icacls`.
  static String? _windowsPrincipal() {
    final user = Platform.environment['USERNAME'];
    if (user == null || user.isEmpty) return null;
    final domain = Platform.environment['USERDOMAIN'];
    if (domain == null || domain.isEmpty) return user;
    return '$domain\\$user';
  }
}

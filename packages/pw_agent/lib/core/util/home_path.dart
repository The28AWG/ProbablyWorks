import 'dart:io';

/// Раскрывает `~` и `~/...` по домашнему каталогу машины, на которой запущено приложение.
/// Другие формы (`~user`, `$HOME`) не раскрываются.
String expandHomePath(String path, {Map<String, String>? environment}) {
  if (path != '~' && !path.startsWith('~/')) return path;
  final env = environment ?? Platform.environment;
  final home = env['HOME'] ?? env['USERPROFILE'];
  if (home == null) return path;
  return '$home${path.replaceFirst('~', '')}';
}

/// Путь к файлу ключа, который приложение сможет открыть: абсолютный или `~/...`.
bool isSupportedKeyPath(String path) =>
    path.startsWith('/') ||
    path.startsWith('~/') ||
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

import 'package:pw_agent/core/config/app_paths.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/security/file_permissions.dart';

/// Один раз приводит права файлов, созданных старыми версиями, к текущим.
///
/// Раньше БД, `mcp.json` и lock создавались с режимом из umask (обычно 0644),
/// поэтому аудит безопасности видел бы в них отклонение от ожидаемых 0600.
/// Миграция выполняется только при первом запуске новой версии: последующие
/// изменения прав уже считаются сигналом, а не наследием старых сборок.
Future<void> migrateFilePermissions(
  AppPaths paths,
  SettingsRepository settings,
) async {
  if (await settings.read(SettingsRepository.keyPermissionsMigrated) == 'yes') {
    return;
  }
  FilePermissions.directory(paths.support);
  if (paths.root.existsSync()) FilePermissions.directory(paths.root);
  if (paths.logs.existsSync()) FilePermissions.directory(paths.logs);
  for (final file in [paths.database, paths.lockFile, paths.mcpConfig]) {
    if (file.existsSync()) FilePermissions.file(file);
  }
  await settings.write(SettingsRepository.keyPermissionsMigrated, 'yes');
}

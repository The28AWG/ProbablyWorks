import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/app/bootstrap/app_paths.dart';
import 'package:probably_works/app/bootstrap/file_permissions_migration.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/db/db_connection.dart';
import 'package:probably_works/core/security/file_permissions.dart';

void main() {
  late Directory tmp;
  late AppPaths paths;
  late SettingsRepository settings;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('pw_file_permissions');
    paths = AppPaths.forSupport(tmp);
    final db = openInMemoryDatabase();
    addTearDown(db.close);
    settings = SettingsRepository(db);
    await settings.preload();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('files get owner-only mode', () {
    if (Platform.isWindows) return;
    final file = File('${tmp.path}/file')..writeAsStringSync('x');

    FilePermissions.file(file);

    expect(_mode(file), '600');
  });

  test('directories get owner-only mode', () {
    if (Platform.isWindows) return;
    final dir = Directory('${tmp.path}/dir')..createSync();

    FilePermissions.directory(dir);

    expect(_mode(dir), '700');
  });

  test('migration fixes files created by older versions once', () async {
    if (Platform.isWindows) return;
    paths.database.writeAsStringSync('db');
    paths.mcpConfig.writeAsStringSync('{}');
    paths.logs.createSync();
    _chmod(tmp.path, '755');
    _chmod(paths.database.path, '644');
    _chmod(paths.mcpConfig.path, '644');
    _chmod(paths.logs.path, '755');

    await migrateFilePermissions(paths, settings);

    expect(_mode(tmp), '700');
    expect(_mode(paths.database), '600');
    expect(_mode(paths.mcpConfig), '600');
    expect(_mode(paths.logs), '700');
    expect(
      await settings.read(SettingsRepository.keyPermissionsMigrated),
      'yes',
    );

    // Повторный запуск не должен скрывать изменения, сделанные позже.
    _chmod(paths.database.path, '644');
    await migrateFilePermissions(paths, settings);
    expect(_mode(paths.database), '644');
  });
}

/// Восьмеричный режим без типа файла.
String _mode(FileSystemEntity entity) =>
    (FileStat.statSync(entity.path).mode & 0x1FF)
        .toRadixString(8)
        .padLeft(3, '0');

void _chmod(String path, String mode) {
  final result = Process.runSync('chmod', [mode, path]);
  expect(result.exitCode, 0, reason: 'chmod $mode $path');
}

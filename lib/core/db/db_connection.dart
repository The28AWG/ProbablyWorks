import 'dart:io';

import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:probably_works/core/db/app_database.dart';
import 'package:probably_works/core/security/file_permissions.dart';

/// Открытие файловой БД в фоновом изоляте. Один экземпляр приложения на файл:
/// см. [SingleInstanceLock].
AppDatabase openAppDatabase(Directory supportDir) {
  final file = File(p.join(supportDir.path, 'probably_works.db'));
  final created = !file.existsSync();
  if (created) file.createSync(recursive: true);
  if (created) FilePermissions.file(file);
  return AppDatabase(NativeDatabase.createInBackground(file));
}

AppDatabase openInMemoryDatabase() => AppDatabase(NativeDatabase.memory());

/// Lock-файл: второй процесс на ту же базу не стартует (иначе две записи в SQLite).
class SingleInstanceLock {
  SingleInstanceLock(this.file);

  final File file;
  RandomAccessFile? _handle;

  /// Возвращает true, если блокировка получена.
  bool acquire() {
    try {
      file.parent.createSync(recursive: true);
      final created = !file.existsSync();
      _handle = file.openSync(mode: FileMode.write);
      if (created) FilePermissions.file(file);
      _handle!.lockSync(FileLock.exclusive);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  void release() {
    _handle?.unlockSync();
    _handle?.closeSync();
    _handle = null;
  }
}

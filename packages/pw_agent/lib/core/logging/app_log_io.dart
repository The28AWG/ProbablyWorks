import 'dart:io';

import 'package:logging/logging.dart';
import 'package:pw_agent/core/security/file_permissions.dart';
import 'package:pw_agent/core/util/redactor.dart';

const _maxBytes = 2 * 1024 * 1024;
const _keepFiles = 3;

/// Файловый журнал с ротацией. Запускается только в native-сборке.
Future<void> init(String logDir) async {
  final directory = Directory(logDir);
  final created = !directory.existsSync();
  await directory.create(recursive: true);
  if (created) FilePermissions.directory(directory);
  final file = File('${directory.path}/app.log');
  _ensureFile(file);
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    final line = Redactor.redact(
      '${record.time.toIso8601String()} ${record.level.name} '
      '${record.loggerName}: ${record.message}'
      '${record.error == null ? '' : ' | ${record.error}'}',
    );
    _rotateIfNeeded(file);
    _ensureFile(file);
    file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  });
}

void _ensureFile(File file) {
  if (file.existsSync()) return;
  file.createSync(recursive: true);
  FilePermissions.file(file);
}

void _rotateIfNeeded(File file) {
  if (!file.existsSync() || file.lengthSync() < _maxBytes) return;
  for (var i = _keepFiles - 1; i >= 1; i--) {
    final from = File('${file.path}.$i');
    if (from.existsSync()) from.renameSync('${file.path}.${i + 1}');
  }
  file.renameSync('${file.path}.1');
}

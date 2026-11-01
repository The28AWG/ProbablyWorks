import 'dart:io';

import 'package:logging/logging.dart';
import 'package:probably_works/core/util/redactor.dart';

/// Локальный лог приложения: файл с ротацией, без содержимого секретов.
abstract final class AppLog {
  const AppLog._();
  static const _maxBytes = 2 * 1024 * 1024;
  static const _keepFiles = 3;

  static final Logger root = Logger('ProbablyWorks');

  static Future<void> init(Directory logDir) async {
    await logDir.create(recursive: true);
    final file = File('${logDir.path}/app.log');
    Logger.root.level = Level.INFO;
    Logger.root.onRecord.listen((record) {
      final line = Redactor.redact(
        '${record.time.toIso8601String()} ${record.level.name} ${record.loggerName}: '
        '${record.message}${record.error == null ? '' : ' | ${record.error}'}',
      );
      _rotateIfNeeded(file);
      file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    });
  }

  static void _rotateIfNeeded(File file) {
    if (!file.existsSync() || file.lengthSync() < _maxBytes) return;
    for (var i = _keepFiles - 1; i >= 1; i--) {
      final from = File('${file.path}.$i');
      if (from.existsSync()) from.renameSync('${file.path}.${i + 1}');
    }
    file.renameSync('${file.path}.1');
  }
}

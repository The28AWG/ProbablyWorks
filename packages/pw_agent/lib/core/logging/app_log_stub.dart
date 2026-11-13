import 'package:logging/logging.dart';

/// Web-заглушка: файловой системы нет, журнал остаётся в консоли браузера.
Future<void> init(String _) {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    // ignore: avoid_print, web-сборка без файлового лога
    print('${record.level.name} ${record.loggerName}: ${record.message}');
  });
  return Future<void>.value();
}

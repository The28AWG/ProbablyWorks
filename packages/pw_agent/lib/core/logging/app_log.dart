import 'package:logging/logging.dart';

import 'package:pw_agent/core/logging/app_log_stub.dart'
    if (dart.library.io) 'package:pw_agent/core/logging/app_log_io.dart'
    as sink;

/// Локальный лог приложения: файл с ротацией, без содержимого секретов.
///
/// На web файлового лога нет: [init] ничего не делает, но [root] остаётся
/// общим логгером, чтобы код ядра не зависел от платформы.
abstract final class AppLog {
  const AppLog._();

  static final Logger root = Logger('ProbablyWorks');

  static Future<void> init(String logDir) => sink.init(logDir);
}

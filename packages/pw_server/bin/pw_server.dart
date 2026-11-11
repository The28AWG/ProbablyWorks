import 'dart:io';

import 'package:pw_server/pw_server.dart';

Future<void> main(List<String> args) async {
  exitCode = await runDaemon(args);
  // Сервисы (каталог моделей, MCP) держат таймеры; демон завершается явно.
  exit(exitCode);
}

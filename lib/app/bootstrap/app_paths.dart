import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Каталоги данных приложения. Всё, что не в secure storage, живёт здесь.
class AppPaths {
  AppPaths._(this.support);

  /// Корень данных: БД, логи запусков (`chats/`), журнал приложения (`logs/`), lock.
  final Directory support;

  Directory get root => Directory(p.join(support.path, 'data'));

  Directory get logs => Directory(p.join(support.path, 'logs'));

  File get lockFile => File(p.join(support.path, 'instance.lock'));

  /// Пользовательская конфигурация MCP. Импортируется при старте и на desktop
  /// перечитывается при изменении файла.
  File get mcpConfig => File(p.join(support.path, 'mcp.json'));

  static Future<AppPaths> resolve() async {
    final dir = await getApplicationSupportDirectory();
    final support = Directory(p.join(dir.path, 'ProbablyWorks'));
    await support.create(recursive: true);
    return AppPaths._(support);
  }
}

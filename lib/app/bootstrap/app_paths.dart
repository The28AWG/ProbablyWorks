import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:probably_works/core/security/file_permissions.dart';

/// Каталоги данных приложения. Всё, что не в secure storage, живёт здесь.
class AppPaths {
  AppPaths._(this.support);

  /// Тестовый и вспомогательный конструктор с готовым каталогом.
  factory AppPaths.forSupport(Directory support) => AppPaths._(support);

  /// Корень данных: БД, логи запусков (`chats/`), журнал приложения (`logs/`), lock.
  final Directory support;

  Directory get root => Directory(p.join(support.path, 'data'));

  Directory get logs => Directory(p.join(support.path, 'logs'));

  File get lockFile => File(p.join(support.path, 'instance.lock'));

  File get database => File(p.join(support.path, 'probably_works.db'));

  /// Пользовательская конфигурация MCP. Импортируется при старте и на desktop
  /// перечитывается при изменении файла.
  File get mcpConfig => File(p.join(support.path, 'mcp.json'));

  static Future<AppPaths> resolve() async {
    final dir = await getApplicationSupportDirectory();
    final support = Directory(p.join(dir.path, 'ProbablyWorks'));
    final created = !support.existsSync();
    await support.create(recursive: true);
    if (created) FilePermissions.directory(support);
    return AppPaths._(support);
  }
}

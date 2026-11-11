import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pw_agent/core/config/app_paths.dart';
import 'package:pw_agent/core/security/file_permissions.dart';

/// Каталог данных Flutter-клиента: `getApplicationSupportDirectory()`.
///
/// Сам [AppPaths] живёт в агенте и не зависит от Flutter: демон создаёт его
/// из XDG/AppData, клиент — через path_provider.
Future<AppPaths> resolveAppPaths() async {
  final dir = await getApplicationSupportDirectory();
  final support = Directory(p.join(dir.path, 'ProbablyWorks'));
  final created = !support.existsSync();
  await support.create(recursive: true);
  if (created) FilePermissions.directory(support);
  return AppPaths.forSupport(support);
}

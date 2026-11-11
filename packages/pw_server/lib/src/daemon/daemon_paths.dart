import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pw_agent/core/config/app_paths.dart';
import 'package:pw_agent/core/security/file_permissions.dart';

/// Идентификатор приложения совпадает с Linux/macOS/Windows путями Flutter-клиента.
const appId = 'com.the28awg.probably_works';

/// Каталог данных демона: тот же, что у клиента, если не задан [explicit].
Future<AppPaths> resolveDaemonPaths({String? explicit}) async {
  final support = explicit == null
      ? Directory(p.join(_platformRoot(), 'ProbablyWorks'))
      : Directory(explicit);
  final created = !support.existsSync();
  await support.create(recursive: true);
  if (created) FilePermissions.directory(support);
  return AppPaths.forSupport(support);
}

String _platformRoot() {
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'];
    if (appData == null || appData.isEmpty) {
      throw StateError('APPDATA is not set');
    }
    return p.join(appData, appId);
  }
  if (Platform.isMacOS) {
    return p.join(_home(), 'Library', 'Application Support', appId);
  }
  final dataHome = Platform.environment['XDG_DATA_HOME'];
  if (dataHome != null && dataHome.isNotEmpty) {
    return p.join(dataHome, appId);
  }
  return p.join(_home(), '.local', 'share', appId);
}

String _home() {
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) {
    throw StateError('HOME is not set; pass --data-dir');
  }
  return home;
}

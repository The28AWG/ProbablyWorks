import 'package:package_info_plus/package_info_plus.dart';
import 'package:probably_works/core/platform/client_info.dart';
import 'package:pw_agent/core/logging/app_log.dart';

/// Сведения о клиенте из `package_info`. Общая для обычного старта приложения
/// и фонового запуска планировщика. Ошибка чтения не критична: заголовки
/// удалённого API получат запасные значения.
Future<ClientInfo> loadClientInfo() async {
  try {
    return ClientInfo.fromPackageInfo(await PackageInfo.fromPlatform());
  } on Object catch (error) {
    AppLog.root.warning('cannot read package info', error);
    return const ClientInfo.fallback();
  }
}

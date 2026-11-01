import 'package:flutter/widgets.dart';
import 'package:probably_works/agent/recovery/startup_recovery.dart';
import 'package:probably_works/app/bootstrap/app_paths.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/locale/locale_controller.dart';
import 'package:probably_works/core/data/host_repository.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/db/db_connection.dart';
import 'package:probably_works/core/logging/app_log.dart';

/// Порядок старта: один экземпляр → журнал → DI (БД, секреты) → восстановление → локальный Host.
/// Возвращает false, если другой экземпляр уже работает с этой базой.
Future<bool> bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();
  final paths = await AppPaths.resolve();
  final lock = SingleInstanceLock(paths.lockFile);
  if (!lock.acquire()) return false;
  await AppLog.init(paths.logs);
  await configureDependencies();
  await getIt<StartupRecovery>().run();
  await getIt<HostRepository>().ensureLocalHost(DateTime.now());
  getIt<LocaleController>().apply(
    await getIt<SettingsRepository>().read(SettingsRepository.keyLanguage),
  );
  return true;
}

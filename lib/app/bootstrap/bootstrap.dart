import 'package:flutter/widgets.dart';
import 'package:probably_works/agent/recovery/startup_recovery.dart';
import 'package:probably_works/app/bootstrap/app_paths.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/locale/locale_controller.dart';
import 'package:probably_works/core/data/host_repository.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/db/db_connection.dart';
import 'package:probably_works/core/logging/app_log.dart';
import 'package:probably_works/core/security/secret_store.dart';
import 'package:probably_works/features/workspace/presentation/bloc/sidebar_cubit.dart';
import 'package:probably_works/providers/ai/model_catalog.dart';

/// Порядок старта: один экземпляр → журнал → DI (БД, секреты) → восстановление → локальный Host →
/// настройки интерфейса (язык, ширина панели) → фоновое обновление каталога моделей. Возвращает false, если другой экземпляр уже работает с этой базой.
Future<bool> bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();
  final paths = await AppPaths.resolve();
  final lock = SingleInstanceLock(paths.lockFile);
  if (!lock.acquire()) return false;
  await AppLog.init(paths.logs);
  await configureDependencies();
  await getIt<StartupRecovery>().run();
  await getIt<HostRepository>().ensureLocalHost(DateTime.now());
  // Ширина панели читается здесь, а не в кубите: иначе панель сначала показывается с ширины по умолчанию и переезжает.
  getIt.registerSingleton(
    SidebarStartupWidth(
      await SidebarCubit.loadWidth(getIt<SettingsRepository>()),
    ),
  );
  getIt<LocaleController>().apply(
    await getIt<SettingsRepository>().read(SettingsRepository.keyLanguage),
  );
  // Не ждём сеть: выбранные модели уже известны из БД, а список придёт в фоне.
  await getIt<ModelCatalogService>().start(hasKey: _hasOpenRouterKey);
  return true;
}

Future<bool> _hasOpenRouterKey() async {
  final key = await getIt<SecretStore>().read(openRouterKeyName);
  return key != null && key.isNotEmpty;
}

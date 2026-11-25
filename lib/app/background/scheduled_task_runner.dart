import 'package:flutter/widgets.dart';
import 'package:probably_works/app/bootstrap/app_paths_resolve.dart';
import 'package:probably_works/app/bootstrap/client_info.dart';
import 'package:probably_works/app/di/injection_native.dart';
import 'package:probably_works/core/platform/app_platform.dart';
import 'package:probably_works/core/platform/client_info.dart';
import 'package:probably_works/core/settings/client_settings.dart';
import 'package:pw_agent/agent/schedule/task_scheduler.dart';
import 'package:pw_agent/core/config/app_paths.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/logging/app_log.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

/// Запускает планировщик отложенных задач на текущей платформе.
///
/// На desktop он живёт в процессе приложения и работает, пока оно открыто.
/// На Android и iOS дополнительно регистрируется периодическая фоновая задача
/// WorkManager: система поднимает приложение, когда оно закрыто, и прогоняет
/// очередь. Проходы в приложении и в фоне разделяет блокировка базы: пока
/// приложение держит данные, фоновый изолят очередь пропускает.
class ScheduledTaskRunner {
  ScheduledTaskRunner(this._scheduler);

  final TaskScheduler _scheduler;

  /// Идентификатор фоновой задачи. На iOS он же должен быть перечислен в
  /// `BGTaskSchedulerPermittedIdentifiers` (см. ios/Runner/Info.plist).
  static const taskIdentifier = 'com.the28awg.probablyWorks.scheduledTasks';

  /// Запускает таймер и, на телефонах, регистрирует фоновую задачу.
  Future<void> start() async {
    _scheduler.start();
    if (!AppPlatform.current.isMobile) return;
    try {
      await Workmanager().initialize(scheduledTaskDispatcher);
      await Workmanager().registerPeriodicTask(
        taskIdentifier,
        taskIdentifier,
        frequency: const Duration(minutes: 15),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
    } on Object catch (error, stack) {
      AppLog.root.warning('cannot register background scheduler', error, stack);
    }
  }
}

/// Точка входа фоновой задачи WorkManager. Обязана быть top-level и помечена
/// как entry-point: плагин вызывает её в отдельном изоляте.
@pragma('vm:entry-point')
void scheduledTaskDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      await runScheduledTasksHeadless();
      return true;
    } on Object catch (error, stack) {
      AppLog.root.warning('scheduled task run failed', error, stack);
      return false;
    }
  });
}

/// Прогоняет очередь отложенных задач без интерфейса.
///
/// Повторяет минимальную часть старта приложения. Если база уже занята
/// (работает приложение или демон), проход пропускается: очередь обработает
/// владелец базы.
Future<void> runScheduledTasksHeadless() async {
  WidgetsFlutterBinding.ensureInitialized();
  final paths = await resolveAppPaths();
  await AppLog.init(paths.logs.path);
  final lock = SingleInstanceLock(paths.lockFile);
  if (!lock.acquire()) return;
  try {
    final clientSettings = SharedPreferencesClientSettings(
      SharedPreferencesAsync(),
    );
    final clientInfo = await loadClientInfo(settings: clientSettings);
    getIt
      ..registerSingleton<AppPaths>(paths)
      ..registerSingleton<ClientInfo>(clientInfo)
      ..registerSingleton<ClientSettings>(clientSettings);
    await configureDependencies();
    await getIt<SettingsRepository>().preload();
    await getIt<HostRepository>().ensureLocalHost(DateTime.now());
    // База закроется сразу после хода: обновление памяти проекта требует сети
    // и времени, поэтому здесь оно выключено и произойдёт в обычном ходе.
    final scheduler = getIt<TaskScheduler>()..disableProjectMemoryUpdates();
    await scheduler.tick(awaitTurns: true);
  } finally {
    if (getIt.isRegistered<AppDatabase>()) {
      await getIt<AppDatabase>().close();
    }
    lock.release();
  }
}

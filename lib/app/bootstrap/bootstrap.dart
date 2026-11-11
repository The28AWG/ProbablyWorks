import 'package:flutter/widgets.dart';
import 'package:probably_works/agent/loop/agent_hub.dart';
import 'package:probably_works/agent/mcp/mcp_service.dart';
import 'package:probably_works/agent/project/project_lifecycle.dart';
import 'package:probably_works/agent/recovery/startup_recovery.dart';
import 'package:probably_works/app/bootstrap/app_paths.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/locale/locale_controller.dart';
import 'package:probably_works/app/theme/theme_controller.dart';
import 'package:probably_works/core/data/host_repository.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/db/db_connection.dart';
import 'package:probably_works/core/logging/app_log.dart';
import 'package:probably_works/core/platform/app_platform.dart';
import 'package:probably_works/core/security/secret_store.dart';
import 'package:probably_works/features/chats/presentation/bloc/chat_list_cubit.dart';
import 'package:probably_works/features/workspace/presentation/bloc/sidebar_cubit.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:probably_works/providers/ai/model_catalog.dart';

/// Порядок старта: один экземпляр → журнал → DI (БД, секреты) → восстановление → локальный Host →
/// настройки интерфейса (язык, ширина панели) → фоновое обновление каталога моделей. Возвращает false, если другой экземпляр уже работает с этой базой.
Future<bool> bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();
  final paths = await AppPaths.resolve();
  final lock = SingleInstanceLock(paths.lockFile);
  // На телефоне второй экземпляр приложения система не запускает, а файловая блокировка может
  // не поддерживаться (sandbox, сетевые тома). Поэтому отказ блокировки там не считаем «уже запущено».
  if (!lock.acquire() && !AppPlatform.current.isMobile) return false;
  await AppLog.init(paths.logs);
  await configureDependencies();
  // Настройки в память до любого чтения: первый кадр нового чата берёт модель и политику синхронно.
  await getIt<SettingsRepository>().preload();
  final language = await getIt<SettingsRepository>().read(
    SettingsRepository.keyLanguage,
  );
  final closedText = lookupAppLocalizations(resolveAppLocale(language))
      .runInterruptedByClose;
  await getIt<StartupRecovery>().run(closedText: closedText);
  // Локальный Host нужен до продолжения хода: иначе шаг, оборванный на нём, не найдёт рантайм.
  await getIt<HostRepository>().ensureLocalHost(DateTime.now());
  // Проекты чинятся до продолжения хода: у каждого чата должен быть проект.
  final projects = getIt<ProjectLifecycleService>();
  await projects.repairOrphans();
  await projects.purgeExpired();
  // mcp.json импортируется без подключения серверов: сеть и процессы не должны
  // задерживать первый кадр. Подключение произойдёт перед первым запросом.
  await getIt<McpService>().start(configFile: paths.mcpConfig);
  // Карточки здесь не показываются. Их регистрирует открытие чата.
  // Вызовы без карточки, чьи зависимости уже закрыты, продолжаются сразу.
  await getIt<AgentHub>().resumeAfterRestart();
  // Хосты тоже читаются здесь, чтобы список хостов был в первом кадре, а не появлялся после чтения БД.
  getIt.registerSingleton(StartupHosts(await getIt<HostRepository>().all()));
  // Ширина панели читается здесь, а не в кубите: иначе панель сначала показывается с ширины по умолчанию и переезжает.
  getIt.registerSingleton(
    SidebarStartupWidth(
      await SidebarCubit.loadWidth(getIt<SettingsRepository>()),
    ),
  );
  getIt<LocaleController>().apply(language);
  // Тема применяется до первого кадра, иначе приложение сначала мелькает в системной теме.
  final themeMode = await getIt<SettingsRepository>().read(
    SettingsRepository.keyThemeMode,
  );
  getIt<ThemeController>().apply(ThemeController.modeFrom(themeMode));
  // Не ждём сеть: выбранные модели уже известны из БД, а список придёт в фоне.
  await getIt<ModelCatalogService>().start(hasKey: _hasOpenRouterKey);
  return true;
}

Future<bool> _hasOpenRouterKey() async {
  final key = await getIt<SecretStore>().read(openRouterKeyName);
  return key != null && key.isNotEmpty;
}

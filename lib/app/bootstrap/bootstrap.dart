import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:probably_works/app/bootstrap/app_paths_resolve.dart';
import 'package:probably_works/app/bootstrap/file_permissions_migration.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/locale/locale_controller.dart';
import 'package:probably_works/app/profiles/local_agent_apis.dart';
import 'package:probably_works/app/profiles/local_daemon_discovery.dart';
import 'package:probably_works/app/profiles/local_daemon_launcher.dart';
import 'package:probably_works/app/profiles/profile_service.dart';
import 'package:probably_works/app/theme/theme_controller.dart';
import 'package:probably_works/core/platform/app_platform.dart';
import 'package:probably_works/core/platform/client_info.dart';
import 'package:probably_works/core/settings/client_settings.dart';
import 'package:probably_works/features/chats/presentation/bloc/chat_list_cubit.dart';
import 'package:probably_works/features/workspace/presentation/bloc/sidebar_cubit.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/exec/live_output_bus.dart';
import 'package:pw_agent/agent/mcp/mcp_service.dart';
import 'package:pw_agent/agent/project/project_lifecycle.dart';
import 'package:pw_agent/agent/recovery/startup_recovery.dart';
import 'package:pw_agent/core/config/app_paths.dart';
import 'package:pw_agent/core/config/local_daemon_info.dart';
import 'package:pw_agent/core/data/chat_draft_store.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/logging/app_log.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/core/security/system_secret_store.dart';
import 'package:pw_agent/host/ssh_connection_pool.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';
import 'package:pw_client/pw_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Порядок старта: поиск или автозапуск локального демона → embedded или
/// local daemon → восстановление → локальный Host → настройки интерфейса →
/// каталог моделей.
///
/// Возвращает false, если другой экземпляр уже работает с этой базой.
Future<bool> bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();
  final paths = await resolveAppPaths();
  await AppLog.init(paths.logs);
  final clientInfo = await _loadClientInfo();
  final clientSettings = SharedPreferencesClientSettings(
    SharedPreferencesAsync(),
  );
  getIt
    ..registerSingleton<AppPaths>(paths)
    ..registerSingleton<ClientInfo>(clientInfo)
    ..registerSingleton<ClientSettings>(clientSettings);

  // На телефоне локального демона нет: там либо embedded, либо удалённый
  // профиль. Переменная окружения выключает демон и на desktop — для отладки.
  if (AppPlatform.current.isMobile || localDaemonDisabled()) {
    return _bootstrapEmbedded(paths, clientSettings);
  }

  final daemonSecrets = createSystemSecretStore(
    support: paths.support,
    environment: Platform.environment,
    // Не переносим токен старого файлового демона в keyring: он ещё
    // работает и не увидит новый ключ.
    migrate: false,
  );
  final discovery = LocalDaemonDiscovery(paths, secrets: daemonSecrets);
  final starter = LocalDaemonStarter(discovery);
  try {
    final running = await discovery.find();
    if (running != null) {
      return await _bootstrapDaemon(running, clientSettings);
    }
    // Если БД уже занята, второй процесс запускать нельзя. Скорее всего, это
    // другой embedded-GUI; но демон мог захватить lock до записи daemon.json.
    if (!_databaseLockFree(paths)) {
      final late = await starter.waitForStartup(
        timeout: const Duration(seconds: 2),
      );
      if (late != null) return await _bootstrapDaemon(late, clientSettings);
      return false;
    }
    final daemon = await starter.ensureRunning(paths);
    if (daemon != null) {
      return await _bootstrapDaemon(daemon, clientSettings);
    }
    final embedded = await _bootstrapEmbedded(paths, clientSettings);
    if (embedded) return true;
    // Демон мог занять БД чуть позже таймаута автозапуска. Тогда embedded
    // не получил блокировку, но подключиться к демону всё ещё можно.
    final late = await starter.waitForStartup(
      timeout: const Duration(seconds: 3),
    );
    if (late != null) return await _bootstrapDaemon(late, clientSettings);
    return false;
  } finally {
    discovery.dispose();
  }
}

/// Проверяет, свободна ли блокировка БД, не удерживая её постоянно.
///
/// Между проверкой и фактическим запуском возможна гонка, но она приводит лишь
/// к неудачному старту демона, а не к повреждению базы.
bool _databaseLockFree(AppPaths paths) {
  final lock = SingleInstanceLock(paths.lockFile);
  if (!lock.acquire()) return false;
  lock.release();
  return true;
}

Future<bool> _bootstrapEmbedded(
  AppPaths paths,
  ClientSettings clientSettings,
) async {
  final lock = SingleInstanceLock(paths.lockFile);
  // На телефоне второй экземпляр приложения система не запускает, а файловая блокировка может
  // не поддерживаться (sandbox, сетевые тома). Поэтому отказ блокировки там не считаем «уже запущено».
  if (!lock.acquire() && !AppPlatform.current.isMobile) return false;
  await configureDependencies();
  // Настройки в память до любого чтения: первый кадр нового чата берёт модель и политику синхронно.
  await getIt<SettingsRepository>().preload();
  await migrateClientSettings(clientSettings, getIt<SettingsRepository>());
  await getIt<ProfileService>().load();
  // До чтения mcp.json: старые версии оставили 0644, и аудит считал бы это изменением.
  await migrateFilePermissions(paths, getIt<SettingsRepository>());
  final language = await clientSettings.read(ClientSettingsKeys.language);
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
  await getIt<AgentApi>().resumeAfterRestart();
  // Хосты тоже читаются здесь, чтобы список хостов был в первом кадре, а не появлялся после чтения БД.
  getIt.registerSingleton(StartupHosts(await getIt<HostRepository>().all()));
  // Ширина панели читается здесь, а не в кубите: иначе панель сначала показывается с ширины по умолчанию и переезжает.
  getIt.registerSingleton(
    SidebarStartupWidth(await SidebarCubit.loadWidth(clientSettings)),
  );
  getIt<LocaleController>().apply(language);
  // Тема применяется до первого кадра, иначе приложение сначала мелькает в системной теме.
  final themeMode = await clientSettings.read(ClientSettingsKeys.themeMode);
  getIt<ThemeController>().apply(ThemeController.modeFrom(themeMode));
  // Не ждём сеть: выбранные модели уже известны из БД, а список придёт в фоне.
  await getIt<ModelCatalogService>().start(hasKey: _hasOpenRouterKey);
  return true;
}

Future<bool> _bootstrapDaemon(
  LocalDaemonInfo daemon,
  ClientSettings clientSettings,
) async {
  await configureClientDependencies();
  getIt
    ..registerSingleton<LiveOutputBus>(LiveOutputBus())
    ..registerSingleton<HostKeyConfirmations>(HostKeyConfirmations())
    ..registerSingleton<ChatDraftStore>(ChatDraftStore.unbound());
  final remote = RemoteAgentApi(
    baseUri: Uri.parse('http://127.0.0.1:${daemon.port}'),
    token: daemon.token,
    clientHeaders: getIt<ClientInfo>().headers,
  )..startEvents();
  getIt<LocalAgentApisProvider>().set(
    LocalAgentApis(
      mode: LocalRuntimeMode.localDaemon,
      agent: remote,
      chat: remote,
      hosts: remote,
      projects: remote,
      settings: remote,
      mcp: remote,
      plugins: remote,
      audit: remote,
      push: remote,
    ),
  );
  final profileService = getIt<ProfileService>();
  await profileService.load();
  await profileService.migrateSecretsToLocalDaemon();
  profileService.attachLocalNotices();
  // Локальный профиль — remote API демона. Начальные хосты придут по SSE,
  // но ChatListCubit должен получить пустой список, а не обращаться к БД.
  getIt
    ..registerSingleton(const StartupHosts([]))
    ..registerSingleton(
      SidebarStartupWidth(await SidebarCubit.loadWidth(clientSettings)),
    );
  final language = await clientSettings.read(ClientSettingsKeys.language);
  getIt<LocaleController>().apply(language);
  final themeMode = await clientSettings.read(ClientSettingsKeys.themeMode);
  getIt<ThemeController>().apply(ThemeController.modeFrom(themeMode));
  return true;
}

Future<ClientInfo> _loadClientInfo() async {
  try {
    return ClientInfo.fromPackageInfo(await PackageInfo.fromPlatform());
  } on Object catch (error) {
    AppLog.root.warning('cannot read package info', error);
    return const ClientInfo.fallback();
  }
}

Future<bool> _hasOpenRouterKey() async {
  final key = await getIt<SecretStore>().read(openRouterKeyName);
  return key != null && key.isNotEmpty;
}

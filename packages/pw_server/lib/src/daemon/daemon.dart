import 'dart:async';
import 'dart:io';

import 'package:plugin_declarative_commands_core/declarative_commands_plugin.dart';
import 'package:plugin_declarative_http_core/declarative_http_plugin.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/agent_settings_api.dart';
import 'package:pw_agent/agent/api/hosts_api.dart';
import 'package:pw_agent/agent/api/local_agent_api.dart';
import 'package:pw_agent/agent/api/mcp_api.dart';
import 'package:pw_agent/agent/api/plugin_api.dart';
import 'package:pw_agent/agent/api/projects_api.dart';
import 'package:pw_agent/agent/mcp/mcp_service.dart';
import 'package:pw_agent/agent/plugins/plugin_registry.dart';
import 'package:pw_agent/agent/project/project_lifecycle.dart';
import 'package:pw_agent/agent/recovery/startup_recovery.dart';
import 'package:pw_agent/agent/schedule/task_scheduler.dart';
import 'package:pw_agent/agent_di.dart';
import 'package:pw_agent/core/appearance/appearance_port.dart';
import 'package:pw_agent/core/config/app_paths.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/logging/app_log.dart';
import 'package:pw_agent/core/notify/app_notifier.dart';
import 'package:pw_agent/core/platform/external_url_opener.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';
import 'package:pw_server/src/api/api_server.dart';
import 'package:pw_server/src/api/api_token.dart';
import 'package:pw_server/src/daemon/daemon_options.dart';
import 'package:pw_server/src/daemon/daemon_paths.dart';
import 'package:pw_server/src/daemon/daemon_secret_store.dart';
import 'package:pw_server/src/daemon/noop_app_notifier.dart';
import 'package:pw_server/src/daemon/noop_appearance.dart';
import 'package:pw_server/src/daemon/process_url_opener.dart';

/// Запускает headless-демон. Возвращает код выхода.
Future<int> runDaemon(List<String> args) async {
  final DaemonOptions options;
  try {
    options = DaemonOptions.fromArgs(args);
  } on FormatException catch (error) {
    stderr
      ..writeln(error.message)
      ..writeln(DaemonOptions.usage);
    return 2;
  }
  if (options.help) {
    stdout.writeln(DaemonOptions.usage);
    return 0;
  }

  final paths = await resolveDaemonPaths(explicit: options.dataDir);
  final lock = SingleInstanceLock(paths.lockFile);
  if (!lock.acquire()) {
    stderr.writeln(
      'Another ProbablyWorks instance already owns ${paths.support.path}',
    );
    return 1;
  }
  await AppLog.init(paths.logs);
  final secrets = DaemonSecretStore(
    paths.support,
    environment: Platform.environment,
  );
  getIt
    ..registerSingleton<AppPaths>(paths)
    ..registerSingleton<SecretStore>(secrets)
    ..registerSingleton<AppNotifier>(const NoopAppNotifier())
    ..registerSingleton<AppearancePort>(const NoopAppearance())
    ..registerSingleton<ExternalUrlOpener>(const ProcessUrlOpener())
    ..registerSingleton<PluginRegistry>(
      const PluginRegistry([
        DeclarativeCommandsPlugin(),
        DeclarativeHttpPlugin(),
      ]),
    );
  await configureAgentDependencies();

  final settings = getIt<SettingsRepository>();
  await settings.preload();
  await getIt<StartupRecovery>().run(
    closedText: 'The daemon was restarted while a run was active.',
  );
  await getIt<HostRepository>().ensureLocalHost(DateTime.now());
  final projects = getIt<ProjectLifecycleService>();
  await projects.repairOrphans();
  await projects.purgeExpired();
  await getIt<McpService>().start(configFile: paths.mcpConfig);
  await getIt<AgentApi>().resumeAfterRestart();
  await getIt<ModelCatalogService>().start(
    hasKey: () async {
      final key = await secrets.read(openRouterKeyName);
      return key != null && key.isNotEmpty;
    },
  );

  final tokens = ApiTokenStore(secrets);
  final token = options.rotateToken
      ? await tokens.rotate()
      : await tokens.ensure();
  final backend = getIt<LocalAgentApi>();
  final server = ApiServer(
    backend,
    token,
    address: options.bind,
    port: options.port,
    chat: backend,
    hosts: getIt<HostsApi>(),
    projects: getIt<ProjectsApi>(),
    settingsApi: getIt<AgentSettingsApi>(),
    mcpApi: getIt<McpApi>(),
    pluginApi: getIt<PluginApi>(),
  );
  final port = await server.start();
  final scheduler = getIt<TaskScheduler>()..start();

  final address = options.bind?.address ?? InternetAddress.loopbackIPv4.address;
  stdout.writeln('ProbablyWorks daemon listening on http://$address:$port');
  if (!_isLoopback(options.bind)) {
    stderr.writeln(
      'Warning: API is bound to $address. Use an SSH tunnel or a TLS proxy.',
    );
  }
  if (options.printToken) stdout.writeln('API token: $token');

  final shutdown = Completer<void>();
  final signals = <StreamSubscription<ProcessSignal>>[];
  void stop() {
    if (!shutdown.isCompleted) shutdown.complete();
  }

  signals.add(ProcessSignal.sigint.watch().listen((_) => stop()));
  try {
    signals.add(ProcessSignal.sigterm.watch().listen((_) => stop()));
  } on Object {
    // Windows не поддерживает SIGTERM.
  }

  await shutdown.future;
  for (final signal in signals) {
    await signal.cancel();
  }
  scheduler.stop();
  await server.stop();
  await getIt<AppDatabase>().close();
  lock.release();
  return 0;
}

bool _isLoopback(InternetAddress? address) =>
    address == null || address.isLoopback;

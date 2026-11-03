// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format width=80

// **************************************************************************
// InjectableConfigGenerator
// **************************************************************************

// ignore_for_file: type=lint
// coverage:ignore-file

// ignore_for_file: no_leading_underscores_for_library_prefixes

import 'package:flutter_secure_storage/flutter_secure_storage.dart' as _i558;
import 'package:get_it/get_it.dart' as _i174;
import 'package:injectable/injectable.dart' as _i526;

import '../../agent/context/context_builder.dart' as _i531;
import '../../agent/context/context_compactor.dart' as _i422;
import '../../agent/exec/active_exec_registry.dart' as _i970;
import '../../agent/exec/command_executor.dart' as _i401;
import '../../agent/exec/exec_log_store.dart' as _i67;
import '../../agent/exec/live_output_bus.dart' as _i972;
import '../../agent/interaction/interaction_broker.dart' as _i765;
import '../../agent/loop/agent_hub.dart' as _i168;
import '../../agent/recovery/startup_recovery.dart' as _i962;
import '../../agent/state/session_state_service.dart' as _i622;
import '../../agent/tools/self_tool_handler.dart' as _i235;
import '../../agent/tools/tool_executor.dart' as _i125;
import '../../agent/workspace/workspace_context_loader.dart' as _i359;
import '../../core/data/chat_draft_store.dart' as _i314;
import '../../core/data/chat_repository.dart' as _i193;
import '../../core/data/host_repository.dart' as _i250;
import '../../core/data/saved_model_repository.dart' as _i503;
import '../../core/data/settings_repository.dart' as _i913;
import '../../core/db/app_database.dart' as _i386;
import '../../core/notify/app_notifier.dart' as _i404;
import '../../core/security/secret_store.dart' as _i617;
import '../../host/host_diagnostics.dart' as _i441;
import '../../host/host_runtime_factory.dart' as _i559;
import '../../host/portable_pty_launcher.dart' as _i224;
import '../../host/pty_launcher.dart' as _i532;
import '../../host/ssh_connection_pool.dart' as _i719;
import '../../providers/ai/llm_port.dart' as _i432;
import '../../providers/ai/model_catalog.dart' as _i758;
import '../bootstrap/app_paths.dart' as _i859;
import '../guards/api_key_guard.dart' as _i519;
import '../locale/locale_controller.dart' as _i675;
import '../router/app_router.dart' as _i81;
import 'core_module.dart' as _i154;

extension GetItInjectableX on _i174.GetIt {
  // initializes the registration of main-scope dependencies inside of GetIt
  Future<_i174.GetIt> init({
    String? environment,
    _i526.EnvironmentFilter? environmentFilter,
  }) async {
    final gh = _i526.GetItHelper(this, environment, environmentFilter);
    final coreModule = _$CoreModule();
    await gh.factoryAsync<_i859.AppPaths>(
      () => coreModule.paths(),
      preResolve: true,
    );
    gh.singleton<_i970.ActiveExecRegistry>(() => _i970.ActiveExecRegistry());
    gh.singleton<_i972.LiveOutputBus>(() => _i972.LiveOutputBus());
    gh.singleton<_i765.InteractionBroker>(() => _i765.InteractionBroker());
    gh.singleton<_i558.FlutterSecureStorage>(() => coreModule.secureStorage);
    gh.singleton<_i675.LocaleController>(() => _i675.LocaleController());
    gh.lazySingleton<_i531.ContextBuilder>(() => _i531.ContextBuilder());
    gh.lazySingleton<_i719.HostKeyConfirmations>(
      () => _i719.HostKeyConfirmations(),
    );
    gh.lazySingleton<_i532.PtyLauncher>(
      () => const _i224.PortablePtyLauncher(),
    );
    gh.singleton<_i67.ExecLogStore>(
      () => coreModule.execLogStore(gh<_i859.AppPaths>()),
    );
    await gh.factoryAsync<_i386.AppDatabase>(
      () => coreModule.database(gh<_i859.AppPaths>()),
      preResolve: true,
    );
    gh.lazySingleton<_i193.ChatRepository>(
      () => _i193.ChatRepository(gh<_i386.AppDatabase>()),
    );
    gh.lazySingleton<_i250.HostRepository>(
      () => _i250.HostRepository(gh<_i386.AppDatabase>()),
    );
    gh.lazySingleton<_i503.SavedModelRepository>(
      () => _i503.SavedModelRepository(gh<_i386.AppDatabase>()),
    );
    gh.lazySingleton<_i913.SettingsRepository>(
      () => _i913.SettingsRepository(gh<_i386.AppDatabase>()),
    );
    gh.lazySingleton<_i617.SecretStore>(
      () => _i617.FlutterSecretStore(gh<_i558.FlutterSecureStorage>()),
    );
    gh.lazySingleton<_i962.StartupRecovery>(
      () => _i962.StartupRecovery(
        gh<_i193.ChatRepository>(),
        gh<_i67.ExecLogStore>(),
        gh<_i913.SettingsRepository>(),
      ),
    );
    gh.lazySingleton<_i404.AppNotifier>(() => _i404.PluginAppNotifier());
    gh.singleton<_i432.LlmProvider>(
      () => coreModule.llmProvider(gh<_i617.SecretStore>()),
    );
    gh.lazySingleton<_i401.CommandExecutor>(
      () => _i401.CommandExecutor(
        gh<_i67.ExecLogStore>(),
        gh<_i970.ActiveExecRegistry>(),
        gh<_i972.LiveOutputBus>(),
      ),
    );
    gh.lazySingleton<_i359.WorkspaceContextLoader>(
      () => _i359.WorkspaceContextLoader(gh<_i913.SettingsRepository>()),
    );
    gh.lazySingleton<_i519.ApiKeyGuard>(
      () => _i519.ApiKeyGuard(gh<_i617.SecretStore>()),
    );
    gh.lazySingleton<_i758.ModelCatalogService>(
      () => _i758.ModelCatalogService(
        gh<_i503.SavedModelRepository>(),
        gh<_i432.LlmProvider>(),
      ),
    );
    gh.lazySingleton<_i719.SshConnectionPool>(
      () => _i719.SshConnectionPool(
        gh<_i250.HostRepository>(),
        gh<_i617.SecretStore>(),
        gh<_i913.SettingsRepository>(),
        gh<_i719.HostKeyConfirmations>(),
      ),
    );
    gh.lazySingleton<_i622.SessionStateService>(
      () => _i622.SessionStateService(gh<_i193.ChatRepository>()),
    );
    gh.lazySingleton<_i314.ChatDraftStore>(
      () => _i314.ChatDraftStore(gh<_i193.ChatRepository>()),
    );
    gh.lazySingleton<_i422.ContextCompactor>(
      () => _i422.ContextCompactor(
        gh<_i193.ChatRepository>(),
        gh<_i432.LlmProvider>(),
        gh<_i531.ContextBuilder>(),
      ),
    );
    gh.singleton<_i81.AppRouter>(
      () => coreModule.appRouter(gh<_i519.ApiKeyGuard>()),
    );
    gh.lazySingleton<_i559.HostRuntimeFactory>(
      () => _i559.HostRuntimeFactory(
        gh<_i719.SshConnectionPool>(),
        gh<_i532.PtyLauncher>(),
      ),
    );
    gh.lazySingleton<_i441.HostDiagnostics>(
      () => _i441.HostDiagnostics(
        gh<_i250.HostRepository>(),
        gh<_i617.SecretStore>(),
        gh<_i913.SettingsRepository>(),
        gh<_i559.HostRuntimeFactory>(),
      ),
    );
    gh.lazySingleton<_i235.SelfToolHandler>(
      () => _i235.SelfToolHandler(
        gh<_i250.HostRepository>(),
        gh<_i913.SettingsRepository>(),
        gh<_i675.LocaleController>(),
        gh<_i758.ModelCatalogService>(),
        gh<_i441.HostDiagnostics>(),
      ),
    );
    gh.lazySingleton<_i125.ToolExecutor>(
      () => _i125.ToolExecutor(
        gh<_i193.ChatRepository>(),
        gh<_i401.CommandExecutor>(),
        gh<_i765.InteractionBroker>(),
        gh<_i622.SessionStateService>(),
        gh<_i359.WorkspaceContextLoader>(),
        gh<_i235.SelfToolHandler>(),
      ),
    );
    gh.singleton<_i168.AgentHub>(
      () => _i168.AgentHub(
        gh<_i193.ChatRepository>(),
        gh<_i913.SettingsRepository>(),
        gh<_i250.HostRepository>(),
        gh<_i559.HostRuntimeFactory>(),
        gh<_i432.LlmProvider>(),
        gh<_i758.ModelCatalogService>(),
        gh<_i531.ContextBuilder>(),
        gh<_i422.ContextCompactor>(),
        gh<_i125.ToolExecutor>(),
        gh<_i359.WorkspaceContextLoader>(),
        gh<_i622.SessionStateService>(),
        gh<_i765.InteractionBroker>(),
        gh<_i970.ActiveExecRegistry>(),
        gh<_i67.ExecLogStore>(),
        gh<_i404.AppNotifier>(),
      ),
    );
    return this;
  }
}

class _$CoreModule extends _i154.CoreModule {}

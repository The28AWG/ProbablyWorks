// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format width=80

// **************************************************************************
// InjectableConfigGenerator
// **************************************************************************

// ignore_for_file: type=lint
// coverage:ignore-file

// ignore_for_file: no_leading_underscores_for_library_prefixes

import 'package:get_it/get_it.dart' as _i174;
import 'package:injectable/injectable.dart' as _i526;

import 'agent/api/agent_settings_api.dart' as _i110;
import 'agent/api/draft_persistence.dart' as _i9;
import 'agent/api/hosts_api.dart' as _i907;
import 'agent/api/local_agent_api.dart' as _i269;
import 'agent/api/local_agent_settings_api.dart' as _i825;
import 'agent/api/local_chat_api.dart' as _i866;
import 'agent/api/local_hosts_api.dart' as _i915;
import 'agent/api/local_mcp_api.dart' as _i300;
import 'agent/api/local_plugin_api.dart' as _i929;
import 'agent/api/local_projects_api.dart' as _i623;
import 'agent/api/local_push_api.dart' as _i979;
import 'agent/api/local_security_audit_api.dart' as _i967;
import 'agent/api/mcp_api.dart' as _i151;
import 'agent/api/plugin_api.dart' as _i60;
import 'agent/api/projects_api.dart' as _i346;
import 'agent/api/push_api.dart' as _i52;
import 'agent/api/security_audit_api.dart' as _i796;
import 'agent/context/context_builder.dart' as _i654;
import 'agent/context/context_compactor.dart' as _i894;
import 'agent/exec/active_exec_registry.dart' as _i1048;
import 'agent/exec/command_executor.dart' as _i993;
import 'agent/exec/exec_log_store.dart' as _i473;
import 'agent/exec/live_output_bus.dart' as _i378;
import 'agent/interaction/interaction_broker.dart' as _i589;
import 'agent/mcp/mcp_client_manager.dart' as _i290;
import 'agent/mcp/mcp_service.dart' as _i176;
import 'agent/memory/project_memory_service.dart' as _i665;
import 'agent/plugins/plugin_registry.dart' as _i408;
import 'agent/plugins/plugin_service.dart' as _i298;
import 'agent/project/project_lifecycle.dart' as _i475;
import 'agent/recovery/startup_recovery.dart' as _i262;
import 'agent/schedule/scheduled_task_repository.dart' as _i453;
import 'agent/schedule/task_scheduler.dart' as _i778;
import 'agent/state/session_state_service.dart' as _i154;
import 'agent/tools/self_tool_handler.dart' as _i865;
import 'agent/tools/tool_executor.dart' as _i780;
import 'agent/turn/turn_changeset_service.dart' as _i214;
import 'agent/turn/turn_changeset_store.dart' as _i221;
import 'agent/workspace/workspace_context_loader.dart' as _i1055;
import 'agent_module.dart' as _i200;
import 'core/appearance/appearance_port.dart' as _i196;
import 'core/config/app_paths.dart' as _i342;
import 'core/data/chat_draft_store.dart' as _i171;
import 'core/data/chat_repository.dart' as _i906;
import 'core/data/draft_persistence_module.dart' as _i855;
import 'core/data/host_repository.dart' as _i985;
import 'core/data/mcp_server_repository.dart' as _i7;
import 'core/data/policy_profile_repository.dart' as _i215;
import 'core/data/project_repository.dart' as _i518;
import 'core/data/saved_model_repository.dart' as _i896;
import 'core/data/settings_repository.dart' as _i384;
import 'core/data/virtual_host_provisioner.dart' as _i400;
import 'core/db/app_database.dart' as _i232;
import 'core/notify/app_notifier.dart' as _i14;
import 'core/notify/push_service.dart' as _i737;
import 'core/platform/external_url_opener.dart' as _i1019;
import 'core/security/secret_store.dart' as _i249;
import 'core/security/security_audit_service.dart' as _i376;
import 'host/host_diagnostics.dart' as _i1011;
import 'host/host_runtime_factory.dart' as _i611;
import 'host/portable_pty_launcher.dart' as _i480;
import 'host/pty_launcher.dart' as _i363;
import 'host/ssh_connection_pool.dart' as _i414;
import 'providers/ai/llama_cpp/llama_cpp_connection.dart' as _i38;
import 'providers/ai/llama_cpp/llama_cpp_llm_provider.dart' as _i924;
import 'providers/ai/llm_port.dart' as _i179;
import 'providers/ai/model_catalog.dart' as _i370;
import 'providers/ai/openrouter/openrouter_llm_provider.dart' as _i1042;
import 'src/agent/loop/agent_hub.dart' as _i667;

extension GetItInjectableX on _i174.GetIt {
  // initializes the registration of main-scope dependencies inside of GetIt
  Future<_i174.GetIt> initAgent({
    String? environment,
    _i526.EnvironmentFilter? environmentFilter,
  }) async {
    final gh = _i526.GetItHelper(this, environment, environmentFilter);
    final agentCoreModule = _$AgentCoreModule();
    final draftPersistenceModule = _$DraftPersistenceModule();
    gh.singleton<_i1048.ActiveExecRegistry>(() => _i1048.ActiveExecRegistry());
    gh.singleton<_i378.LiveOutputBus>(() => _i378.LiveOutputBus());
    gh.singleton<_i589.InteractionBroker>(() => _i589.InteractionBroker());
    gh.lazySingleton<_i654.ContextBuilder>(() => _i654.ContextBuilder());
    gh.lazySingleton<_i414.HostKeyConfirmations>(
      () => _i414.HostKeyConfirmations(),
    );
    gh.singleton<_i473.ExecLogStore>(
      () => agentCoreModule.execLogStore(gh<_i342.AppPaths>()),
    );
    gh.singleton<_i221.TurnChangesetStore>(
      () => agentCoreModule.turnChangesetStore(gh<_i342.AppPaths>()),
    );
    await gh.factoryAsync<_i232.AppDatabase>(
      () => agentCoreModule.database(gh<_i342.AppPaths>()),
      preResolve: true,
    );
    gh.lazySingleton<_i363.PtyLauncher>(
      () => const _i480.PortablePtyLauncher(),
    );
    gh.lazySingleton<_i214.TurnChangesetService>(
      () => _i214.TurnChangesetService(gh<_i221.TurnChangesetStore>()),
    );
    gh.lazySingleton<_i453.ScheduledTaskRepository>(
      () => _i453.ScheduledTaskRepository(gh<_i232.AppDatabase>()),
    );
    gh.lazySingleton<_i906.ChatRepository>(
      () => _i906.ChatRepository(gh<_i232.AppDatabase>()),
    );
    gh.lazySingleton<_i7.McpServerRepository>(
      () => _i7.McpServerRepository(gh<_i232.AppDatabase>()),
    );
    gh.lazySingleton<_i215.PolicyProfileRepository>(
      () => _i215.PolicyProfileRepository(gh<_i232.AppDatabase>()),
    );
    gh.lazySingleton<_i518.ProjectRepository>(
      () => _i518.ProjectRepository(gh<_i232.AppDatabase>()),
    );
    gh.lazySingleton<_i896.SavedModelRepository>(
      () => _i896.SavedModelRepository(gh<_i232.AppDatabase>()),
    );
    gh.lazySingleton<_i384.SettingsRepository>(
      () => _i384.SettingsRepository(gh<_i232.AppDatabase>()),
    );
    gh.lazySingleton<_i400.VirtualHostProvisioner>(
      () => _i400.VirtualHostProvisioner(gh<_i232.AppDatabase>()),
    );
    gh.lazySingleton<_i154.SessionStateService>(
      () => _i154.SessionStateService(gh<_i906.ChatRepository>()),
    );
    gh.singleton<_i38.LlamaCppSettingsReader>(
      () => agentCoreModule.llamaCppSettingsReader(
        gh<_i384.SettingsRepository>(),
        gh<_i249.SecretStore>(),
      ),
    );
    gh.lazySingleton<_i262.StartupRecovery>(
      () => _i262.StartupRecovery(
        gh<_i906.ChatRepository>(),
        gh<_i473.ExecLogStore>(),
        gh<_i384.SettingsRepository>(),
      ),
    );
    gh.lazySingleton<_i376.SecurityAuditService>(
      () => _i376.SecurityAuditService(
        gh<_i342.AppPaths>(),
        gh<_i384.SettingsRepository>(),
        gh<_i249.SecretStore>(),
        gh<_i7.McpServerRepository>(),
        gh<_i408.PluginRegistry>(),
      ),
    );
    gh.lazySingleton<_i993.CommandExecutor>(
      () => _i993.CommandExecutor(
        gh<_i473.ExecLogStore>(),
        gh<_i1048.ActiveExecRegistry>(),
        gh<_i378.LiveOutputBus>(),
      ),
    );
    gh.singleton<_i924.LlamaCppLlmProvider>(
      () => agentCoreModule.llamaCppLlmProvider(
        gh<_i38.LlamaCppSettingsReader>(),
      ),
    );
    gh.lazySingleton<_i985.HostRepository>(
      () => _i985.HostRepository(
        gh<_i232.AppDatabase>(),
        gh<_i249.SecretStore>(),
      ),
    );
    gh.lazySingleton<_i1055.WorkspaceContextLoader>(
      () => _i1055.WorkspaceContextLoader(gh<_i384.SettingsRepository>()),
    );
    gh.lazySingleton<_i737.PushService>(
      () => _i737.PushService(
        gh<_i384.SettingsRepository>(),
        gh<_i249.SecretStore>(),
      ),
    );
    gh.singleton<_i1042.OpenRouterLlmProvider>(
      () => agentCoreModule.openRouterLlmProvider(gh<_i249.SecretStore>()),
    );
    gh.lazySingleton<_i290.McpClientManager>(
      () => _i290.McpClientManager(
        gh<_i249.SecretStore>(),
        gh<_i1019.ExternalUrlOpener>(),
      ),
    );
    gh.lazySingleton<_i796.SecurityAuditApi>(
      () => _i967.LocalSecurityAuditApi(gh<_i376.SecurityAuditService>()),
    );
    gh.lazySingleton<_i9.DraftPersistence>(
      () => draftPersistenceModule.draftPersistence(gh<_i906.ChatRepository>()),
    );
    gh.lazySingleton<_i414.SshConnectionPool>(
      () => _i414.SshConnectionPool(
        gh<_i985.HostRepository>(),
        gh<_i249.SecretStore>(),
        gh<_i384.SettingsRepository>(),
        gh<_i414.HostKeyConfirmations>(),
      ),
    );
    gh.singleton<_i179.LlmProvider>(
      () => agentCoreModule.llmProvider(
        gh<_i1042.OpenRouterLlmProvider>(),
        gh<_i924.LlamaCppLlmProvider>(),
      ),
    );
    gh.lazySingleton<_i611.HostRuntimeFactory>(
      () => _i611.HostRuntimeFactory(
        gh<_i414.SshConnectionPool>(),
        gh<_i363.PtyLauncher>(),
        gh<_i400.VirtualHostProvisioner>(),
      ),
    );
    gh.lazySingleton<_i894.ContextCompactor>(
      () => _i894.ContextCompactor(
        gh<_i906.ChatRepository>(),
        gh<_i179.LlmProvider>(),
        gh<_i654.ContextBuilder>(),
      ),
    );
    gh.lazySingleton<_i171.ChatDraftStore>(
      () => _i171.ChatDraftStore(gh<_i9.DraftPersistence>()),
    );
    gh.lazySingleton<_i665.ProjectMemoryService>(
      () => _i665.ProjectMemoryService(
        gh<_i518.ProjectRepository>(),
        gh<_i906.ChatRepository>(),
        gh<_i384.SettingsRepository>(),
        gh<_i179.LlmProvider>(),
      ),
    );
    gh.lazySingleton<_i1011.HostDiagnostics>(
      () => _i1011.HostDiagnostics(
        gh<_i985.HostRepository>(),
        gh<_i249.SecretStore>(),
        gh<_i384.SettingsRepository>(),
        gh<_i611.HostRuntimeFactory>(),
      ),
    );
    gh.lazySingleton<_i475.ProjectLifecycleService>(
      () => _i475.ProjectLifecycleService(
        gh<_i232.AppDatabase>(),
        gh<_i518.ProjectRepository>(),
        gh<_i985.HostRepository>(),
        gh<_i611.HostRuntimeFactory>(),
      ),
    );
    gh.lazySingleton<_i52.PushApi>(
      () => _i979.LocalPushApi(gh<_i737.PushService>()),
    );
    gh.lazySingleton<_i370.ModelCatalogService>(
      () => _i370.ModelCatalogService(
        gh<_i896.SavedModelRepository>(),
        gh<_i179.LlmProvider>(),
      ),
    );
    gh.lazySingleton<_i110.AgentSettingsApi>(
      () => _i825.LocalAgentSettingsApi(
        gh<_i384.SettingsRepository>(),
        gh<_i249.SecretStore>(),
        gh<_i370.ModelCatalogService>(),
      ),
    );
    gh.lazySingleton<_i346.ProjectsApi>(
      () => _i623.LocalProjectsApi(
        gh<_i518.ProjectRepository>(),
        gh<_i906.ChatRepository>(),
        gh<_i985.HostRepository>(),
        gh<_i215.PolicyProfileRepository>(),
        gh<_i384.SettingsRepository>(),
        gh<_i665.ProjectMemoryService>(),
      ),
    );
    gh.lazySingleton<_i907.HostsApi>(
      () => _i915.LocalHostsApi(
        gh<_i985.HostRepository>(),
        gh<_i249.SecretStore>(),
        gh<_i1011.HostDiagnostics>(),
        gh<_i400.VirtualHostProvisioner>(),
      ),
    );
    gh.lazySingleton<_i865.SelfToolHandler>(
      () => _i865.SelfToolHandler(
        gh<_i985.HostRepository>(),
        gh<_i384.SettingsRepository>(),
        gh<_i196.AppearancePort>(),
        gh<_i370.ModelCatalogService>(),
        gh<_i1011.HostDiagnostics>(),
      ),
    );
    gh.lazySingleton<_i780.ToolExecutor>(
      () => _i780.ToolExecutor(
        gh<_i906.ChatRepository>(),
        gh<_i993.CommandExecutor>(),
        gh<_i589.InteractionBroker>(),
        gh<_i154.SessionStateService>(),
        gh<_i1055.WorkspaceContextLoader>(),
        gh<_i865.SelfToolHandler>(),
        gh<_i518.ProjectRepository>(),
        gh<_i214.TurnChangesetService>(),
      ),
    );
    gh.lazySingleton<_i298.PluginService>(
      () => _i298.PluginService(
        gh<_i408.PluginRegistry>(),
        gh<_i384.SettingsRepository>(),
        gh<_i780.ToolExecutor>(),
        gh<_i993.CommandExecutor>(),
        gh<_i249.SecretStore>(),
      ),
    );
    gh.lazySingleton<_i176.McpService>(
      () => _i176.McpService(
        gh<_i7.McpServerRepository>(),
        gh<_i290.McpClientManager>(),
        gh<_i780.ToolExecutor>(),
        gh<_i249.SecretStore>(),
      ),
    );
    gh.singleton<_i667.AgentHub>(
      () => _i667.AgentHub(
        gh<_i906.ChatRepository>(),
        gh<_i384.SettingsRepository>(),
        gh<_i985.HostRepository>(),
        gh<_i611.HostRuntimeFactory>(),
        gh<_i179.LlmProvider>(),
        gh<_i370.ModelCatalogService>(),
        gh<_i654.ContextBuilder>(),
        gh<_i894.ContextCompactor>(),
        gh<_i780.ToolExecutor>(),
        gh<_i176.McpService>(),
        gh<_i298.PluginService>(),
        gh<_i1055.WorkspaceContextLoader>(),
        gh<_i154.SessionStateService>(),
        gh<_i589.InteractionBroker>(),
        gh<_i1048.ActiveExecRegistry>(),
        gh<_i473.ExecLogStore>(),
        gh<_i214.TurnChangesetService>(),
        gh<_i14.AppNotifier>(),
        gh<_i475.ProjectLifecycleService>(),
        gh<_i518.ProjectRepository>(),
        gh<_i215.PolicyProfileRepository>(),
        gh<_i665.ProjectMemoryService>(),
      ),
    );
    gh.lazySingleton<_i778.TaskScheduler>(
      () => _i778.TaskScheduler(
        gh<_i667.AgentHub>(),
        gh<_i453.ScheduledTaskRepository>(),
      ),
    );
    gh.lazySingleton<_i60.PluginApi>(
      () =>
          _i929.LocalPluginApi(gh<_i298.PluginService>(), gh<_i667.AgentHub>()),
    );
    gh.lazySingleton<_i151.McpApi>(
      () => _i300.LocalMcpApi(
        gh<_i7.McpServerRepository>(),
        gh<_i176.McpService>(),
      ),
    );
    gh.lazySingleton<_i269.LocalAgentApi>(
      () => _i269.LocalAgentApi(
        gh<_i667.AgentHub>(),
        gh<_i453.ScheduledTaskRepository>(),
        gh<_i778.TaskScheduler>(),
      ),
    );
    gh.lazySingleton<_i866.LocalChatApi>(
      () => _i866.LocalChatApi(gh<_i667.AgentHub>()),
    );
    return this;
  }
}

class _$AgentCoreModule extends _i200.AgentCoreModule {}

class _$DraftPersistenceModule extends _i855.DraftPersistenceModule {}

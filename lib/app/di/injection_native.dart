import 'package:injectable/injectable.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/di/injection_native.config.dart';
import 'package:probably_works/app/guards/api_key_guard.dart';
import 'package:probably_works/app/profiles/local_agent_apis.dart';
import 'package:pw_agent/agent/api/agent_settings_api.dart';
import 'package:pw_agent/agent/api/hosts_api.dart';
import 'package:pw_agent/agent/api/local_agent_api.dart';
import 'package:pw_agent/agent/api/local_chat_api.dart';
import 'package:pw_agent/agent/api/mcp_api.dart';
import 'package:pw_agent/agent/api/plugin_api.dart';
import 'package:pw_agent/agent/api/projects_api.dart';
import 'package:pw_agent/agent/api/push_api.dart';
import 'package:pw_agent/agent/api/security_audit_api.dart';
import 'package:pw_agent/agent_di.dart' as agent;
import 'package:pw_agent/providers/ai/model_catalog.dart';

export 'package:probably_works/app/di/injection.dart';

/// Регистрация зависимостей клиента и ядра агента.
///
/// `AppPaths` регистрируется до вызова: он нужен модулю агента для открытия БД.
@InjectableInit(preferRelativeImports: true)
Future<void> configureClientDependencies() {
  getIt.init();
  return Future<void>.value();
}

/// Регистрация клиента и embedded-ядра.
Future<void> configureDependencies() async {
  await configureClientDependencies();
  await configureEmbeddedAgentDependencies();
}

/// Регистрирует агентские зависимости и собирает embedded-bundle.
Future<void> configureEmbeddedAgentDependencies() async {
  await agent.configureAgentDependencies();
  // Guard создан раньше агентских зависимостей: подключаем каталог сейчас.
  getIt<ApiKeyGuard>().hasProvider = () =>
      getIt<ModelCatalogService>().hasUsableProvider;
  getIt<LocalAgentApisProvider>().set(
    LocalAgentApis(
      agent: getIt<LocalAgentApi>(),
      chat: getIt<LocalChatApi>(),
      hosts: getIt<HostsApi>(),
      projects: getIt<ProjectsApi>(),
      settings: getIt<AgentSettingsApi>(),
      mcp: getIt<McpApi>(),
      plugins: getIt<PluginApi>(),
      audit: getIt<SecurityAuditApi>(),
      push: getIt<PushApi>(),
    ),
  );
}

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
import 'package:pw_agent/agent/api/agent_api.dart' as _i144;
import 'package:pw_agent/agent/api/chat_api.dart' as _i891;
import 'package:pw_agent/agent/api/hosts_api.dart' as _i359;
import 'package:pw_agent/agent/api/local_agent_api.dart' as _i995;
import 'package:pw_agent/agent/api/local_chat_api.dart' as _i326;
import 'package:pw_agent/agent/plugins/plugin_registry.dart' as _i1065;
import 'package:pw_agent/core/appearance/appearance_port.dart' as _i598;
import 'package:pw_agent/core/config/app_paths.dart' as _i515;
import 'package:pw_agent/core/data/mcp_server_repository.dart' as _i358;
import 'package:pw_agent/core/data/settings_repository.dart' as _i370;
import 'package:pw_agent/core/notify/app_notifier.dart' as _i641;
import 'package:pw_agent/core/platform/external_url_opener.dart' as _i1054;
import 'package:pw_agent/core/security/secret_store.dart' as _i564;

import '../../core/notify/app_notifier_plugin.dart' as _i238;
import '../../core/platform/url_launcher_opener.dart' as _i224;
import '../../core/security/secret_store_plugin.dart' as _i1071;
import '../../core/security/security_audit_service.dart' as _i388;
import '../guards/api_key_guard.dart' as _i519;
import '../locale/appearance_port_adapter.dart' as _i395;
import '../locale/locale_controller.dart' as _i675;
import '../profiles/profile_service.dart' as _i740;
import '../router/app_router.dart' as _i81;
import '../theme/theme_controller.dart' as _i699;
import 'core_module.dart' as _i154;

extension GetItInjectableX on _i174.GetIt {
  // initializes the registration of main-scope dependencies inside of GetIt
  _i174.GetIt init({
    String? environment,
    _i526.EnvironmentFilter? environmentFilter,
  }) {
    final gh = _i526.GetItHelper(this, environment, environmentFilter);
    final coreModule = _$CoreModule();
    gh.singleton<_i558.FlutterSecureStorage>(() => coreModule.secureStorage);
    gh.singleton<_i1065.PluginRegistry>(() => coreModule.pluginRegistry());
    gh.singleton<_i675.LocaleController>(() => _i675.LocaleController());
    gh.singleton<_i699.ThemeController>(() => _i699.ThemeController());
    gh.singleton<_i144.AgentApi>(
      () => coreModule.agentApi(gh<_i995.LocalAgentApi>()),
    );
    gh.singleton<_i891.ChatApi>(
      () => coreModule.chatApi(gh<_i326.LocalChatApi>()),
    );
    gh.lazySingleton<_i564.SecretStore>(
      () => _i1071.FlutterSecretStore(gh<_i558.FlutterSecureStorage>()),
    );
    gh.lazySingleton<_i519.ApiKeyGuard>(
      () => _i519.ApiKeyGuard(gh<_i564.SecretStore>()),
    );
    gh.lazySingleton<_i388.SecurityAuditService>(
      () => _i388.SecurityAuditService(
        gh<_i515.AppPaths>(),
        gh<_i370.SettingsRepository>(),
        gh<_i564.SecretStore>(),
        gh<_i358.McpServerRepository>(),
        gh<_i1065.PluginRegistry>(),
      ),
    );
    gh.lazySingleton<_i1054.ExternalUrlOpener>(
      () => const _i224.UrlLauncherOpener(),
    );
    gh.lazySingleton<_i598.AppearancePort>(
      () => _i395.ClientAppearancePort(
        gh<_i675.LocaleController>(),
        gh<_i699.ThemeController>(),
      ),
    );
    gh.singleton<_i81.AppRouter>(
      () => coreModule.appRouter(gh<_i519.ApiKeyGuard>()),
    );
    gh.lazySingleton<_i641.AppNotifier>(
      () => _i238.PluginAppNotifier(gh<_i675.LocaleController>()),
    );
    gh.lazySingleton<_i740.ProfileService>(
      () => _i740.ProfileService(
        gh<_i370.SettingsRepository>(),
        gh<_i564.SecretStore>(),
        gh<_i144.AgentApi>(),
        gh<_i891.ChatApi>(),
        gh<_i359.HostsApi>(),
      ),
    );
    return this;
  }
}

class _$CoreModule extends _i154.CoreModule {}

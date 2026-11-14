import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:plugin_api_ui/plugin_api_ui.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/guards/api_key_guard.dart';
import 'package:probably_works/app/locale/locale_controller.dart';
import 'package:probably_works/app/profiles/local_agent_apis.dart';
import 'package:probably_works/app/profiles/profile_service.dart';
import 'package:probably_works/app/router/app_router.dart';
import 'package:probably_works/app/shortcuts/keybinding_service.dart';
import 'package:probably_works/app/theme/theme_controller.dart';
import 'package:probably_works/core/notify/web_app_notifier.dart';
import 'package:probably_works/core/platform/client_info.dart';
import 'package:probably_works/core/security/secret_store_plugin.dart';
import 'package:probably_works/core/settings/client_settings.dart';
import 'package:probably_works/features/chats/presentation/bloc/chat_list_cubit.dart';
import 'package:probably_works/features/palette/domain/command_plugin_registry.dart';
import 'package:probably_works/features/workspace/presentation/bloc/sidebar_cubit.dart';
import 'package:pw_agent/agent/exec/live_output_bus.dart';
import 'package:pw_agent/core/data/chat_draft_store.dart';
import 'package:pw_agent/core/notify/app_notifier.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Запуск web-клиента: только удалённые профили, без БД и локального агента.
Future<void> bootstrapWeb() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = SharedPreferencesClientSettings(SharedPreferencesAsync());
  final secrets = FlutterSecretStore(const FlutterSecureStorage());
  final local = LocalAgentApisProvider();
  final profiles = ProfileService(
    settings,
    secrets,
    local,
    const ClientInfo.fallback(),
    const WebAppNotifier(),
    includeLocal: false,
  );
  final locale = LocaleController();
  final theme = ThemeController();
  final keybindings = KeybindingService(settings);
  final sidebarWidth = await SidebarCubit.loadWidth(settings);

  getIt
    ..registerSingleton<ClientSettings>(settings)
    ..registerSingleton<SecretStore>(secrets)
    ..registerSingleton<LocalAgentApisProvider>(local)
    ..registerSingleton<ProfileService>(profiles)
    ..registerSingleton<AppNotifier>(const WebAppNotifier())
    ..registerSingleton<ChatDraftStore>(ChatDraftStore.unbound())
    ..registerSingleton<LiveOutputBus>(LiveOutputBus())
    ..registerSingleton<StartupHosts>(const StartupHosts([]))
    ..registerSingleton<SidebarStartupWidth>(SidebarStartupWidth(sidebarWidth))
    ..registerSingleton<LocaleController>(locale)
    ..registerSingleton<ThemeController>(theme)
    ..registerSingleton<KeybindingService>(keybindings)
    ..registerSingleton<CommandPluginRegistry>(const CommandPluginRegistry([]))
    ..registerSingleton<PluginUiRegistry>(const PluginUiRegistry([]));

  await profiles.load();
  await keybindings.load();
  final language = await settings.read(ClientSettingsKeys.language);
  locale.apply(language);
  final themeMode = await settings.read(ClientSettingsKeys.themeMode);
  theme.apply(ThemeController.modeFrom(themeMode));

  final guard = ApiKeyGuard(profiles, local);
  getIt
    ..registerSingleton<ApiKeyGuard>(guard)
    ..registerSingleton<AppRouter>(AppRouter(apiKeyGuard: guard));
}

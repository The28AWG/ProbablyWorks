import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:injectable/injectable.dart';
import 'package:plugin_api_ui/plugin_api_ui.dart';
import 'package:plugin_declarative_commands/declarative_commands_plugin.dart';
import 'package:plugin_declarative_commands_core/declarative_commands_plugin.dart'
    as commands_core;
import 'package:plugin_declarative_http/declarative_http_plugin.dart';
import 'package:plugin_declarative_http_core/declarative_http_plugin.dart'
    as http_core;
import 'package:probably_works/app/guards/api_key_guard.dart';
import 'package:probably_works/app/profiles/local_agent_apis.dart';
import 'package:probably_works/app/profiles/profile_service.dart';
import 'package:probably_works/app/router/app_router.dart';
import 'package:probably_works/app/shortcuts/keybinding_service.dart';
import 'package:probably_works/core/settings/client_settings.dart';
import 'package:probably_works/features/palette/domain/command_plugin_registry.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/chat_api.dart';
import 'package:pw_agent/agent/plugins/plugin_registry.dart';

/// Внешние ресурсы Flutter-клиента: плагины, уведомления, браузер и тема.
@module
abstract class CoreModule {
  @singleton
  FlutterSecureStorage get secureStorage => const FlutterSecureStorage();

  @lazySingleton
  AppRouter appRouter(ApiKeyGuard guard) => AppRouter(apiKeyGuard: guard);

  /// Guard проверяет наличие настроенного провайдера. Сам каталог
  /// подключается после регистрации агентских зависимостей.
  @lazySingleton
  ApiKeyGuard apiKeyGuard(
    ProfileService profiles,
    LocalAgentApisProvider local,
  ) => ApiKeyGuard(profiles, local);

  /// Backend локального профиля выбирает bootstrap.
  @lazySingleton
  LocalAgentApisProvider localAgentApisProvider() => LocalAgentApisProvider();

  @lazySingleton
  AgentApi agentApi(LocalAgentApisProvider local) => local.value.agent;

  @lazySingleton
  ChatApi chatApi(LocalAgentApisProvider local) => local.value.chat;

  @singleton
  KeybindingService keybindingService(ClientSettings settings) =>
      KeybindingService(settings);

  @singleton
  PluginRegistry pluginRegistry() => const PluginRegistry([
    commands_core.DeclarativeCommandsPlugin(),
    http_core.DeclarativeHttpPlugin(),
  ]);

  @singleton
  CommandPluginRegistry commandPluginRegistry() =>
      const CommandPluginRegistry([]);

  @singleton
  PluginUiRegistry pluginUiRegistry() => const PluginUiRegistry([
    DeclarativeCommandsPluginUi(),
    DeclarativeHttpPluginUi(),
  ]);
}

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:injectable/injectable.dart';
import 'package:plugin_declarative_commands/declarative_commands_plugin.dart';
import 'package:plugin_declarative_http/declarative_http_plugin.dart';
import 'package:probably_works/app/guards/api_key_guard.dart';
import 'package:probably_works/app/router/app_router.dart';
import 'package:pw_agent/agent/plugins/plugin_registry.dart';

/// Внешние ресурсы Flutter-клиента: плагины, уведомления, браузер и тема.
@module
abstract class CoreModule {
  @singleton
  FlutterSecureStorage get secureStorage => const FlutterSecureStorage();

  @singleton
  AppRouter appRouter(ApiKeyGuard guard) => AppRouter(apiKeyGuard: guard);

  /// Плагины компилируются в клиент. Демон регистрирует свой список.
  @singleton
  PluginRegistry pluginRegistry() => const PluginRegistry([
    DeclarativeCommandsPlugin(),
    DeclarativeHttpPlugin(),
  ]);
}

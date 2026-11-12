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
import 'package:probably_works/app/router/app_router.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/agent_settings_api.dart';
import 'package:pw_agent/agent/api/chat_api.dart';
import 'package:pw_agent/agent/api/hosts_api.dart';
import 'package:pw_agent/agent/api/local_agent_api.dart';
import 'package:pw_agent/agent/api/local_chat_api.dart';
import 'package:pw_agent/agent/api/mcp_api.dart';
import 'package:pw_agent/agent/api/plugin_api.dart';
import 'package:pw_agent/agent/api/projects_api.dart';
import 'package:pw_agent/agent/api/push_api.dart';
import 'package:pw_agent/agent/api/security_audit_api.dart';
import 'package:pw_agent/agent/plugins/plugin_registry.dart';

/// Внешние ресурсы Flutter-клиента: плагины, уведомления, браузер и тема.
@module
abstract class CoreModule {
  @singleton
  FlutterSecureStorage get secureStorage => const FlutterSecureStorage();

  @lazySingleton
  AppRouter appRouter(ApiKeyGuard guard) => AppRouter(apiKeyGuard: guard);

  /// API локального профиля. Позже daemon-режим подменит этот bundle
  /// реализацией RemoteAgentApi на localhost.
  @lazySingleton
  LocalAgentApis localAgentApis(
    LocalAgentApi agent,
    LocalChatApi chat,
    HostsApi hosts,
    ProjectsApi projects,
    AgentSettingsApi settings,
    McpApi mcp,
    PluginApi plugins,
    SecurityAuditApi audit,
    PushApi push,
  ) => LocalAgentApis(
    agent: agent,
    chat: chat,
    hosts: hosts,
    projects: projects,
    settings: settings,
    mcp: mcp,
    plugins: plugins,
    audit: audit,
    push: push,
  );

  @lazySingleton
  AgentApi agentApi(LocalAgentApis local) => local.agent;

  @lazySingleton
  ChatApi chatApi(LocalAgentApis local) => local.chat;

  @singleton
  PluginRegistry pluginRegistry() => const PluginRegistry([
    commands_core.DeclarativeCommandsPlugin(),
    http_core.DeclarativeHttpPlugin(),
  ]);

  @singleton
  PluginUiRegistry pluginUiRegistry() => const PluginUiRegistry([
    DeclarativeCommandsPluginUi(),
    DeclarativeHttpPluginUi(),
  ]);
}

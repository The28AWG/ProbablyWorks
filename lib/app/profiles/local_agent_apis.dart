import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/agent_settings_api.dart';
import 'package:pw_agent/agent/api/chat_api.dart';
import 'package:pw_agent/agent/api/hosts_api.dart';
import 'package:pw_agent/agent/api/mcp_api.dart';
import 'package:pw_agent/agent/api/plugin_api.dart';
import 'package:pw_agent/agent/api/projects_api.dart';
import 'package:pw_agent/agent/api/push_api.dart';
import 'package:pw_agent/agent/api/security_audit_api.dart';

/// Режим, в котором работает локальный профиль.
enum LocalRuntimeMode { embedded, localDaemon }

/// Набор API локального профиля.
///
/// Embedded-режим собирает его из локальных адаптеров, daemon-режим — из
/// `RemoteAgentApi` на localhost. UI и `ProfileService` видят только интерфейсы.
final class LocalAgentApis {
  const LocalAgentApis({
    required this.agent,
    required this.chat,
    required this.hosts,
    required this.projects,
    required this.settings,
    required this.mcp,
    required this.plugins,
    required this.audit,
    required this.push,
    this.mode = LocalRuntimeMode.embedded,
  });

  final AgentApi agent;
  final ChatApi chat;
  final HostsApi hosts;
  final ProjectsApi projects;
  final AgentSettingsApi settings;
  final McpApi mcp;
  final PluginApi plugins;
  final SecurityAuditApi audit;
  final PushApi push;
  final LocalRuntimeMode mode;
}

/// Позволяет выбрать backend локального профиля до первого обращения UI.
///
/// Bootstrap заполняет provider либо embedded-адаптерами, либо remote-клиентом
/// локального демона.
final class LocalAgentApisProvider {
  LocalAgentApis? _value;

  LocalAgentApis get value {
    final value = _value;
    if (value == null) {
      throw StateError('LocalAgentApis is not configured');
    }
    return value;
  }

  LocalRuntimeMode? get modeOrNull => _value?.mode;

  void set(LocalAgentApis value) {
    _value = value;
  }
}

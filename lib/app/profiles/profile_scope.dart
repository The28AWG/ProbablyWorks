// ignore_for_file: avoid-returning-widgets, inherited scope lookup by design
import 'package:flutter/widgets.dart';
import 'package:probably_works/app/profiles/agent_profile.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/agent_settings_api.dart';
import 'package:pw_agent/agent/api/chat_api.dart';
import 'package:pw_agent/agent/api/hosts_api.dart';
import 'package:pw_agent/agent/api/projects_api.dart';

/// Профиль, привязанный к ветке маршрута `/a/<profileId>/...`.
///
/// Ветка сама создаёт Cubit-ы и передаёт им эти API, поэтому смена профиля —
/// это переход на другой маршрут, а не мутация глобального состояния.
class ProfileScope extends InheritedWidget {
  const ProfileScope({
    required this.profile,
    required this.agentApi,
    required this.chatApi,
    required this.hostsApi,
    required this.projectsApi,
    required this.settingsApi,
    required super.child,
    super.key,
  });

  final AgentProfile profile;
  final AgentApi agentApi;
  final ChatApi chatApi;
  final HostsApi hostsApi;
  final ProjectsApi projectsApi;
  final AgentSettingsApi settingsApi;

  static ProfileScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ProfileScope>();

  static ProfileScope of(BuildContext context) {
    final scope = maybeOf(context);
    assert(scope != null, 'ProfileScope is missing');
    return scope!;
  }

  @override
  bool updateShouldNotify(ProfileScope oldWidget) =>
      profile.id != oldWidget.profile.id ||
      agentApi != oldWidget.agentApi ||
      chatApi != oldWidget.chatApi ||
      hostsApi != oldWidget.hostsApi ||
      projectsApi != oldWidget.projectsApi ||
      settingsApi != oldWidget.settingsApi;
}

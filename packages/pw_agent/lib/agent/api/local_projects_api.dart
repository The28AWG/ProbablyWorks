import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/api/projects_api.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/project.dart';
import 'package:pw_agent/agent/policy/security_profile.dart';
import 'package:pw_agent/core/data/chat_repository.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/data/policy_profile_repository.dart';
import 'package:pw_agent/core/data/project_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/domain/host.dart';

/// Локальная вкладка проектов: все данные из БД.
@LazySingleton(as: ProjectsApi)
final class LocalProjectsApi implements ProjectsApi {
  LocalProjectsApi(
    this._projects,
    this._chats,
    this._hosts,
    this._policies,
    this._settings,
  );

  final ProjectRepository _projects;
  final ChatRepository _chats;
  final HostRepository _hosts;
  final PolicyProfileRepository _policies;
  final SettingsRepository _settings;

  @override
  Stream<List<Project>> watchProjects() => _projects.watchAll();

  @override
  Stream<Map<String, int>> watchChatCounts() => _projects.watchChatCounts();

  @override
  Stream<List<Host>> watchHosts() => _hosts.watchAll();

  @override
  Stream<List<PolicyProfile>> watchPolicyProfiles() => _policies.watchAll();

  @override
  Stream<List<ProjectFact>> watchFacts(String projectId) =>
      _projects.watchFacts(projectId);

  @override
  Stream<List<ProjectSkill>> watchSkills(String projectId) =>
      _projects.watchSkills(projectId);

  @override
  Stream<List<Chat>> watchProjectChats(String projectId) =>
      _chats.watchByProject(projectId);

  @override
  Future<void> saveProject(Project project) => _projects.save(project);

  @override
  Future<void> deleteProject(String id) => _projects.delete(id);

  @override
  Future<void> setTrustAgentsMd(String projectId, bool trusted) =>
      _projects.setTrustAgentsMd(projectId, trusted);

  @override
  Future<void> setSkillTrusted(
    String projectId,
    String name, {
    required bool trusted,
  }) => _projects.setSkillTrusted(projectId, name, trusted: trusted);

  @override
  Future<void> trustWorkspace(String projectId) =>
      _projects.trustWorkspace(projectId);

  @override
  Future<void> addFact(ProjectFact fact) => _projects.addFact(fact);

  @override
  Future<void> deleteFact(String projectId, String factId) =>
      _projects.deleteFact(factId);

  @override
  Future<void> savePolicyProfile(PolicyProfile profile) =>
      _policies.save(profile);

  @override
  Future<void> deletePolicyProfile(String id) => _policies.delete(id);

  @override
  Future<List<String>> readDenylist() => _settings.readDenylist();

  @override
  Future<SecurityProfile> readSecurityProfile() =>
      _settings.readSecurityProfile();
}

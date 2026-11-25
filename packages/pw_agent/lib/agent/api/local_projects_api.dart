import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/api/projects_api.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/project.dart';
import 'package:pw_agent/agent/domain/workspace_entry.dart';
import 'package:pw_agent/agent/memory/project_memory_service.dart';
import 'package:pw_agent/agent/policy/security_profile.dart';
import 'package:pw_agent/agent/project/project_lifecycle.dart';
import 'package:pw_agent/agent/state/domain_change_bus.dart';
import 'package:pw_agent/agent/state/shared_state.dart';
import 'package:pw_agent/agent/workspace/mention_search_service.dart';
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
    this._memory,
    this._lifecycle,
    this._mentions, [
    this._changes,
  ]);

  final ProjectRepository _projects;
  final ChatRepository _chats;
  final HostRepository _hosts;
  final PolicyProfileRepository _policies;
  final SettingsRepository _settings;
  final ProjectMemoryService _memory;
  final ProjectLifecycleService _lifecycle;
  final MentionSearchService _mentions;
  final DomainChangeBus? _changes;

  @override
  Stream<List<Project>> watchProjects() => _projects.watchAll();

  @override
  Stream<Map<String, int>> watchChatCounts() => _projects.watchChatCounts();

  @override
  Stream<List<Host>> watchHosts() => _hosts.watchAll();

  @override
  Stream<List<PolicyProfile>> watchPolicyProfiles() => _policies.watchAll();

  @override
  Stream<ProjectMemory?> watchMemory(String projectId) =>
      _projects.watchMemory(projectId);

  @override
  Stream<List<ProjectSkill>> watchSkills(String projectId) =>
      _projects.watchSkills(projectId);

  @override
  Stream<List<Chat>> watchProjectChats(String projectId) =>
      _chats.watchByProject(projectId);

  @override
  Future<Project?> find({required String hostId, required String workspace}) =>
      _lifecycle.find(hostId: hostId, workspace: workspace);

  @override
  Future<List<WorkspaceEntry>> searchMentions(String projectId, String query) =>
      _mentions.search(projectId, query);

  @override
  Future<void> saveProject(Project project, {int? expectedRevision}) async {
    await _projects.save(project, expectedRevision: expectedRevision);
    _changes?.publish(SharedResource.projects);
  }

  @override
  Future<void> deleteProject(String id) async {
    await _projects.delete(id);
    _changes?.publish(SharedResource.projects);
  }

  @override
  Future<void> setTrustAgentsMd(String projectId, bool trusted) async {
    await _projects.setTrustAgentsMd(projectId, trusted);
    _changes?.publish(SharedResource.projects);
  }

  @override
  Future<void> setSkillTrusted(
    String projectId,
    String name, {
    required bool trusted,
  }) async {
    await _projects.setSkillTrusted(projectId, name, trusted: trusted);
    _changes?.publish(SharedResource.projects);
  }

  @override
  Future<void> trustWorkspace(String projectId) async {
    await _projects.trustWorkspace(projectId);
    _changes?.publish(SharedResource.projects);
  }

  @override
  Future<void> reviseMemory(String projectId, String instruction) async {
    final project = await _projects.byId(projectId);
    if (project == null) {
      throw StateError('project not found: $projectId');
    }
    await _memory.revise(project: project, instruction: instruction);
    _changes?.publish(SharedResource.projects);
  }

  @override
  Future<void> savePolicyProfile(PolicyProfile profile) async {
    await _policies.save(profile);
    _changes?.publish(SharedResource.projects);
  }

  @override
  Future<void> deletePolicyProfile(String id) async {
    await _policies.delete(id);
    _changes?.publish(SharedResource.projects);
  }

  @override
  Future<List<String>> readDenylist() => _settings.readDenylist();

  @override
  Future<SecurityProfile> readSecurityProfile() =>
      _settings.readSecurityProfile();
}

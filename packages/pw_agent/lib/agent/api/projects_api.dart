import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/project.dart';
import 'package:pw_agent/agent/policy/security_profile.dart';
import 'package:pw_agent/core/domain/host.dart';

/// Данные и операции вкладки проектов.
///
/// Локальная реализация читает БД напрямую, удалённая — через API.
abstract interface class ProjectsApi {
  Stream<List<Project>> watchProjects();
  Stream<Map<String, int>> watchChatCounts();
  Stream<List<Host>> watchHosts();
  Stream<List<PolicyProfile>> watchPolicyProfiles();

  /// Саммари проекта. Null — память ещё не накоплена.
  Stream<ProjectMemory?> watchMemory(String projectId);
  Stream<List<ProjectSkill>> watchSkills(String projectId);
  Stream<List<Chat>> watchProjectChats(String projectId);

  Future<void> saveProject(Project project);
  Future<void> deleteProject(String id);
  Future<void> setTrustAgentsMd(String projectId, bool trusted);
  Future<void> setSkillTrusted(
    String projectId,
    String name, {
    required bool trusted,
  });
  Future<void> trustWorkspace(String projectId);

  /// Просит memory-цикл поправить саммари по инструкции пользователя.
  /// Изменения применяются только через `apply_patch` и проверяются на лимит.
  Future<void> reviseMemory(String projectId, String instruction);

  Future<void> savePolicyProfile(PolicyProfile profile);
  Future<void> deletePolicyProfile(String id);

  Future<List<String>> readDenylist();
  Future<SecurityProfile> readSecurityProfile();
}

import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/project.dart';
import 'package:pw_agent/agent/domain/workspace_entry.dart';
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

  /// Существующий проект для пары «хост + папка», без создания.
  Future<Project?> find({required String hostId, required String workspace});

  /// Поиск файлов и каталогов проекта для упоминаний. Глубину, лимиты и
  /// таймауты выбирает агент, а не клиент.
  Future<List<WorkspaceEntry>> searchMentions(String projectId, String query);

  /// Сохраняет свойства проекта.
  ///
  /// [expectedRevision] — `revision` снимка, с которого открыта форма. При
  /// несовпадении реализация бросает `409 project_conflict` до записи. Без
  /// него (служебная запись, старый клиент) ревизия не проверяется.
  Future<void> saveProject(Project project, {int? expectedRevision});
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

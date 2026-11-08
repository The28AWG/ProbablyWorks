import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:probably_works/agent/domain/project.dart';
import 'package:probably_works/core/data/host_repository.dart';
import 'package:probably_works/core/data/project_repository.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:uuid/uuid.dart';

/// Состояние раздела проектов: активные и архивные проекты, хосты и число чатов.
class ProjectsState extends Equatable {
  const ProjectsState({
    this.projects = const [],
    this.hosts = const [],
    this.chatCounts = const {},
    this.loading = true,
  });

  final List<Project> projects;
  final List<Host> hosts;

  /// Число чатов по проектам. Проект без чатов показывается как архивный.
  final Map<String, int> chatCounts;
  final bool loading;

  /// Активные проекты: в них есть хотя бы один чат.
  List<Project> get active => [
    for (final project in projects)
      if (!project.isArchived) project,
  ];

  /// Архивные проекты: чатов нет, они удалятся через неделю.
  List<Project> get archived => [
    for (final project in projects)
      if (project.isArchived) project,
  ];

  int chatCountOf(Project project) => chatCounts[project.id] ?? 0;

  Host? hostOf(Project project) =>
      hosts.where((host) => host.id == project.hostId).firstOrNull;

  ProjectsState copyWith({
    List<Project>? projects,
    List<Host>? hosts,
    Map<String, int>? chatCounts,
    bool? loading,
  }) => ProjectsState(
    projects: projects ?? this.projects,
    hosts: hosts ?? this.hosts,
    chatCounts: chatCounts ?? this.chatCounts,
    loading: loading ?? this.loading,
  );

  @override
  List<Object?> get props => [projects, hosts, chatCounts, loading];
}

/// Раздел проектов. Проекты не создаются здесь: они появляются из чатов, а этот блок
/// показывает их список, переименовывает, меняет доверие и общую память.
class ProjectsCubit extends Cubit<ProjectsState> {
  ProjectsCubit(this._projects, this._hosts) : super(const ProjectsState()) {
    _projectsSub = _projects.watchAll().listen(
      (projects) => emit(state.copyWith(projects: projects, loading: false)),
    );
    _hostsSub = _hosts.watchAll().listen(
      (hosts) => emit(state.copyWith(hosts: hosts)),
    );
    _countsSub = _projects.watchChatCounts().listen(
      (counts) => emit(state.copyWith(chatCounts: counts)),
    );
  }

  final ProjectRepository _projects;
  final HostRepository _hosts;

  static const _uuid = Uuid();

  late final StreamSubscription<List<Project>> _projectsSub;
  late final StreamSubscription<List<Host>> _hostsSub;
  late final StreamSubscription<Map<String, int>> _countsSub;

  /// Имя проекта видно в списке и в чипе чата. Хост и папка — идентичность, их не меняем.
  Future<void> rename(Project project, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == project.name) return;
    await _projects.save(project.copyWith(name: trimmed));
  }

  /// Профиль политики проекта. Null — используется глобальный профиль из настроек.
  Future<void> setPolicyProfile(Project project, String? profileId) =>
      _projects.save(
        project.copyWith(
          policyProfileId: profileId,
          clearPolicyProfile: profileId == null,
        ),
      );

  /// Доверие к AGENTS.md. Skills доверяются отдельно, по одному.
  Future<void> setAgentsTrust(Project project, {required bool trusted}) =>
      _projects.setTrustAgentsMd(project.id, trusted);

  Future<void> setSkillTrusted(
    String projectId,
    String name, {
    required bool trusted,
  }) => _projects.setSkillTrusted(projectId, name, trusted: trusted);

  Future<void> addFact(Project project, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    await _projects.addFact(
      ProjectFact(
        id: _uuid.v4(),
        projectId: project.id,
        text: trimmed,
        createdAt: DateTime.now(),
      ),
    );
  }

  Future<void> deleteFact(String id) => _projects.deleteFact(id);

  /// Окончательное удаление архивного проекта. Активный проект удалять нельзя:
  /// сначала должны исчезнуть его чаты, иначе чаты остались бы без проекта.
  Future<void> deleteProject(Project project) async {
    if (!project.isArchived || state.chatCountOf(project) > 0) return;
    await _projects.delete(project.id);
  }

  @override
  Future<void> close() async {
    await _projectsSub.cancel();
    await _hostsSub.cancel();
    await _countsSub.cancel();
    return super.close();
  }
}

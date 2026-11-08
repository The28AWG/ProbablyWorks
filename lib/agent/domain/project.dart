import 'package:equatable/equatable.dart';
import 'package:probably_works/agent/policy/security_profile.dart';

/// Проект: пара «хост + рабочая папка», к которой привязаны чаты.
///
/// Хост и папка — идентичность проекта, поэтому у них нет изменения: смена любого из них
/// переводит чат в другой проект. Имя, факты, доверие к skills и профиль политики — свойства проекта.
class Project extends Equatable {
  const Project({
    required this.id,
    required this.hostId,
    required this.name,
    required this.workspace,
    required this.workspaceKey,
    required this.createdAt,
    required this.updatedAt,
    this.policyProfileId,
    this.trustAgentsMd = false,
    this.skillsInitialized = false,
    this.archivedAt,
  });

  final String id;
  final String hostId;
  final String name;

  /// Путь как его видит пользователь (может содержать `~`).
  final String workspace;

  /// Канонический путь, по которому проект находится. Уникален вместе с [hostId].
  final String workspaceKey;
  final String? policyProfileId;
  final bool trustAgentsMd;
  final bool skillsInitialized;
  final DateTime? archivedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isArchived => archivedAt != null;

  Project copyWith({
    String? id,
    String? hostId,
    String? name,
    String? workspace,
    String? workspaceKey,
    String? policyProfileId,
    bool clearPolicyProfile = false,
    bool? trustAgentsMd,
    bool? skillsInitialized,
    DateTime? archivedAt,
    bool clearArchivedAt = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => Project(
    id: id ?? this.id,
    hostId: hostId ?? this.hostId,
    name: name ?? this.name,
    workspace: workspace ?? this.workspace,
    workspaceKey: workspaceKey ?? this.workspaceKey,
    policyProfileId: clearPolicyProfile
        ? null
        : (policyProfileId ?? this.policyProfileId),
    trustAgentsMd: trustAgentsMd ?? this.trustAgentsMd,
    skillsInitialized: skillsInitialized ?? this.skillsInitialized,
    archivedAt: clearArchivedAt ? null : (archivedAt ?? this.archivedAt),
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? DateTime.now(),
  );

  @override
  List<Object?> get props => [
    id,
    hostId,
    name,
    workspace,
    workspaceKey,
    policyProfileId,
    trustAgentsMd,
    skillsInitialized,
    archivedAt,
    createdAt,
    updatedAt,
  ];
}

/// Факт проекта. Читается каждым новым чатом и меняется только через подтверждение.
class ProjectFact extends Equatable {
  const ProjectFact({
    required this.id,
    required this.projectId,
    required this.text,
    required this.createdAt,
  });

  final String id;
  final String projectId;
  final String text;
  final DateTime createdAt;

  @override
  List<Object?> get props => [id, projectId, text, createdAt];
}

/// Доверие к отдельному skill проекта.
class ProjectSkill extends Equatable {
  const ProjectSkill({required this.name, required this.trusted});

  final String name;
  final bool trusted;

  @override
  List<Object?> get props => [name, trusted];
}

/// Именованный профиль политики проекта.
class PolicyProfile extends Equatable {
  const PolicyProfile({
    required this.id,
    required this.name,
    required this.profile,
    required this.createdAt,
    required this.updatedAt,
    this.description,
  });

  final String id;
  final String name;
  final String? description;
  final SecurityProfile profile;
  final DateTime createdAt;
  final DateTime updatedAt;

  PolicyProfile copyWith({
    String? id,
    String? name,
    String? description,
    bool clearDescription = false,
    SecurityProfile? profile,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => PolicyProfile(
    id: id ?? this.id,
    name: name ?? this.name,
    description: clearDescription ? null : (description ?? this.description),
    profile: profile ?? this.profile,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  @override
  List<Object?> get props => [
    id,
    name,
    description,
    profile,
    createdAt,
    updatedAt,
  ];
}

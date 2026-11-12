import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/domain/project.dart';
import 'package:pw_agent/core/db/app_database.dart';

/// Проекты, их факты и доверие к skills. Чаты ссылаются на проект по `project_id`.
///
/// Репозиторий не решает жизненный цикл: создание, перенос чата и архив — задача
/// [ProjectLifecycleService]. Здесь только чтение и запись строк.
@lazySingleton
class ProjectRepository {
  ProjectRepository(this._db);

  final AppDatabase _db;

  $ProjectsTable get _projects => _db.projects;
  $ProjectFactsTable get _facts => _db.projectFacts;
  $ProjectSkillsTable get _skills => _db.projectSkills;
  $ChatsTable get _chats => _db.chats;

  /// Все проекты: активные сверху, архивные ниже. Список чатов и оболочка показывают оба раздела.
  Stream<List<Project>> watchAll() =>
      (_db.select(_projects)..orderBy([
            (t) => OrderingTerm.asc(t.archivedAt.isNull()),
            (t) => OrderingTerm.desc(t.updatedAt),
          ]))
          .watch()
          .map((rows) => rows.map(_project).toList());

  Future<List<Project>> all() async =>
      (await (_db.select(_projects)..orderBy([
                (t) => OrderingTerm.asc(t.archivedAt.isNull()),
                (t) => OrderingTerm.desc(t.updatedAt),
              ]))
              .get())
          .map(_project)
          .toList();

  Future<Project?> byId(String id) async {
    final row = await (_db.select(
      _projects,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _project(row);
  }

  Future<Project?> find(String hostId, String workspaceKey) async {
    final row =
        await (_db.select(_projects)..where(
              (t) =>
                  t.hostId.equals(hostId) & t.workspaceKey.equals(workspaceKey),
            ))
            .getSingleOrNull();
    return row == null ? null : _project(row);
  }

  /// Проект чата. Null — чат ещё не привязан (миграция или незаписанный чат).
  Future<Project?> forChat(String chatId) async {
    final query = _db.select(_projects).join([
      innerJoin(_chats, _chats.projectId.equalsExp(_projects.id)),
    ])..where(_chats.id.equals(chatId));
    final row = await query.getSingleOrNull();
    return row == null ? null : _project(row.readTable(_projects));
  }

  Future<void> save(Project project) => _db
      .into(_projects)
      .insertOnConflictUpdate(
        ProjectsCompanion.insert(
          id: project.id,
          hostId: project.hostId,
          name: project.name,
          workspace: project.workspace,
          workspaceKey: project.workspaceKey,
          policyProfileId: Value(project.policyProfileId),
          trustAgentsMd: Value(project.trustAgentsMd),
          skillsInitialized: Value(project.skillsInitialized),
          archivedAt: Value(project.archivedAt),
          createdAt: project.createdAt,
          updatedAt: project.updatedAt,
        ),
      );

  Future<void> delete(String id) =>
      (_db.delete(_projects)..where((t) => t.id.equals(id))).go();

  /// Количество чатов по проектам: нужно, чтобы отличить активный проект от архивного.
  Stream<Map<String, int>> watchChatCounts() {
    final count = _chats.id.count();
    return (_db.selectOnly(_chats)
          ..addColumns([_chats.projectId, count])
          ..groupBy([_chats.projectId]))
        .watch()
        .map(
          (rows) => {
            for (final row in rows)
              ?row.read(_chats.projectId): row.read(count) ?? 0,
          },
        );
  }

  Future<int> chatCount(String projectId) async {
    final count = _chats.id.count();
    final row =
        await (_db.selectOnly(_chats)
              ..addColumns([count])
              ..where(_chats.projectId.equals(projectId)))
            .getSingle();
    return row.read(count) ?? 0;
  }

  // ---- facts -------------------------------------------------------------

  Future<List<ProjectFact>> facts(String projectId) async =>
      (await (_db.select(_facts)
                ..where((t) => t.projectId.equals(projectId))
                ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
              .get())
          .map(_fact)
          .toList();

  Stream<List<ProjectFact>> watchFacts(String projectId) =>
      (_db.select(_facts)
            ..where((t) => t.projectId.equals(projectId))
            ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .watch()
          .map((rows) => rows.map(_fact).toList());

  /// Сколько фактов можно хранить в одном проекте.
  static const maxFactsPerProject = 50;

  /// Максимальная длина одного факта в символах.
  static const maxFactChars = 2000;

  Future<void> addFact(ProjectFact fact) async {
    final text = fact.text.trim();
    if (text.isEmpty) {
      throw ArgumentError('project fact is empty');
    }
    if (text.length > maxFactChars) {
      throw ArgumentError(
        'project fact is too long: ${text.length} > $maxFactChars chars',
      );
    }
    final count = _facts.id.count();
    final row =
        await (_db.selectOnly(_facts)
              ..addColumns([count])
              ..where(_facts.projectId.equals(fact.projectId)))
            .getSingle();
    if ((row.read(count) ?? 0) >= maxFactsPerProject) {
      throw StateError('project fact limit reached: $maxFactsPerProject facts');
    }
    await _db
        .into(_facts)
        .insert(
          ProjectFactsCompanion.insert(
            id: fact.id,
            projectId: fact.projectId,
            content: text,
            createdAt: fact.createdAt,
          ),
        );
  }

  Future<void> deleteFact(String id) =>
      (_db.delete(_facts)..where((t) => t.id.equals(id))).go();

  Future<ProjectFact?> fact(String id) async {
    final row = await (_db.select(
      _facts,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _fact(row);
  }

  // ---- skills ------------------------------------------------------------

  /// Доверие по именам skills проекта.
  Future<Map<String, bool>> skillTrust(String projectId) async => {
    for (final row in await (_db.select(
      _skills,
    )..where((t) => t.projectId.equals(projectId))).get())
      row.name: row.trusted,
  };

  /// Skills проекта в порядке имени: карточка проекта показывает и доверенные, и нет.
  Stream<List<ProjectSkill>> watchSkills(String projectId) =>
      (_db.select(_skills)
            ..where((t) => t.projectId.equals(projectId))
            ..orderBy([(t) => OrderingTerm.asc(t.name)]))
          .watch()
          .map(
            (rows) => [
              for (final row in rows)
                ProjectSkill(name: row.name, trusted: row.trusted),
            ],
          );

  /// Доверенные имена skills проекта.
  Future<Set<String>> trustedSkillNames(String projectId) async => {
    for (final row
        in await (_db.select(_skills)..where(
              (t) => t.projectId.equals(projectId) & t.trusted.equals(true),
            ))
            .get())
      row.name,
  };

  /// Добавляет новые skills проекта и убирает исчезнувшие. Доверие существующих не меняется.
  /// Возвращает true, если набор изменился.
  Future<bool> syncSkills(String projectId, Iterable<String> names) =>
      _db.transaction(() async {
        final current = await (_db.select(
          _skills,
        )..where((t) => t.projectId.equals(projectId))).get();
        final existing = {for (final row in current) row.name};
        final wanted = names.toSet();
        var changed = false;
        for (final name in wanted.difference(existing)) {
          await _db
              .into(_skills)
              .insert(
                ProjectSkillsCompanion.insert(
                  projectId: projectId,
                  name: name,
                  createdAt: DateTime.now(),
                ),
              );
          changed = true;
        }
        final removed = existing.difference(wanted);
        if (removed.isNotEmpty) {
          await (_db.delete(_skills)..where(
                (t) => t.projectId.equals(projectId) & t.name.isIn(removed),
              ))
              .go();
          changed = true;
        }
        return changed;
      });

  Future<void> setSkillTrusted(
    String projectId,
    String name, {
    required bool trusted,
  }) =>
      (_db.update(_skills)
            ..where((t) => t.projectId.equals(projectId) & t.name.equals(name)))
          .write(ProjectSkillsCompanion(trusted: Value(trusted)));

  /// Доверяет всё содержимое папки: AGENTS.md и все известные skills.
  Future<void> trustWorkspace(String projectId) => _db.transaction(() async {
    await (_db.update(_projects)..where((t) => t.id.equals(projectId))).write(
      ProjectsCompanion(
        trustAgentsMd: const Value(true),
        skillsInitialized: const Value(true),
        updatedAt: Value(DateTime.now()),
      ),
    );
    await (_db.update(_skills)..where((t) => t.projectId.equals(projectId)))
        .write(const ProjectSkillsCompanion(trusted: Value(true)));
  });

  Future<void> setTrustAgentsMd(String projectId, bool trusted) =>
      (_db.update(_projects)..where((t) => t.id.equals(projectId))).write(
        ProjectsCompanion(
          trustAgentsMd: Value(trusted),
          updatedAt: Value(DateTime.now()),
        ),
      );

  // ---- mapping -----------------------------------------------------------

  Project _project(ProjectRow row) => Project(
    id: row.id,
    hostId: row.hostId,
    name: row.name,
    workspace: row.workspace,
    workspaceKey: row.workspaceKey,
    policyProfileId: row.policyProfileId,
    trustAgentsMd: row.trustAgentsMd,
    skillsInitialized: row.skillsInitialized,
    archivedAt: row.archivedAt,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );

  ProjectFact _fact(ProjectFactRow row) => ProjectFact(
    id: row.id,
    projectId: row.projectId,
    text: row.content,
    createdAt: row.createdAt,
  );
}

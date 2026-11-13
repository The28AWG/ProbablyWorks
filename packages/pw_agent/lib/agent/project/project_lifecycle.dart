import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';
import 'package:logging/logging.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/project.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/data/project_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/util/workspace_path.dart';
import 'package:pw_agent/host/host_capture.dart';
import 'package:pw_agent/host/host_op.dart';
import 'package:pw_agent/host/host_runtime_factory.dart';
import 'package:uuid/uuid.dart';

/// Жизненный цикл проекта. Проект не создаётся кнопкой: он появляется из пары
/// «хост + явная рабочая папка» при первом сохранении чата.
///
/// Явная папка — та, что выбрана в чате, либо папка, заданная хосту. Неявный домашний
/// каталог проектом не становится: иначе чаты без папки делили бы память и доверие
/// к `~/AGENTS.md`. Команды при этом всё равно идут из дома, см. [commandWorkspace].
/// Когда у проекта не остаётся чатов, он уходит в архив и удаляется окончательно через
/// [purgeAfter]. Факты и доверие skills переживают удаление последнего чата.
@lazySingleton
class ProjectLifecycleService {
  ProjectLifecycleService(
    this._db,
    this._projects,
    this._hosts,
    this._runtimes,
  );

  final AppDatabase _db;
  final ProjectRepository _projects;
  final HostRepository _hosts;
  final HostRuntimeFactory _runtimes;

  /// Сколько проект живёт в архиве без чатов.
  static const purgeAfter = Duration(days: 7);

  static const _uuid = Uuid();
  final _log = Logger('ProjectLifecycle');

  /// Папка, которую пользователь задал хосту. Null — дом в проект не подставляется.
  String? configuredWorkspace(Host host) => configuredHostWorkspace(host);

  /// Папка проекта для чата. Null — у чата нет проекта.
  String? projectWorkspace(Chat chat, Host host) =>
      explicitProjectWorkspace(host, chat.workspace);

  /// Каталог команд: явная папка, папка хоста или дом. Дом проектом не является.
  String defaultWorkspaceFor(Host host) => commandWorkspace(host, null);

  /// Канонический ключ папки на конкретном хосте.
  ///
  /// `RealpathOp` раскрывает `~` и симлинки силами Host. Если хост недоступен или папки
  /// ещё нет, остаётся лексическая форма: она стабильна и не даёт двух проектов на
  /// `~/repo` и `/home/user/repo/` в пределах одного запуска.
  Future<String> canonicalKey(Host host, String workspace) async {
    final windows = host.os == HostOs.windows;
    final lexical = normalizeWorkspacePath(workspace, windows: windows);
    try {
      final run = await captureOp(
        _runtimes.forHost(host),
        RealpathOp(workspace),
      );
      if (!run.ok) return lexical;
      final path = run.stdout.trim();
      return path.isEmpty
          ? lexical
          : normalizeWorkspacePath(path, windows: windows);
    } on Object catch (error, stack) {
      _log.fine('realpath failed, using lexical key', error, stack);
      return lexical;
    }
  }

  Future<Project> ensureProject({
    required String hostId,
    required String workspace,
    DateTime? now,
  }) async {
    final host = await _hosts.byId(hostId);
    if (host == null) {
      throw ArgumentError.value(hostId, 'hostId', 'host not found');
    }
    final key = await canonicalKey(host, workspace);
    final at = now ?? DateTime.now();
    final existing = await _projects.find(hostId, key);
    if (existing != null) {
      return _revive(existing, at);
    }

    final project = Project(
      id: _uuid.v4(),
      hostId: hostId,
      name: projectNameFor(workspace),
      workspace: workspace,
      workspaceKey: key,
      createdAt: at,
      updatedAt: at,
    );
    final projectsTable = _db.projects;
    // insertOrIgnore защищает от гонки двух первых сообщений в одной папке.
    await _db
        .into(projectsTable)
        .insert(
          ProjectsCompanion.insert(
            id: project.id,
            hostId: project.hostId,
            name: project.name,
            workspace: project.workspace,
            workspaceKey: project.workspaceKey,
            createdAt: project.createdAt,
            updatedAt: project.updatedAt,
          ),
          mode: InsertMode.insertOrIgnore,
        );
    final saved = await _projects.find(hostId, key);
    if (saved == null) {
      throw StateError('project was not created for $hostId/$key');
    }
    return saved;
  }

  /// Проект для уже сохранённого чата. Null, если явной папки нет: чат без папки
  /// не присоединяется к домашнему проекту.
  Future<Project?> ensureForChat(Chat chat) async {
    final host = await _hosts.byId(chat.hostId);
    if (host == null) {
      throw ArgumentError.value(chat.hostId, 'hostId', 'host not found');
    }
    final workspace = projectWorkspace(chat, host);
    if (workspace == null) return null;
    final project = await ensureProject(
      hostId: chat.hostId,
      workspace: workspace,
    );
    if (chat.projectId != project.id || chat.workspace != workspace) {
      final chatsTable = _db.chats;
      await (_db.update(chatsTable)..where((t) => t.id.equals(chat.id))).write(
        ChatsCompanion(
          projectId: Value(project.id),
          workspace: Value(workspace),
        ),
      );
    }
    return project;
  }

  /// Готовит новый чат к сохранению. Без явной папки проект не создаётся.
  Future<Chat> attach(Chat chat) async {
    final host = await _hosts.byId(chat.hostId);
    if (host == null) {
      throw ArgumentError.value(chat.hostId, 'hostId', 'host not found');
    }
    final workspace = projectWorkspace(chat, host);
    if (workspace == null) {
      return chat.copyWith(clearProjectId: true, clearWorkspace: true);
    }
    final project = await ensureProject(
      hostId: chat.hostId,
      workspace: workspace,
    );
    return chat.copyWith(workspace: workspace, projectId: project.id);
  }

  /// Переносит чат в проект новой пары «хост + папка». Старый проект архивируется,
  /// если в нём не осталось чатов.
  ///
  /// [workspaceSpecified] отличает очистку папки от смены хоста: пустая папка
  /// отвязывает чат, если у хоста нет своей. Смена хоста не переносит чужой путь
  /// и берёт папку нового хоста. Возвращает обновлённый чат; если чат уже в базе,
  /// записывает его сам.
  Future<Chat> relocate(
    Chat chat, {
    String? hostId,
    String? workspace,
    bool workspaceSpecified = false,
  }) async {
    final nextHostId = hostId ?? chat.hostId;
    final host = await _hosts.byId(nextHostId);
    if (host == null) {
      throw ArgumentError.value(nextHostId, 'hostId', 'host not found');
    }
    final nextWorkspace = _nextWorkspace(
      chat,
      host,
      hostChanged: hostId != null && hostId != chat.hostId,
      workspace: workspace,
      workspaceSpecified: workspaceSpecified,
    );
    if (nextWorkspace == null) {
      return _clearProject(chat, hostId: nextHostId);
    }
    final project = await ensureProject(
      hostId: nextHostId,
      workspace: nextWorkspace,
    );
    final previous = chat.projectId;
    final updated = chat.copyWith(
      hostId: nextHostId,
      workspace: nextWorkspace,
      projectId: project.id,
      updatedAt: DateTime.now(),
    );
    // Сохранённый чат переносим сразу: иначе старый проект ещё видит чат и не архивируется.
    final chatsTable = _db.chats;
    final saved =
        await (chatsTable.select()..where((t) => t.id.equals(chat.id)))
            .getSingleOrNull();
    if (saved != null) {
      await (_db.update(chatsTable)..where((t) => t.id.equals(chat.id))).write(
        ChatsCompanion(
          hostId: Value(nextHostId),
          workspace: Value(nextWorkspace),
          projectId: Value(project.id),
          updatedAt: Value(updated.updatedAt),
        ),
      );
    }
    if (previous != null && previous != project.id) {
      await releaseIfEmpty(previous);
    }
    return updated;
  }

  /// Существующий проект для пары чата, без создания. Нужен чипу «будет создан новый проект».
  /// Null, если явной папки нет: дом существующим проектом не показывается.
  Future<Project?> findForChat(Chat chat) async {
    final host = await _hosts.byId(chat.hostId);
    if (host == null) return null;
    final workspace = projectWorkspace(chat, host);
    if (workspace == null) return null;
    final key = await canonicalKey(host, workspace);
    return _projects.find(chat.hostId, key);
  }

  /// Проект чата до удаления чата: после `deleteChat` связь уже потеряна.
  Future<Project?> projectForChat(String chatId) => _projects.forChat(chatId);

  /// Архивирует проект, если в нём не осталось чатов. Уже архивный проект не трогаем:
  /// дата архивации — начало недельного срока до окончательного удаления.
  Future<void> releaseIfEmpty(String? projectId) async {
    if (projectId == null) return;
    if (await _projects.chatCount(projectId) > 0) return;
    final project = await _projects.byId(projectId);
    if (project == null || project.isArchived) return;
    await _projects.save(project.copyWith(archivedAt: DateTime.now()));
  }

  /// Удаляет архивные проекты без чатов, пролежавшие дольше [purgeAfter].
  Future<void> purgeExpired({DateTime? now}) async {
    final projectsTable = _db.projects;
    final cutoff = (now ?? DateTime.now()).subtract(purgeAfter);
    final rows =
        await (projectsTable.select()..where(
              (t) =>
                  t.archivedAt.isNotNull() &
                  t.archivedAt.isSmallerThanValue(cutoff),
            ))
            .get();
    for (final row in rows) {
      if (await _projects.chatCount(row.id) > 0) continue;
      await _projects.delete(row.id);
    }
  }

  /// Чинит чаты с явной папкой, оставшиеся без проекта после миграции или сбоя.
  /// Чат без папки не получает домашний проект.
  Future<void> repairOrphans() async {
    final chatsTable = _db.chats;
    final rows = await (chatsTable.select()..where((t) => t.projectId.isNull()))
        .get();
    for (final row in rows) {
      final host = await _hosts.byId(row.hostId);
      if (host == null) continue;
      final workspace = explicitProjectWorkspace(host, row.workspace);
      if (workspace == null) continue;
      final project = await ensureProject(
        hostId: row.hostId,
        workspace: workspace,
      );
      await (_db.update(chatsTable)..where((t) => t.id.equals(row.id))).write(
        ChatsCompanion(
          projectId: Value(project.id),
          workspace: Value(workspace),
        ),
      );
    }
  }

  /// Доверяет AGENTS.md и все известные skills проекта.
  Future<void> trustWorkspace(String projectId) =>
      _projects.trustWorkspace(projectId);

  String? _nextWorkspace(
    Chat chat,
    Host host, {
    required bool hostChanged,
    required String? workspace,
    required bool workspaceSpecified,
  }) {
    if (workspaceSpecified) {
      final explicit = workspace?.trim();
      if (explicit != null && explicit.isNotEmpty) return explicit;
      return configuredWorkspace(host);
    }
    if (hostChanged) return configuredWorkspace(host);
    return projectWorkspace(chat, host);
  }

  /// Снимает чат с проекта. Сохранённую строку обновляет сразу, чтобы старый
  /// проект увидел, что чата больше нет, и ушёл в архив.
  Future<Chat> _clearProject(Chat chat, {required String hostId}) async {
    final previous = chat.projectId;
    final updated = chat.copyWith(
      hostId: hostId,
      clearWorkspace: true,
      clearProjectId: true,
      updatedAt: DateTime.now(),
    );
    final chatsTable = _db.chats;
    final saved =
        await (chatsTable.select()..where((t) => t.id.equals(chat.id)))
            .getSingleOrNull();
    if (saved != null) {
      await (_db.update(chatsTable)..where((t) => t.id.equals(chat.id))).write(
        ChatsCompanion(
          hostId: Value(hostId),
          workspace: const Value(null),
          projectId: const Value(null),
          updatedAt: Value(updated.updatedAt),
        ),
      );
    }
    if (previous != null) await releaseIfEmpty(previous);
    return updated;
  }

  Future<Project> _revive(Project project, DateTime now) async {
    if (!project.isArchived) return project;
    final revived = project.copyWith(clearArchivedAt: true, updatedAt: now);
    await _projects.save(revived);
    return revived;
  }
}

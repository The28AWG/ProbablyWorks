import 'package:drift/drift.dart';

@DataClassName('HostRow')
class Hosts extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get kind => text()();
  TextColumn get address => text().nullable()();
  IntColumn get port => integer().withDefault(const Constant(22))();
  TextColumn get username => text().nullable()();
  TextColumn get authType => text().withDefault(const Constant('key'))();
  TextColumn get keyPath => text().nullable()();
  TextColumn get hostKeyFingerprint => text().nullable()();
  TextColumn get osFamily => text().withDefault(const Constant('posix'))();
  TextColumn get defaultWorkspace => text().nullable()();
  TextColumn get shellOverride => text().nullable()();
  TextColumn get notes => text().nullable()();
  IntColumn get connectTimeoutSeconds => integer().nullable()();
  DateTimeColumn get lastCheckAt => dateTime().nullable()();
  IntColumn get lastLatencyMs => integer().nullable()();
  TextColumn get lastCheckError => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Проект: неявная пара «хост + явная рабочая папка», к которой привязаны чаты.
///
/// Проект создаётся при первом сохранении чата в этой папке и находится по ключу
/// ([hostId], [workspaceKey]). Домашний каталог без выбора папки проектом не является.
/// Хост и папка — идентичность проекта: их нельзя изменить, можно только перейти в другой проект.
/// Когда чатов не осталось, проект уходит в архив и удаляется окончательно через неделю.
@DataClassName('ProjectRow')
@TableIndex(
  name: 'projects_host_key',
  columns: {#hostId, #workspaceKey},
  unique: true,
)
class Projects extends Table {
  TextColumn get id => text()();
  TextColumn get hostId =>
      text().references(Hosts, #id, onDelete: KeyAction.cascade)();

  /// Имя для интерфейса. Меняется пользователем, по умолчанию — последняя папка пути.
  TextColumn get name => text()();

  /// Путь так, как его видит пользователь. Может содержать `~`.
  TextColumn get workspace => text()();

  /// Канонический путь для поиска проекта: `~` раскрыт, симлинки разрешены.
  TextColumn get workspaceKey => text()();
  TextColumn get policyProfileId => text().nullable()();

  /// Доверие к AGENTS.md проекта. Отдельно от доверия к skills: это разные источники инструкций.
  BoolColumn get trustAgentsMd =>
      boolean().withDefault(const Constant(false))();

  /// Первое сканирование skills выполнено. Нужно миграции: старые skills доверяются один раз,
  /// а появившиеся позже — уже нет.
  BoolColumn get skillsInitialized =>
      boolean().withDefault(const Constant(false))();

  /// Время архивации: чатов не осталось. Null — проект активен.
  DateTimeColumn get archivedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Доверие к отдельному skill проекта. Запись создаётся при первом сканировании каталогов skills.
@DataClassName('ProjectSkillRow')
class ProjectSkills extends Table {
  TextColumn get projectId =>
      text().references(Projects, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text()();
  BoolColumn get trusted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {projectId, name};
}

/// Долговременная память проекта: одно саммари на проект.
///
/// Строка одна, без ревизий. Обновляется memory-циклом агента, а не пользователем
/// напрямую; старые факты сворачиваются в неё одноразовой миграцией.
@DataClassName('ProjectMemoryRow')
class ProjectMemories extends Table {
  TextColumn get projectId =>
      text().references(Projects, #id, onDelete: KeyAction.cascade)();
  TextColumn get summary => text()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {projectId};
}

/// Именованный профиль политики. Проект может ссылаться на него вместо глобального профиля.
@DataClassName('PolicyProfileRow')
class PolicyProfiles extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get description => text().nullable()();

  /// JSON профиля ([SecurityProfile.encode]).
  TextColumn get profileJson => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('ChatRow')
@TableIndex(name: 'chats_project', columns: {#projectId})
class Chats extends Table {
  TextColumn get id => text()();
  TextColumn get hostId =>
      text().references(Hosts, #id, onDelete: KeyAction.cascade)();

  /// Проект чата. Null допустим только для строк, созданных до миграции v10:
  /// приложение чинит такие строки при старте и при открытии чата.
  TextColumn get projectId => text().nullable().references(
    Projects,
    #id,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get title => text()();
  TextColumn get titleSource => text().withDefault(const Constant('none'))();

  /// `main` или `subagent`. Скрытые чаты субагентов не попадают в список.
  TextColumn get kind => text().withDefault(const Constant('main'))();

  /// Родительский чат для субагента и самый верхний пользовательский чат.
  TextColumn get parentChatId => text().nullable()();
  TextColumn get rootChatId => text().nullable()();
  IntColumn get depth => integer().withDefault(const Constant(0))();
  TextColumn get model => text().nullable()();
  TextColumn get policyMode => text().withDefault(const Constant('ask'))();
  TextColumn get workspace => text().nullable()();
  IntColumn get lastPromptTokens => integer().nullable()();
  IntColumn get lastCompletionTokens => integer().nullable()();
  IntColumn get contextLength => integer().nullable()();
  TextColumn get compactionSummary => text().nullable()();
  IntColumn get compactedUntilSeq => integer().withDefault(const Constant(0))();
  TextColumn get currentRevisionId => text().nullable()();

  /// Черновик поля ввода: текст, который пользователь ещё не отправил.
  TextColumn get draft => text().withDefault(const Constant(''))();

  /// Вложения черновика: JSON-список AttachmentRef (содержимое уже замаскировано).
  TextColumn get draftAttachments => text().withDefault(const Constant('[]'))();

  /// Неотправленные правки сообщений: JSON-объект id сообщения → текст и вложения.
  /// Пишется отдельно от [draft], чтобы набор в ленте не затирал поле внизу.
  TextColumn get messageEdits => text().withDefault(const Constant('{}'))();

  /// Версия черновика и правок. Нужна для разрешения конфликтов между клиентами.
  IntColumn get draftRevision => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('MessageRow')
class Messages extends Table {
  TextColumn get id => text()();
  TextColumn get chatId =>
      text().references(Chats, #id, onDelete: KeyAction.cascade)();
  IntColumn get seq => integer()();
  TextColumn get role => text()();
  TextColumn get payload => text()();
  TextColumn get openedRevisionId => text().nullable()();
  TextColumn get sealedBeforeRevisionId => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {chatId, seq},
  ];
}

@DataClassName('ToolRunRow')
class ToolRuns extends Table {
  TextColumn get id => text()();
  TextColumn get chatId =>
      text().references(Chats, #id, onDelete: KeyAction.cascade)();
  TextColumn get messageId => text()();
  TextColumn get toolName => text()();
  TextColumn get argsJson => text()();
  TextColumn get command => text().nullable()();
  BoolColumn get background => boolean().withDefault(const Constant(false))();
  IntColumn get pid => integer().nullable()();
  TextColumn get status => text()();
  IntColumn get exitCode => integer().nullable()();
  BoolColumn get timedOut => boolean().withDefault(const Constant(false))();
  TextColumn get logPath => text().nullable()();
  TextColumn get outputText => text().nullable()();
  BoolColumn get outputTruncated =>
      boolean().withDefault(const Constant(false))();
  TextColumn get resultPreview => text().nullable()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get finishedAt => dateTime().nullable()();

  /// Id вызова в сообщении ассистента. Нужен, чтобы после перезапуска привязать ответ к тому же вызову.
  TextColumn get toolCallId => text().nullable()();

  /// Карточка подтверждения (summary, reason, diff), пока статус waitingApproval.
  /// Вопрос ask_user лежит в argsJson, поэтому для него поле пустое.
  TextColumn get pendingCard => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('RevisionRow')
class SessionRevisions extends Table {
  TextColumn get id => text()();
  TextColumn get chatId =>
      text().references(Chats, #id, onDelete: KeyAction.cascade)();
  TextColumn get parentId => text().nullable()();
  TextColumn get triggeredByMessageId => text().nullable()();
  BoolColumn get sealed => boolean().withDefault(const Constant(false))();
  TextColumn get stateJson => text()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Модели, которые пользователь выбрал (закрепил, поставил по умолчанию, для заголовков или в чат),
/// с деталями. Нужны, чтобы показать название до загрузки каталога и маркер `!`, если модели больше нет.
/// Полный список моделей OpenRouter в БД не хранится.
@DataClassName('SavedModelRow')
class SavedModels extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get contextLength => integer().nullable()();
  BoolColumn get supportsTools =>
      boolean().withDefault(const Constant(false))();

  /// Входные модальности через запятую (`text,image,file`). Null — каталог их не описал.
  TextColumn get inputModalities => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('KvRow')
class KvSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

/// Настройки подключения MCP-серверов.
///
/// Секреты не хранятся в [configJson]: там только ссылки `${secret:...}`.
/// [source] отделяет серверы из `mcp.json` от добавленных пользователем.
@DataClassName('McpServerRow')
class McpServers extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get transport => text()();
  TextColumn get source => text()();
  TextColumn get externalKey => text().nullable()();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  TextColumn get configJson => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Файлы виртуального Host. Строка — узел с метаданными; содержимое файла лежит в [content].
/// Путь канонический (см. `VfsPath`), поэтому ключ (hostId, path) не допускает двух имён одной записи.
/// Индекс по (hostId, parentPath) нужен для листинга каталога.
@DataClassName('VirtualFsNodeRow')
@TableIndex(name: 'virtual_fs_nodes_parent', columns: {#hostId, #parentPath})
class VirtualFsNodes extends Table {
  TextColumn get hostId =>
      text().references(Hosts, #id, onDelete: KeyAction.cascade)();
  TextColumn get path => text()();
  TextColumn get parentPath => text()();

  /// `file`, `dir` или `symlink` (имя `VfsNodeKind`).
  TextColumn get kind => text()();
  IntColumn get mode => integer()();

  /// Секунды Unix, та же единица, что у `stat -c %Y`.
  IntColumn get mtime => integer()();
  IntColumn get size => integer()();
  TextColumn get target => text().nullable()();
  BlobColumn get content => blob().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {hostId, path};
}

/// Отложенный запуск агента: сообщение, которое нужно отправить в чат в указанное время.
/// Статус `dispatched` означает, что сообщение уже передано сессии; результат живёт в журнале чата.
@DataClassName('ScheduledTaskRow')
@TableIndex(name: 'scheduled_tasks_due', columns: {#status, #dueAt})
class ScheduledTasks extends Table {
  TextColumn get id => text()();
  TextColumn get chatId =>
      text().references(Chats, #id, onDelete: KeyAction.cascade)();
  TextColumn get prompt => text()();
  DateTimeColumn get dueAt => dateTime()();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  TextColumn get error => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

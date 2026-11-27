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

  /// Ревизия редактируемых полей. Растёт при сохранении из формы; результат
  /// проверки подключения её не меняет, чтобы автопроверка не ломала открытую
  /// форму в другом окне.
  IntColumn get revision => integer().withDefault(const Constant(0))();
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

  /// Ревизия свойств проекта. Хост и папка — идентичность и не меняются;
  /// имя, память, доверие и профиль политики версионируются.
  IntColumn get revision => integer().withDefault(const Constant(0))();
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

  /// Уровень рассуждений чата. `inherit` — следовать настройке по умолчанию.
  TextColumn get reasoning => text().withDefault(const Constant('inherit'))();
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

  /// Упоминания файлов и каталогов workspace: JSON-список MentionRef.
  /// Полный путь хранится здесь, в тексте остаётся только basename.
  TextColumn get draftMentions => text().withDefault(const Constant('[]'))();

  /// Неотправленные правки сообщений: JSON-объект id сообщения → текст и вложения.
  /// Пишется отдельно от [draft], чтобы набор в ленте не затирал поле внизу.
  TextColumn get messageEdits => text().withDefault(const Constant('{}'))();

  /// Версия черновика композера. Нужна для разрешения конфликтов между клиентами.
  IntColumn get draftRevision => integer().withDefault(const Constant(0))();

  /// Версия неотправленных правок сообщений. Отдельная от [draftRevision].
  IntColumn get messageEditsRevision =>
      integer().withDefault(const Constant(0))();

  /// Версия метаданных чата для точечного PATCH.
  IntColumn get revision => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Курсор прочтения и счётчик непрочитанного.
///
/// Таблица отдельная от [Chats], потому что это не свойство разговора:
/// полное сохранение чата (`PUT /chats/{id}`) не должно сбрасывать прогресс
/// чтения, а запись курсора не должна менять `updatedAt` и порядок списка.
/// Строка появляется при первом сообщении или первом явном прочтении; её
/// отсутствие означает «ещё ничего не прочитано».
@DataClassName('ChatReadRow')
class ChatReadStates extends Table {
  TextColumn get chatId =>
      text().references(Chats, #id, onDelete: KeyAction.cascade)();

  /// Максимум `seq` среди всех сообщений чата.
  IntColumn get lastMessageSeq => integer().withDefault(const Constant(0))();

  /// Общий read-horizon пользователя. Двигается только вперёд, но не может
  /// быть выше [lastMessageSeq]: удалённые сообщения освобождают свой `seq`,
  /// и новое сообщение на нём не должно выглядеть прочитанным.
  IntColumn get lastReadSeq => integer().withDefault(const Constant(0))();

  /// Сколько сообщений после [lastReadSeq] ещё не прочитано. Считаются
  /// сообщения агента и служебные строки; собственные сообщения и `tool`
  /// не создают непрочитанного.
  IntColumn get unreadCount => integer().withDefault(const Constant(0))();

  /// Растёт при каждом сдвиге курсора. Позволяет клиенту отличать более
  /// свежее событие от запоздавшего и строить дайджест.
  IntColumn get readRevision => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {chatId};
}

/// Проблемное завершение хода, которое ещё ждёт пользователя.
///
/// Одна строка на чат: новый проблемный ход заменяет предыдущий, а обычный
/// ход удаляет запись. Отдельная таблица, как у [ChatReadStates], не даёт
/// полному сохранению чата стереть состояние, которое переживает перезапуск.
@DataClassName('ChatAttentionRow')
class ChatAttentionStates extends Table {
  TextColumn get chatId =>
      text().references(Chats, #id, onDelete: KeyAction.cascade)();

  /// `failed`, `stepLimit`, `budget` или `stalled`.
  TextColumn get turn => text()();
  DateTimeColumn get occurredAt => dateTime()();

  /// Растёт при каждой записи. Нужна, чтобы отличить более свежий снимок от
  /// запоздавшего, когда два окна видят одно состояние.
  IntColumn get revision => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {chatId};
}

/// Отложенное напоминание о чате.
///
/// Отдельная таблица, как входящие и курсор прочтения: сохранение чата не
/// должно сбрасывать срок, а запись напоминания не должна менять `updatedAt`
/// и переставлять чат в списке. Одна строка на чат, потому что повторное
/// «напомнить позже» сдвигает срок, а не копит напоминания.
@DataClassName('ChatSnoozeRow')
class ChatAttentionSnoozes extends Table {
  TextColumn get chatId =>
      text().references(Chats, #id, onDelete: KeyAction.cascade)();

  /// До какого момента чат отложен. Просроченная строка ещё может лежать в
  /// базе, если таймер не успел её убрать: снимок сравнивает срок с текущим
  /// временем и такую строку не скрывает.
  DateTimeColumn get until => dateTime()();

  /// Растёт при каждом изменении срока, чтобы окна отличали свежий снимок от
  /// запоздавшего.
  IntColumn get revision => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {chatId};
}

/// Общая пауза уведомлений («тихие часы»).
///
/// Одна строка на агента, а не на чат: пауза выключает уведомления сразу на
/// всех устройствах. Отдельная таблица, как у snooze, не даёт сохранению
/// настроек или чата случайно сбросить срок, а поток базы оповещает окна и
/// SSE без отдельного маршрута чтения.
@DataClassName('NotificationPauseRow')
class NotificationPauses extends Table {
  /// Всегда `0`: таблица хранит одну текущую паузу.
  IntColumn get id => integer()();

  /// До какого момента уведомления молчат. Просроченная строка ещё может
  /// лежать в базе, если таймер не успел её убрать: сервис внимания сравнивает
  /// срок с текущим временем и такую паузу не показывает.
  DateTimeColumn get until => dateTime()();

  /// `focus`, `meeting` или `overnight`: подпись причины для интерфейса.
  TextColumn get reason => text().withDefault(const Constant('focus'))();

  /// Растёт при каждом изменении срока, чтобы окна отличали свежий снимок от
  /// запоздавшего.
  IntColumn get revision => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('MessageRow')
@TableIndex(
  name: 'messages_chat_client_message_id',
  columns: {#chatId, #clientMessageId},
  unique: true,
)
class Messages extends Table {
  TextColumn get id => text()();
  TextColumn get chatId =>
      text().references(Chats, #id, onDelete: KeyAction.cascade)();
  IntColumn get seq => integer()();

  /// Идентификатор отправки, который назначил клиент.
  ///
  /// Нужен для идемпотентности: повтор запроса после сетевого таймаута не
  /// создаёт второе сообщение. Null у событий агента и старых записей.
  TextColumn get clientMessageId => text().nullable()();
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

  /// Инструмент выполнился, но вернул ошибку. Отдельно от статуса вызова:
  /// такой результат агент обрабатывает как обычный и UI не считает сбоем.
  BoolColumn get resultError => boolean().withDefault(const Constant(false))();

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

  /// Возможности рассуждений в JSON (LlmReasoningCapability). Null — неизвестно.
  TextColumn get reasoningJson => text().nullable()();

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

  /// Ревизия формы MCP-сервера. Импорт файла тоже её увеличивает, чтобы
  /// открытая в другом окне форма не затёрла свежую конфигурацию.
  IntColumn get revision => integer().withDefault(const Constant(0))();
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

/// Файлы локальных моделей среды выполнения (llamadart).
///
/// Это модели среды, а не модели провайдера: файл можно скачать, настроить и
/// удалить при выключенном провайдере. Путь в БД не хранится: на iOS контейнер
/// приложения переезжает между запусками, поэтому источник и `cacheKey`
/// разрешаются в актуальный путь при чтении.
@DataClassName('LocalModelRow')
@TableIndex(name: 'local_models_source', columns: {#source})
class LocalModels extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();

  /// Исходник: `hf://...`, HTTP(S)-ссылка или путь на диске.
  TextColumn get source => text()();

  /// `LocalModelSourceKind` в виде строки.
  TextColumn get sourceKind => text()();

  /// Ключ кэша llamadart. Null — импортированный файл, которым владеет пользователь.
  TextColumn get cacheKey => text().nullable()();
  IntColumn get sizeBytes => integer().nullable()();
  TextColumn get sha256 => text().nullable()();

  /// `LocalModelSettings` в JSON. Параметры запуска и генерации файла.
  TextColumn get settingsJson => text().withDefault(const Constant('{}'))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get lastUsedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Активные скачивания файлов локальных моделей.
///
/// Запись живёт с момента установки до завершения, отмены или ошибки. После
/// перезапуска процесса сервис читает её и возобновляет загрузку: файл
/// докачивается с `.part` (Dart-менеджер) или подхватывается платформенной
/// задачей по `id`.
@DataClassName('LocalModelDownloadRow')
class LocalModelDownloads extends Table {
  TextColumn get id => text()();
  TextColumn get source => text()();
  TextColumn get name => text()();
  TextColumn get sha256 => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

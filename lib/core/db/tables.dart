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

@DataClassName('ChatRow')
class Chats extends Table {
  TextColumn get id => text()();
  TextColumn get hostId =>
      text().references(Hosts, #id, onDelete: KeyAction.cascade)();
  TextColumn get title => text()();
  TextColumn get titleSource => text().withDefault(const Constant('none'))();
  TextColumn get model => text().nullable()();
  TextColumn get policyMode => text().withDefault(const Constant('ask'))();
  TextColumn get workspace => text().nullable()();
  IntColumn get lastPromptTokens => integer().nullable()();
  IntColumn get lastCompletionTokens => integer().nullable()();
  IntColumn get contextLength => integer().nullable()();
  TextColumn get compactionSummary => text().nullable()();
  IntColumn get compactedUntilSeq => integer().withDefault(const Constant(0))();
  TextColumn get currentRevisionId => text().nullable()();
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

@DataClassName('KvRow')
class KvSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

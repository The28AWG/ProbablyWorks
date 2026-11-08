import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/domain/session_state.dart';
import 'package:probably_works/core/db/app_database.dart';

/// Чаты, сообщения, tool runs и ревизии состояния. Все многотабличные
/// изменения выполняются через [transaction].
@lazySingleton
class ChatRepository {
  ChatRepository(this._db);

  final AppDatabase _db;

  $ChatsTable get _chatsTable => _db.chats;
  $MessagesTable get _messagesTable => _db.messages;
  $ToolRunsTable get _toolRunsTable => _db.toolRuns;
  $SessionRevisionsTable get _sessionRevisionsTable => _db.sessionRevisions;

  Future<T> transaction<T>(Future<T> Function() action) =>
      _db.transaction(action);

  // ---- chats -------------------------------------------------------------

  /// Черновик пишется при паузах в наборе текста: такие записи не должны перестраивать список чатов.
  Stream<List<Chat>> watchChats() =>
      (_db.select(_chatsTable)
            ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
          .watch()
          .distinct(_sameChatsIgnoringDrafts)
          .map((rows) => rows.map(_chat).toList());

  static bool _sameChatsIgnoringDrafts(List<ChatRow> a, List<ChatRow> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (_withoutDraft(a[i]) != _withoutDraft(b[i])) return false;
    }
    return true;
  }

  static ChatRow _withoutDraft(ChatRow row) =>
      row.copyWith(draft: '', draftAttachments: '[]');

  /// Черновик пишется отдельно от записи чата: не трогает updatedAt, поэтому порядок списка не меняется.
  Future<void> saveDraft(String chatId, ChatDraft draft) =>
      (_db.update(_chatsTable)..where((t) => t.id.equals(chatId))).write(
        ChatsCompanion(
          draft: Value(draft.text),
          draftAttachments: Value(
            jsonEncode([
              for (final attachment in draft.attachments)
                attachment.redacted().toJson(),
            ]),
          ),
        ),
      );

  /// Id всех чатов. После старта по ним ищут незакрытый шаг: у него может не быть
  /// активного запуска, если процесс уже прерван, а остальные вызовы не начались.
  Future<List<String>> chatIds() async {
    final rows = await _db.select(_chatsTable).get();
    return [for (final row in rows) row.id];
  }

  Future<Chat?> chat(String id) async {
    final row = await (_db.select(
      _chatsTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _chat(row);
  }

  Future<void> saveChat(Chat chat) => _db
      .into(_chatsTable)
      .insertOnConflictUpdate(
        ChatsCompanion.insert(
          id: chat.id,
          hostId: chat.hostId,
          title: chat.title,
          titleSource: Value(chat.titleSource.name),
          model: Value(chat.model),
          policyMode: Value(chat.policyMode.name),
          workspace: Value(chat.workspace),
          lastPromptTokens: Value(chat.lastPromptTokens),
          lastCompletionTokens: Value(chat.lastCompletionTokens),
          contextLength: Value(chat.contextLength),
          compactionSummary: Value(chat.compactionSummary),
          compactedUntilSeq: Value(chat.compactedUntilSeq),
          currentRevisionId: Value(chat.currentRevisionId),
          createdAt: chat.createdAt,
          updatedAt: chat.updatedAt,
        ),
      );

  Future<void> deleteChat(String id) =>
      (_db.delete(_chatsTable)..where((t) => t.id.equals(id))).go();

  // ---- messages ----------------------------------------------------------

  Future<List<ChatMessage>> messages(String chatId, {int? fromSeq}) async {
    final query = _db.select(_messagesTable)
      ..where(
        (t) =>
            t.chatId.equals(chatId) &
            (fromSeq == null
                ? const Constant(true)
                : t.seq.isBiggerOrEqualValue(fromSeq)),
      )
      ..orderBy([(t) => OrderingTerm.asc(t.seq)]);
    return (await query.get()).map(_message).toList();
  }

  Future<int> nextSeq(String chatId) async {
    final max = _messagesTable.seq.max();
    final row =
        await (_db.selectOnly(_messagesTable)
              ..addColumns([max])
              ..where(_messagesTable.chatId.equals(chatId)))
            .getSingle();
    return (row.read(max) ?? 0) + 1;
  }

  /// Вставка сообщения и индексация для поиска в одной транзакции.
  Future<void> insertMessage(ChatMessage message) => _db.transaction(() async {
    await _db
        .into(_messagesTable)
        .insert(
          MessagesCompanion.insert(
            id: message.id,
            chatId: message.chatId,
            seq: message.seq,
            role: message.role.name,
            payload: message.encodePayload(),
            openedRevisionId: Value(message.openedRevisionId),
            sealedBeforeRevisionId: Value(message.sealedBeforeRevisionId),
            createdAt: message.createdAt,
          ),
        );
    await _indexMessage(message);
  });

  Future<void> _indexMessage(ChatMessage message) async {
    if (message.text.trim().isEmpty) return;
    await _db.customStatement(
      'INSERT INTO message_search(message_id, chat_id, body) VALUES (?, ?, ?)',
      [message.id, message.chatId, message.text],
    );
  }

  /// FTS-поиск по transcript чата. Запрос экранируется как набор фраз.
  Future<List<ChatMessage>> searchMessages(
    String chatId,
    String query, {
    int limit = 20,
  }) async {
    final terms = query
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .map((t) => '"${t.replaceAll('"', '""')}"')
        .join(' ');
    if (terms.isEmpty) return const [];
    final rows = await _db
        .customSelect(
          'SELECT message_id FROM message_search WHERE message_search MATCH ? AND chat_id = ? ORDER BY rank LIMIT ?',
          variables: [
            Variable.withString(terms),
            Variable.withString(chatId),
            Variable.withInt(limit),
          ],
        )
        .get();
    final ids = rows.map((r) => r.read<String>('message_id')).toList();
    if (ids.isEmpty) return const [];
    final found = await (_db.select(
      _messagesTable,
    )..where((t) => t.id.isIn(ids))).get();
    return found.map(_message).toList();
  }

  /// Удаляет сообщения с seq >= [fromSeq] и связанные записи. Возвращает удалённые id.
  Future<List<String>> deleteMessagesFrom(String chatId, int fromSeq) async {
    final rows =
        await (_db.select(_messagesTable)..where(
              (t) =>
                  t.chatId.equals(chatId) & t.seq.isBiggerOrEqualValue(fromSeq),
            ))
            .get();
    final ids = rows.map((r) => r.id).toList();
    if (ids.isEmpty) return ids;
    for (final id in ids) {
      await _db.customStatement(
        'DELETE FROM message_search WHERE message_id = ?',
        [id],
      );
    }
    await (_db.delete(_messagesTable)..where((t) => t.id.isIn(ids))).go();
    return ids;
  }

  // ---- tool runs ---------------------------------------------------------

  Future<void> saveToolRun(ToolRun run) => _db
      .into(_toolRunsTable)
      .insertOnConflictUpdate(
        ToolRunsCompanion.insert(
          id: run.id,
          chatId: run.chatId,
          messageId: run.messageId,
          toolName: run.toolName,
          argsJson: run.argsJson,
          command: Value(run.command),
          background: Value(run.background),
          pid: Value(run.pid),
          status: run.status.name,
          exitCode: Value(run.exitCode),
          timedOut: Value(run.timedOut),
          logPath: Value(run.logPath),
          outputText: Value(run.outputText),
          outputTruncated: Value(run.outputTruncated),
          resultPreview: Value(run.resultPreview),
          startedAt: run.startedAt,
          finishedAt: Value(run.finishedAt),
          toolCallId: Value(run.toolCallId),
          pendingCard: Value(run.pendingCard),
        ),
      );

  Future<List<ToolRun>> toolRunsForChat(String chatId) async =>
      (await (_db.select(_toolRunsTable)
                ..where((t) => t.chatId.equals(chatId))
                ..orderBy([(t) => OrderingTerm.asc(t.startedAt)]))
              .get())
          .map(_toolRun)
          .toList();

  Future<List<ToolRun>> toolRunsForMessages(List<String> messageIds) async {
    if (messageIds.isEmpty) return const [];
    return (await (_db.select(
          _toolRunsTable,
        )..where((t) => t.messageId.isIn(messageIds))).get())
        .map(_toolRun)
        .toList();
  }

  Future<void> deleteToolRuns(List<String> ids) async {
    if (ids.isEmpty) return;
    await (_db.delete(_toolRunsTable)..where((t) => t.id.isIn(ids))).go();
  }

  /// Все запуски, которые не завершились (после падения приложения их процессы уже неизвестны).
  Future<List<ToolRun>> allActiveRuns() async =>
      (await (_db.select(_toolRunsTable)..where(
                (t) => t.status.isIn([
                  ToolRunStatus.running.name,
                  ToolRunStatus.backgroundRunning.name,
                  ToolRunStatus.waitingApproval.name,
                  ToolRunStatus.waitingUser.name,
                ]),
              ))
              .get())
          .map(_toolRun)
          .toList();

  /// Запуски чата, у которых ещё нет ответа пользователя: вопрос или подтверждение.
  /// Отказ, остановка хода и обычное завершение сюда не попадают — статус уже другой.
  Future<List<ToolRun>> waitingRuns(String chatId) async =>
      (await (_db.select(_toolRunsTable)
                ..where(
                  (t) =>
                      t.chatId.equals(chatId) &
                      t.status.isIn([
                        ToolRunStatus.waitingApproval.name,
                        ToolRunStatus.waitingUser.name,
                      ]),
                )
                ..orderBy([(t) => OrderingTerm.asc(t.startedAt)]))
              .get())
          .map(_toolRun)
          .toList();

  // ---- revisions ---------------------------------------------------------

  Future<SessionStateRevision?> revision(String id) async {
    final row = await (_db.select(
      _sessionRevisionsTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _revision(row);
  }

  Future<List<SessionStateRevision>> revisionsForChat(String chatId) async =>
      (await (_db.select(_sessionRevisionsTable)
                ..where((t) => t.chatId.equals(chatId))
                ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
              .get())
          .map(_revision)
          .toList();

  Future<void> saveRevision(SessionStateRevision rev) => _db
      .into(_sessionRevisionsTable)
      .insertOnConflictUpdate(
        SessionRevisionsCompanion.insert(
          id: rev.id,
          chatId: rev.chatId,
          parentId: Value(rev.parentId),
          triggeredByMessageId: Value(rev.triggeredByMessageId),
          sealed: Value(rev.sealed),
          stateJson: _encodeState(rev),
          createdAt: rev.createdAt,
        ),
      );

  Future<void> deleteRevisionsTriggeredBy(List<String> messageIds) async {
    if (messageIds.isEmpty) return;
    await (_db.delete(
      _sessionRevisionsTable,
    )..where((t) => t.triggeredByMessageId.isIn(messageIds))).go();
  }

  // ---- mapping -----------------------------------------------------------

  Chat _chat(ChatRow row) => Chat(
    id: row.id,
    hostId: row.hostId,
    title: row.title,
    titleSource: ChatTitleSource.values.byName(row.titleSource),
    model: row.model,
    policyMode: PolicyMode.values.byName(row.policyMode),
    workspace: row.workspace,
    lastPromptTokens: row.lastPromptTokens,
    lastCompletionTokens: row.lastCompletionTokens,
    contextLength: row.contextLength,
    compactionSummary: row.compactionSummary,
    compactedUntilSeq: row.compactedUntilSeq,
    currentRevisionId: row.currentRevisionId,
    draft: ChatDraft(
      text: row.draft,
      attachments: [
        for (final json in jsonDecode(row.draftAttachments) as List<dynamic>)
          AttachmentRef.fromJson(json as Map<String, dynamic>),
      ],
    ),
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );

  ChatMessage _message(MessageRow row) => ChatMessage.decode(
    id: row.id,
    chatId: row.chatId,
    seq: row.seq,
    role: row.role,
    payload: row.payload,
    createdAt: row.createdAt,
    openedRevisionId: row.openedRevisionId,
    sealedBeforeRevisionId: row.sealedBeforeRevisionId,
  );

  ToolRun _toolRun(ToolRunRow row) => ToolRun(
    id: row.id,
    chatId: row.chatId,
    messageId: row.messageId,
    toolName: row.toolName,
    argsJson: row.argsJson,
    command: row.command,
    background: row.background,
    pid: row.pid,
    status: ToolRunStatus.values.byName(row.status),
    exitCode: row.exitCode,
    timedOut: row.timedOut,
    logPath: row.logPath,
    outputText: row.outputText,
    outputTruncated: row.outputTruncated,
    resultPreview: row.resultPreview,
    startedAt: row.startedAt,
    finishedAt: row.finishedAt,
    toolCallId: row.toolCallId,
    pendingCard: row.pendingCard,
  );

  SessionStateRevision _revision(RevisionRow row) => SessionStateRevision(
    id: row.id,
    chatId: row.chatId,
    parentId: row.parentId,
    triggeredByMessageId: row.triggeredByMessageId,
    sealed: row.sealed,
    createdAt: row.createdAt,
  )..applyStateJson(_decodeState(row.stateJson));

  String _encodeState(SessionStateRevision rev) =>
      jsonEncode(rev.stateToJson());

  Map<String, dynamic> _decodeState(String raw) =>
      jsonDecode(raw) as Map<String, dynamic>;
}

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/draft_persistence.dart';
import 'package:pw_agent/agent/domain/chat_attention.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/session_state.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/providers/ai/reasoning.dart';

/// Строка списка чатов вместе с курсором прочтения.
///
/// Пара нужна для `distinct`: черновик и read state меняются разными путями,
/// и список должен перестраиваться только на значимых изменениях.
typedef _ChatListEntry = ({ChatRow chat, ChatReadRow? read});

/// Чаты, сообщения, tool runs и ревизии состояния. Все многотабличные
/// изменения выполняются через [transaction].
@lazySingleton
class ChatRepository implements DraftPersistence {
  ChatRepository(this._db);

  final AppDatabase _db;

  $ChatsTable get _chatsTable => _db.chats;
  $ChatReadStatesTable get _readTable => _db.chatReadStates;
  $ChatAttentionStatesTable get _attentionTable => _db.chatAttentionStates;
  $MessagesTable get _messagesTable => _db.messages;
  $ToolRunsTable get _toolRunsTable => _db.toolRuns;
  $SessionRevisionsTable get _sessionRevisionsTable => _db.sessionRevisions;

  Future<T> transaction<T>(Future<T> Function() action) =>
      _db.transaction(action);

  // ---- chats -------------------------------------------------------------

  /// Черновик пишется при паузах в наборе текста: такие записи не должны перестраивать список чатов.
  ///
  /// Курсор прочтения приходит из отдельной таблицы. Без `distinct` каждое
  /// сохранение черновика перестраивало бы весь список, а с ним и unread.
  Stream<List<Chat>> watchChats() {
    final query =
        _db.select(_chatsTable).join([
            leftOuterJoin(
              _readTable,
              _readTable.chatId.equalsExp(_chatsTable.id),
            ),
          ])
          ..where(_chatsTable.kind.equals(ChatKind.main.name))
          ..orderBy([OrderingTerm.desc(_chatsTable.updatedAt)]);
    return query
        .watch()
        .map(
          (rows) => [
            for (final row in rows)
              (
                chat: row.readTable(_chatsTable),
                read: row.readTableOrNull(_readTable),
              ),
          ],
        )
        .distinct(_sameChatsIgnoringDrafts)
        .map((rows) => [for (final item in rows) _chat(item.chat, item.read)]);
  }

  static bool _sameChatsIgnoringDrafts(
    List<_ChatListEntry> a,
    List<_ChatListEntry> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (_withoutDraft(a[i].chat) != _withoutDraft(b[i].chat)) return false;
      if (a[i].read != b[i].read) return false;
    }
    return true;
  }

  static ChatRow _withoutDraft(ChatRow row) => row.copyWith(
    draft: '',
    draftAttachments: '[]',
    draftMentions: '[]',
    messageEdits: '{}',
    draftRevision: 0,
    messageEditsRevision: 0,
  );

  /// Чаты проекта, новые сверху. Карточка проекта открывает их отсюда.
  Stream<List<Chat>> watchByProject(String projectId) {
    final query =
        _db.select(_chatsTable).join([
            leftOuterJoin(
              _readTable,
              _readTable.chatId.equalsExp(_chatsTable.id),
            ),
          ])
          ..where(
            _chatsTable.projectId.equals(projectId) &
                _chatsTable.kind.equals(ChatKind.main.name),
          )
          ..orderBy([OrderingTerm.desc(_chatsTable.updatedAt)]);
    return query.watch().map(
      (rows) => [
        for (final row in rows)
          _chat(row.readTable(_chatsTable), row.readTableOrNull(_readTable)),
      ],
    );
  }

  /// Неотправленные правки сообщений. Как [saveDraft], не трогает updatedAt.
  @override
  Future<int> saveMessageEdits(
    String chatId,
    Map<String, ChatDraft> edits, {
    int? expectedRevision,
  }) => _saveDraftFields(
    chatId,
    ChatsCompanion(messageEdits: Value(encodeMessageEdits(edits))),
    expectedRevision,
    edits: true,
  );

  /// Черновик пишется отдельно от записи чата: не трогает updatedAt, поэтому порядок списка не меняется.
  @override
  Future<int> saveDraft(
    String chatId,
    ChatDraft draft, {
    int? expectedRevision,
  }) => _saveDraftFields(
    chatId,
    ChatsCompanion(
      draft: Value(draft.text),
      draftAttachments: Value(
        jsonEncode([
          for (final attachment in draft.attachments)
            attachment.redacted().toJson(),
        ]),
      ),
      draftMentions: Value(
        jsonEncode([for (final mention in draft.mentions) mention.toJson()]),
      ),
    ),
    expectedRevision,
  );

  Future<int> _saveDraftFields(
    String chatId,
    ChatsCompanion fields,
    int? expectedRevision, {
    bool edits = false,
  }) => _db.transaction(() async {
    final row = await (_db.select(
      _chatsTable,
    )..where((t) => t.id.equals(chatId))).getSingleOrNull();
    if (row == null) {
      throw AgentApiException(404, 'chat_not_found', 'chat $chatId not found');
    }
    final current = edits ? row.messageEditsRevision : row.draftRevision;
    if (expectedRevision != null && expectedRevision != current) {
      throw AgentApiException(409, 'draft_conflict', 'draft revision changed');
    }
    final next = current + 1;
    await (_db.update(_chatsTable)..where((t) => t.id.equals(chatId))).write(
      fields.copyWith(
        draftRevision: edits ? null : Value(next),
        messageEditsRevision: edits ? Value(next) : null,
      ),
    );
    return next;
  });

  /// Id всех чатов. После старта по ним ищут незакрытый шаг: у него может не быть
  /// активного запуска, если процесс уже прерван, а остальные вызовы не начались.
  Future<List<String>> chatIds() async {
    final rows = await _db.select(_chatsTable).get();
    return [for (final row in rows) row.id];
  }

  /// Все чаты, включая скрытых субагентов. Нужно восстановлению.
  Future<List<Chat>> allChats() async {
    final rows = await _db.select(_chatsTable).get();
    return [for (final row in rows) _chat(row)];
  }

  /// Чат и все его потомки, самые глубокие сначала: дочерние строки удаляются раньше родителя.
  ///
  /// `deleteChat` сам рекурсивно удаляет детей, но очистке истории нужны id
  /// каждого чата: у скрытых субагентов свои логи и снимки файлов, и они не
  /// уходят каскадом внешних ключей. Пустой список — чата нет.
  Future<List<Chat>> chatAndDescendants(String rootId) async {
    final all = await allChats();
    final children = <String, List<Chat>>{};
    Chat? root;
    for (final chat in all) {
      if (chat.id == rootId) root = chat;
      final parentId = chat.parentChatId;
      if (parentId != null) {
        children.putIfAbsent(parentId, () => []).add(chat);
      }
    }
    if (root == null) return const [];
    final result = <Chat>[];
    void visit(Chat chat) {
      result.add(chat);
      for (final child in children[chat.id] ?? const <Chat>[]) {
        visit(child);
      }
    }

    visit(root);
    result.sort((a, b) => b.depth.compareTo(a.depth));
    return result;
  }

  @override
  Future<Chat?> chat(String id) async {
    final entry = await _chatEntry(id);
    return entry == null ? null : _chat(entry.chat, entry.read);
  }

  /// Чат вместе с read state. Один запрос на открытие чата и его список.
  Future<_ChatListEntry?> _chatEntry(String id) async {
    final query = _db.select(_chatsTable).join([
      leftOuterJoin(_readTable, _readTable.chatId.equalsExp(_chatsTable.id)),
    ])..where(_chatsTable.id.equals(id));
    final row = await query.getSingleOrNull();
    if (row == null) return null;
    return (
      chat: row.readTable(_chatsTable),
      read: row.readTableOrNull(_readTable),
    );
  }

  Future<void> saveChat(Chat chat) => _db
      .into(_chatsTable)
      .insertOnConflictUpdate(
        ChatsCompanion.insert(
          id: chat.id,
          hostId: chat.hostId,
          projectId: Value(chat.projectId),
          title: chat.title,
          titleSource: Value(chat.titleSource.name),
          kind: Value(chat.kind.name),
          parentChatId: Value(chat.parentChatId),
          rootChatId: Value(chat.rootChatId),
          depth: Value(chat.depth),
          model: Value(chat.model),
          reasoning: Value(chat.reasoning.name),
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

  /// Точечно меняет метаданные чата, не переписывая строку целиком.
  ///
  /// [expectedRevision] защищает от затирания полей, изменённых другим
  /// клиентом. Отсутствие параметра означает «не проверять» и нужно старым
  /// вызовам, которым ревизия ещё не передаётся.
  Future<Chat> updateChat(
    String chatId, {
    String? title,
    String? model,
    ReasoningPreference? reasoning,
    PolicyMode? policyMode,
    String? workspace,
    bool workspaceSpecified = false,
    int? expectedRevision,
  }) => _db.transaction(() async {
    final row = await (_db.select(
      _chatsTable,
    )..where((t) => t.id.equals(chatId))).getSingleOrNull();
    if (row == null) {
      throw AgentApiException(404, 'chat_not_found', 'chat $chatId not found');
    }
    if (expectedRevision != null && expectedRevision != row.revision) {
      throw const AgentApiException(
        409,
        'chat_conflict',
        'chat revision changed',
      );
    }
    final next = row.revision + 1;
    final trimmed = title?.trim();
    await (_db.update(_chatsTable)..where((t) => t.id.equals(chatId))).write(
      ChatsCompanion(
        title: trimmed == null || trimmed.isEmpty
            ? const Value.absent()
            : Value(trimmed),
        titleSource: trimmed == null || trimmed.isEmpty
            ? const Value.absent()
            : const Value('user'),
        model: model == null ? const Value.absent() : Value(model),
        reasoning: reasoning == null
            ? const Value.absent()
            : Value(reasoning.name),
        policyMode: policyMode == null
            ? const Value.absent()
            : Value(policyMode.name),
        workspace: workspaceSpecified ? Value(workspace) : const Value.absent(),
        revision: Value(next),
        updatedAt: Value(DateTime.now()),
      ),
    );
    final updated = await (_db.select(
      _chatsTable,
    )..where((t) => t.id.equals(chatId))).getSingle();
    final read = await _readRow(chatId);
    return _chat(updated, read);
  });

  /// Удаляет чат и всех его скрытых потомков-субагентов.
  Future<void> deleteChat(String id) async {
    final children = await (_db.select(
      _chatsTable,
    )..where((t) => t.parentChatId.equals(id))).get();
    for (final child in children) {
      await deleteChat(child.id);
    }
    // FTS-таблица не участвует в каскаде внешних ключей.
    await _db.customStatement('DELETE FROM message_search WHERE chat_id = ?', [
      id,
    ]);
    await (_db.delete(_chatsTable)..where((t) => t.id.equals(id))).go();
  }

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

  /// Была ли отправка с таким [clientMessageId] уже записана в чате.
  ///
  /// Идентификатор уникален в пределах чата, поэтому проверка идёт по обоим
  /// полям. По этому признаку повтор после потерянного ответа не создаёт
  /// второе сообщение, а индекс ускоряет проверку и страхует от гонки.
  Future<bool> hasClientMessage(String chatId, String clientMessageId) async {
    final row =
        await (_db.select(_messagesTable)..where(
              (t) =>
                  t.chatId.equals(chatId) &
                  t.clientMessageId.equals(clientMessageId),
            ))
            .getSingleOrNull();
    return row != null;
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
            clientMessageId: Value(message.clientMessageId),
            role: message.role.name,
            payload: message.encodePayload(),
            openedRevisionId: Value(message.openedRevisionId),
            sealedBeforeRevisionId: Value(message.sealedBeforeRevisionId),
            createdAt: message.createdAt,
          ),
        );
    await _indexMessage(message);
    await _bumpReadState(message);
  });

  Future<void> _indexMessage(ChatMessage message) async {
    // Индекс без уникального ключа: перед вставкой убираем прежнюю строку,
    // чтобы повторная запись сообщения не создала дубль.
    await _db.customStatement(
      'DELETE FROM message_search WHERE message_id = ?',
      [message.id],
    );
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
    final terms = _ftsQuery(query);
    if (terms == null) return const [];
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

  /// FTS-поиск по всем основным чатам или по чатам одного проекта.
  ///
  /// Возвращает сообщения в порядке релевантности вместе с названием чата,
  /// чтобы модель могла сослаться на решение из другого чата.
  Future<List<ChatSearchHit>> searchMessagesAll(
    String query, {
    String? projectId,
    int limit = 20,
  }) async {
    final terms = _ftsQuery(query);
    if (terms == null) return const [];
    final projectClause = projectId == null ? '' : ' AND c.project_id = ?';
    final variables = [
      Variable.withString(terms),
      Variable.withString(ChatKind.main.name),
      if (projectId != null) Variable.withString(projectId),
      Variable.withInt(limit),
    ];
    final rows = await _db
        .customSelect(
          'SELECT message_search.message_id AS message_id, '
          'message_search.chat_id AS chat_id, c.title AS chat_title '
          'FROM message_search '
          'JOIN chats c ON c.id = message_search.chat_id '
          'WHERE message_search MATCH ? AND c.kind = ?$projectClause '
          'ORDER BY rank LIMIT ?',
          variables: variables,
        )
        .get();
    if (rows.isEmpty) return const [];
    final ids = rows.map((r) => r.read<String>('message_id')).toList();
    final found = await (_db.select(
      _messagesTable,
    )..where((t) => t.id.isIn(ids))).get();
    final messages = {for (final row in found) row.id: _message(row)};
    return [
      for (final row in rows)
        if (messages[row.read<String>('message_id')] case final message?)
          ChatSearchHit(
            chatId: row.read<String>('chat_id'),
            chatTitle: row.read<String>('chat_title'),
            message: message,
          ),
    ];
  }

  static String? _ftsQuery(String query) {
    final terms = query
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .map((t) => '"${t.replaceAll('"', '""')}"')
        .join(' ');
    return terms.isEmpty ? null : terms;
  }

  /// Удаляет одно сообщение и его запись в поиске.
  ///
  /// Нужно правке: заметка о просроченной задаче стоит отдельным событием перед
  /// промптом и должна уходить вместе с ним.
  Future<void> deleteMessage(String id) async {
    final row = await (_db.select(
      _messagesTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    await _db.customStatement(
      'DELETE FROM message_search WHERE message_id = ?',
      [id],
    );
    await (_db.delete(_messagesTable)..where((t) => t.id.equals(id))).go();
    if (row != null) await _recomputeReadState(row.chatId);
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
    await _recomputeReadState(chatId);
    return ids;
  }

  // ---- read state --------------------------------------------------------

  /// Сдвигает общий курсор прочтения вперёд и возвращает чат с новым unread.
  ///
  /// [seq] ограничивается серверным `lastMessageSeq`: клиент не может
  /// случайно (или из устаревшего снимка) прочитать сообщения, которых он не
  /// видел. Курсор не двигается назад; поздний запрос с меньшим `seq` — no-op.
  /// [expectedRevision] проверяется, только если передан.
  Future<Chat> markRead(
    String chatId, {
    required int seq,
    int? expectedRevision,
  }) => _db.transaction(() async {
    final entry = await _chatEntry(chatId);
    if (entry == null) {
      throw AgentApiException(404, 'chat_not_found', 'chat $chatId not found');
    }
    final read = entry.read;
    final currentRevision = read?.readRevision ?? 0;
    if (expectedRevision != null && expectedRevision != currentRevision) {
      throw const AgentApiException(
        409,
        'read_conflict',
        'read cursor revision changed',
      );
    }
    // Последний seq читаем из сообщений, а не из счётчика: так устаревшая
    // строка read state не может ограничить курсор слишком рано.
    final lastMessage = await _maxSeq(chatId);
    final target = seq <= 0 ? 0 : (seq > lastMessage ? lastMessage : seq);
    final currentRead = read?.lastReadSeq ?? 0;
    if (target <= currentRead) return _chat(entry.chat, read);
    final unread = await _unreadCount(chatId, target);
    final nextRevision = currentRevision + 1;
    await _writeReadState(
      chatId,
      lastMessageSeq: lastMessage,
      lastReadSeq: target,
      unreadCount: unread,
      readRevision: nextRevision,
    );
    return _chat(
      entry.chat,
      ChatReadRow(
        chatId: chatId,
        lastMessageSeq: lastMessage,
        lastReadSeq: target,
        unreadCount: unread,
        readRevision: nextRevision,
      ),
    );
  });

  Future<ChatReadRow?> _readRow(String chatId) => (_db.select(
    _readTable,
  )..where((t) => t.chatId.equals(chatId))).getSingleOrNull();

  Future<int> _maxSeq(String chatId) async {
    final max = _messagesTable.seq.max();
    final row =
        await (_db.selectOnly(_messagesTable)
              ..addColumns([max])
              ..where(_messagesTable.chatId.equals(chatId)))
            .getSingle();
    return row.read(max) ?? 0;
  }

  /// Непрочитанное — сообщения агента и служебные строки после [fromSeq].
  ///
  /// Собственные сообщения пользователя и результаты инструментов не должны
  /// поднимать счётчик: они либо уже видны отправителю, либо не рисуются в ленте.
  Future<int> _unreadCount(String chatId, int fromSeq) async {
    final count = _messagesTable.id.count();
    final query = _db.selectOnly(_messagesTable)
      ..addColumns([count])
      ..where(
        _messagesTable.chatId.equals(chatId) &
            _messagesTable.seq.isBiggerThanValue(fromSeq) &
            _messagesTable.role.isIn([
              MessageRole.assistant.name,
              MessageRole.event.name,
            ]),
      );
    final row = await query.getSingle();
    return row.read(count) ?? 0;
  }

  Future<void> _writeReadState(
    String chatId, {
    required int lastMessageSeq,
    required int lastReadSeq,
    required int unreadCount,
    required int readRevision,
  }) => _db
      .into(_readTable)
      .insertOnConflictUpdate(
        ChatReadStatesCompanion.insert(
          chatId: chatId,
          lastMessageSeq: Value(lastMessageSeq),
          lastReadSeq: Value(lastReadSeq),
          unreadCount: Value(unreadCount),
          readRevision: Value(readRevision),
        ),
      );

  /// Обновляет счётчик после нового сообщения.
  ///
  /// Считать заново всю историю на каждое сообщение дороже, чем хранить
  /// счётчик: при вставке он меняется на единицу, а при удалении
  /// пересчитывается точно (см. [_recomputeReadState]).
  Future<void> _bumpReadState(ChatMessage message) async {
    final read = await _readRow(message.chatId);
    final lastRead = read?.lastReadSeq ?? 0;
    final lastMessage = read?.lastMessageSeq ?? 0;
    final unread =
        (read?.unreadCount ?? 0) +
        (_isUnreadRole(message.role) && message.seq > lastRead ? 1 : 0);
    await _writeReadState(
      message.chatId,
      lastMessageSeq: message.seq > lastMessage ? message.seq : lastMessage,
      lastReadSeq: lastRead,
      unreadCount: unread,
      readRevision: read?.readRevision ?? 0,
    );
  }

  /// Пересчитывает курсор и счётчик после удаления сообщений.
  ///
  /// Курсор не может оказаться выше последнего сообщения: `nextSeq` берёт
  /// максимум по оставшимся, поэтому удалённый номер снова достанется новому
  /// сообщению. Без ограничения такое сообщение выглядело бы прочитанным, а
  /// после перезаписи истории (правка, перегенерация, «удалить после») курсор
  /// откатывается к последнему уцелевшему сообщению именно по этой причине.
  /// Это единственное исключение из монотонности курсора.
  Future<void> _recomputeReadState(String chatId) async {
    final read = await _readRow(chatId);
    if (read == null) return;
    final lastMessage = await _maxSeq(chatId);
    final lastRead = read.lastReadSeq > lastMessage
        ? lastMessage
        : read.lastReadSeq;
    final unread = await _unreadCount(chatId, lastRead);
    final changed =
        lastMessage != read.lastMessageSeq ||
        lastRead != read.lastReadSeq ||
        unread != read.unreadCount;
    await _writeReadState(
      chatId,
      lastMessageSeq: lastMessage,
      lastReadSeq: lastRead,
      unreadCount: unread,
      readRevision: read.readRevision + (changed ? 1 : 0),
    );
  }

  static bool _isUnreadRole(MessageRole role) =>
      role == MessageRole.assistant || role == MessageRole.event;

  // ---- attention ---------------------------------------------------------

  /// Проблемные завершения ходов, которые ещё ждут пользователя.
  ///
  /// Входящие строятся по снимку чатов и этому состоянию. Поток отдельный,
  /// потому что запись не меняет `updatedAt` и не должна переставлять чаты
  /// в списке.
  Stream<List<ChatAttentionRecord>> watchAttentionStates() => _db
      .select(_attentionTable)
      .watch()
      .map(
        (rows) => [
          for (final row in rows)
            ChatAttentionRecord(
              chatId: row.chatId,
              turn:
                  ChatAttentionTurn.fromStorage(row.turn) ??
                  // Неизвестное значение читается как ошибка: лучше лишний
                  // раз показать проблему, чем молча потерять её.
                  ChatAttentionTurn.failed,
              occurredAt: row.occurredAt,
              revision: row.revision,
            ),
        ],
      );

  /// Запоминает проблемное завершение хода.
  ///
  /// Одна строка на чат: новый проблемный ход заменяет предыдущий, а его
  /// ревизия растёт, чтобы окна не приняли старый снимок за свежий.
  Future<void> recordAttention(
    String chatId,
    ChatAttentionTurn turn, {
    required DateTime occurredAt,
  }) => _db.transaction(() async {
    final current = await (_db.select(
      _attentionTable,
    )..where((t) => t.chatId.equals(chatId))).getSingleOrNull();
    await _db
        .into(_attentionTable)
        .insertOnConflictUpdate(
          ChatAttentionStatesCompanion.insert(
            chatId: chatId,
            turn: turn.name,
            occurredAt: occurredAt,
            revision: Value((current?.revision ?? 0) + 1),
          ),
        );
  });

  /// Снимает проблемное завершение хода: начался новый ход или пользователь
  /// разобрал его во входящих.
  Future<void> clearAttention(String chatId) =>
      (_db.delete(_attentionTable)..where((t) => t.chatId.equals(chatId))).go();

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
          resultError: Value(run.resultError),
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

  /// Один запуск по id. Нужен чтению полного вывода и остановке фоновой команды.
  Future<ToolRun?> toolRun(String id) async {
    final row = await (_db.select(
      _toolRunsTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _toolRun(row);
  }

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

  Chat _chat(ChatRow row, [ChatReadRow? read]) => Chat(
    id: row.id,
    hostId: row.hostId,
    kind: ChatKind.values.byName(row.kind),
    parentChatId: row.parentChatId,
    rootChatId: row.rootChatId,
    depth: row.depth,
    projectId: row.projectId,
    title: row.title,
    titleSource: ChatTitleSource.values.byName(row.titleSource),
    model: row.model,
    reasoning: ReasoningPreference.parse(row.reasoning),
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
      mentions: [
        for (final json in jsonDecode(row.draftMentions) as List<dynamic>)
          MentionRef.fromJson(json as Map<String, dynamic>),
      ],
    ),
    messageEdits: decodeMessageEdits(row.messageEdits),
    draftRevision: row.draftRevision,
    messageEditsRevision: row.messageEditsRevision,
    revision: row.revision,
    lastReadSeq: read?.lastReadSeq ?? 0,
    readRevision: read?.readRevision ?? 0,
    lastMessageSeq: read?.lastMessageSeq ?? 0,
    unreadCount: read?.unreadCount ?? 0,
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
    clientMessageId: row.clientMessageId,
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
    resultError: row.resultError,
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

/// Результат FTS-поиска по нескольким чатам.
final class ChatSearchHit {
  const ChatSearchHit({
    required this.chatId,
    required this.chatTitle,
    required this.message,
  });

  final String chatId;
  final String chatTitle;
  final ChatMessage message;
}

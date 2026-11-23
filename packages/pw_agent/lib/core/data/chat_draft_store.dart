import 'dart:async';

import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/draft_persistence.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';

/// Вид черновика, для которого возник конфликт.
enum DraftConflictKind { draft, messageEdits }

/// Один конфликт: локальная версия не перезаписывается серверной молча.
final class DraftConflict {
  const DraftConflict({
    required this.chatId,
    required this.kind,
    required this.remoteRevision,
    this.local,
    this.remote,
    this.localEdits,
    this.remoteEdits,
  });

  final String chatId;
  final DraftConflictKind kind;

  /// Ревизия, которую сервер считает актуальной. С ней сохраняется
  /// выбранный локальный вариант.
  final int remoteRevision;

  final ChatDraft? local;
  final ChatDraft? remote;
  final Map<String, ChatDraft>? localEdits;
  final Map<String, ChatDraft>? remoteEdits;
}

/// Черновики полей ввода и неотправленных правок по чатам. Актуальная версия держится в памяти:
/// переключение чата и создание нового читают её сразу, без ожидания БД. В БД запись идёт с небольшой
/// задержкой, пока пользователь печатает, и сразу при закрытии чата, переносе и выходе из приложения.
@lazySingleton
class ChatDraftStore {
  ChatDraftStore(this._chats);

  /// Черновик без backend'а: нужен в daemon-режиме до привязки профиля.
  ChatDraftStore.unbound() : _chats = const _NoopDraftPersistence();

  DraftPersistence _chats;

  final _drafts = <String, ChatDraft>{};
  final _edits = <String, Map<String, ChatDraft>>{};
  final _draftRevisions = <String, int>{};
  final _editRevisions = <String, int>{};
  final _dirty = <String>{};
  final _editsDirty = <String>{};
  final _conflicts = <String, List<DraftConflict>>{};
  final _conflictChanges = StreamController<DraftConflict>.broadcast();

  /// Конфликты, которые ждут решения пользователя. У чата может быть
  /// одновременно конфликт черновика и конфликт правок сообщений.
  Stream<DraftConflict> get conflicts => _conflictChanges.stream;

  /// Первый нерешённый конфликт чата (сначала черновик, затем правки).
  DraftConflict? conflictFor(String chatId) {
    final conflicts = _conflicts[chatId];
    return conflicts == null || conflicts.isEmpty ? null : conflicts.first;
  }

  DraftConflict? _conflictFor(String chatId, DraftConflictKind kind) {
    final conflicts = _conflicts[chatId];
    if (conflicts == null) return null;
    for (final conflict in conflicts) {
      if (conflict.kind == kind) return conflict;
    }
    return null;
  }

  void _removeConflict(String chatId, DraftConflictKind kind) {
    final conflicts = _conflicts[chatId];
    if (conflicts == null) return;
    conflicts.removeWhere((conflict) => conflict.kind == kind);
    if (conflicts.isEmpty) _conflicts.remove(chatId);
  }

  /// Привязывает хранилище к backend'у профиля: локальной БД или HTTP API.
  ///
  /// Незаписанный черновик предыдущего профиля отправляется в старый backend
  /// до переключения, иначе он мог бы уйти в чужой профиль.
  void bind(DraftPersistence backend) {
    if (identical(_chats, backend)) return;
    final previous = _chats;
    _chats = backend;
    unawaited(_flushTo(previous));
  }

  Timer? _timer;

  static const _saveDelay = Duration(milliseconds: 500);

  /// Черновик чата из памяти. Если в памяти его нет — из [fallback] (запись из списка чатов).
  ChatDraft of(String chatId, {Chat? fallback}) =>
      _drafts[chatId] ?? fallback?.draft ?? ChatDraft.empty;

  /// Запоминает черновик и правки из записи чата, если в памяти их ещё нет.
  /// Возвращает true, если запомнил хотя бы одно.
  bool prime(String chatId, Chat? stored) {
    if (stored == null) return false;
    final draftRevision = _draftRevisions[chatId];
    final editRevision = _editRevisions[chatId];
    final draftDirty = _dirty.contains(chatId);
    final editsDirty = _editsDirty.contains(chatId);
    if (draftRevision != null &&
        stored.draftRevision > draftRevision &&
        !draftDirty) {
      _drafts[chatId] = stored.draft;
      _draftRevisions[chatId] = stored.draftRevision;
    }
    if (editRevision != null &&
        stored.messageEditsRevision > editRevision &&
        !editsDirty) {
      _edits[chatId] = stored.messageEdits;
      _editRevisions[chatId] = stored.messageEditsRevision;
    }
    var added = false;
    if (!_drafts.containsKey(chatId)) {
      _drafts[chatId] = stored.draft;
      added = true;
    }
    if (!_edits.containsKey(chatId)) {
      _edits[chatId] = stored.messageEdits;
      added = true;
    }
    _draftRevisions.putIfAbsent(chatId, () => stored.draftRevision);
    _editRevisions.putIfAbsent(chatId, () => stored.messageEditsRevision);
    return added;
  }

  /// Новый черновик чата: сразу в памяти, в БД — с задержкой.
  void update(String chatId, ChatDraft draft) {
    if (_drafts[chatId] == draft) return;
    _drafts[chatId] = draft;
    _dirty.add(chatId);
    _schedule();
  }

  /// Неотправленные правки сообщений чата. Пустая карта, если их не было.
  Map<String, ChatDraft> editsOf(String chatId, {Chat? fallback}) =>
      _edits[chatId] ?? fallback?.messageEdits ?? const {};

  /// Черновик правки одного сообщения или null, если пользователь его не менял.
  ChatDraft? editOf(String chatId, String messageId) =>
      editsOf(chatId)[messageId];

  /// Запоминает правку сообщения. Пустой текст тоже хранится: пользователь мог стереть
  /// исходный текст и уйти, а потом вернуться к пустому полю.
  void updateEdit(String chatId, String messageId, ChatDraft draft) {
    final current = Map<String, ChatDraft>.of(_edits[chatId] ?? const {});
    if (current[messageId] == draft) return;
    current[messageId] = draft;
    _edits[chatId] = current;
    _editsDirty.add(chatId);
    _schedule();
  }

  /// Убирает правку: сообщение отправили или текст снова совпал с исходным.
  void removeEdit(String chatId, String messageId) {
    final current = _edits[chatId];
    if (current == null || !current.containsKey(messageId)) return;
    _edits[chatId] = Map<String, ChatDraft>.of(current)..remove(messageId);
    _editsDirty.add(chatId);
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(_saveDelay, () => unawaited(flush()));
  }

  /// Переносит черновик из [fromId] в [toId] (например, в только что созданный чат) и очищает исходный.
  Future<void> move(String fromId, String toId, {Chat? fallback}) async {
    final draft = of(fromId, fallback: fallback);
    if (draft.isEmpty) return;
    update(toId, draft);
    update(fromId, ChatDraft.empty);
    await flush();
  }

  /// Записывает все изменённые черновики в текущий backend.
  Future<void> flush() => _flushTo(_chats);

  Future<void> _flushTo(DraftPersistence backend) async {
    _timer?.cancel();
    _timer = null;
    final ids = _dirty.toList();
    final editIds = _editsDirty.toList();
    _dirty.clear();
    _editsDirty.clear();
    for (final id in ids) {
      await _saveDraft(id, backend);
    }
    for (final id in editIds) {
      await _saveEdits(id, backend);
    }
  }

  Future<void> _saveDraft(String id, DraftPersistence backend) async {
    try {
      _draftRevisions[id] = await backend.saveDraft(
        id,
        _drafts[id] ?? ChatDraft.empty,
        expectedRevision: _draftRevisions[id],
      );
      _removeConflict(id, DraftConflictKind.draft);
    } on AgentApiException catch (error) {
      if (error.code == 'draft_conflict') {
        await _rememberConflict(id, backend, DraftConflictKind.draft);
      } else {
        _dirty.add(id);
      }
    }
  }

  Future<void> _saveEdits(String id, DraftPersistence backend) async {
    try {
      _editRevisions[id] = await backend.saveMessageEdits(
        id,
        _edits[id] ?? const {},
        expectedRevision: _editRevisions[id],
      );
      _removeConflict(id, DraftConflictKind.messageEdits);
    } on AgentApiException catch (error) {
      if (error.code == 'draft_conflict') {
        await _rememberConflict(id, backend, DraftConflictKind.messageEdits);
      } else {
        _editsDirty.add(id);
      }
    }
  }

  Future<void> _rememberConflict(
    String id,
    DraftPersistence backend,
    DraftConflictKind kind,
  ) async {
    try {
      final chat = await backend.chat(id);
      if (chat == null) {
        _markDirty(id, kind);
        return;
      }
      final conflict = kind == DraftConflictKind.draft
          ? DraftConflict(
              chatId: id,
              kind: kind,
              remoteRevision: chat.draftRevision,
              local: _drafts[id] ?? ChatDraft.empty,
              remote: chat.draft,
            )
          : DraftConflict(
              chatId: id,
              kind: kind,
              remoteRevision: chat.messageEditsRevision,
              localEdits: _edits[id] ?? const {},
              remoteEdits: chat.messageEdits,
            );
      _conflicts.putIfAbsent(id, () => [])
        ..removeWhere((item) => item.kind == kind)
        ..add(conflict);
      // Новые правки, появившиеся во время загрузки серверного снимка,
      // остаются грязными и будут отправлены следующим flush.
      if (!_conflictChanges.isClosed) _conflictChanges.add(conflict);
    } on Object {
      // Оставляем изменение грязным: следующая запись повторит попытку.
      _markDirty(id, kind);
    }
  }

  void _markDirty(String id, DraftConflictKind kind) {
    if (kind == DraftConflictKind.draft) {
      _dirty.add(id);
    } else {
      _editsDirty.add(id);
    }
  }

  /// Принимает версию чата с сервера: например, после SSE о чужом изменении.
  /// Возвращает true, если версия действительно новее локальной.
  bool applyRemote(String chatId, Chat chat) {
    final draftRevision = _draftRevisions[chatId];
    final editRevision = _editRevisions[chatId];
    final draftChanged =
        _conflictFor(chatId, DraftConflictKind.draft) == null &&
        !_dirty.contains(chatId) &&
        (draftRevision == null || chat.draftRevision > draftRevision);
    final editsChanged =
        _conflictFor(chatId, DraftConflictKind.messageEdits) == null &&
        !_editsDirty.contains(chatId) &&
        (editRevision == null || chat.messageEditsRevision > editRevision);
    if (!draftChanged && !editsChanged) return false;
    if (draftChanged) {
      _drafts[chatId] = chat.draft;
      _draftRevisions[chatId] = chat.draftRevision;
    }
    if (editsChanged) {
      _edits[chatId] = chat.messageEdits;
      _editRevisions[chatId] = chat.messageEditsRevision;
    }
    return true;
  }

  /// Оставляет локальный вариант и повторяет сохранение с ревизией,
  /// которую сервер считал актуальной на момент конфликта.
  Future<void> keepLocal(String chatId, {DraftConflictKind? kind}) async {
    final conflict = kind == null
        ? conflictFor(chatId)
        : _conflictFor(chatId, kind);
    if (conflict == null) return;
    _removeConflict(chatId, conflict.kind);
    if (conflict.kind == DraftConflictKind.draft) {
      _drafts[chatId] = conflict.local ?? ChatDraft.empty;
      _draftRevisions[chatId] = conflict.remoteRevision;
      _dirty.add(chatId);
    } else {
      _edits[chatId] = conflict.localEdits ?? const {};
      _editRevisions[chatId] = conflict.remoteRevision;
      _editsDirty.add(chatId);
    }
    await flush();
  }

  /// Принимает серверный вариант и снимает конфликт.
  void acceptRemote(String chatId, {DraftConflictKind? kind}) {
    final conflict = kind == null
        ? conflictFor(chatId)
        : _conflictFor(chatId, kind);
    if (conflict == null) return;
    _removeConflict(chatId, conflict.kind);
    if (conflict.kind == DraftConflictKind.draft) {
      _drafts[chatId] = conflict.remote ?? ChatDraft.empty;
      _draftRevisions[chatId] = conflict.remoteRevision;
      _dirty.remove(chatId);
    } else {
      _edits[chatId] = conflict.remoteEdits ?? const {};
      _editRevisions[chatId] = conflict.remoteRevision;
      _editsDirty.remove(chatId);
    }
  }

  /// Чат удалён: его черновик и правки больше не нужны.
  void discard(String chatId) {
    _drafts.remove(chatId);
    _dirty.remove(chatId);
    _edits.remove(chatId);
    _editsDirty.remove(chatId);
    _draftRevisions.remove(chatId);
    _editRevisions.remove(chatId);
    _conflicts.remove(chatId);
  }

  /// Закрывает поток конфликтов при остановке приложения.
  Future<void> dispose() => _conflictChanges.close();
}

final class _NoopDraftPersistence implements DraftPersistence {
  const _NoopDraftPersistence();

  @override
  Future<Chat?> chat(String id) async => null;

  @override
  Future<int> saveDraft(
    String chatId,
    ChatDraft draft, {
    int? expectedRevision,
  }) async => expectedRevision ?? 0;

  @override
  Future<int> saveMessageEdits(
    String chatId,
    Map<String, ChatDraft> edits, {
    int? expectedRevision,
  }) async => expectedRevision ?? 0;
}

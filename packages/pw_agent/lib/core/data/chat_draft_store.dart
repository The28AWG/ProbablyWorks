import 'dart:async';

import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/draft_persistence.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';

/// Черновики полей ввода и неотправленных правок по чатам. Актуальная версия держится в памяти:
/// переключение чата и создание нового читают её сразу, без ожидания БД. В БД запись идёт с небольшой
/// задержкой, пока пользователь печатает, и сразу при закрытии чата, переносе и выходе из приложения.
@lazySingleton
class ChatDraftStore {
  ChatDraftStore(this._chats);

  DraftPersistence _chats;

  final _drafts = <String, ChatDraft>{};
  final _edits = <String, Map<String, ChatDraft>>{};
  final _revisions = <String, int>{};
  final _dirty = <String>{};
  final _editsDirty = <String>{};

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
    final revision = _revisions[chatId];
    final dirty = _dirty.contains(chatId) || _editsDirty.contains(chatId);
    if (revision != null && stored.draftRevision > revision && !dirty) {
      _drafts[chatId] = stored.draft;
      _edits[chatId] = stored.messageEdits;
      _revisions[chatId] = stored.draftRevision;
      return true;
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
    _revisions.putIfAbsent(chatId, () => stored.draftRevision);
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
      _revisions[id] = await backend.saveDraft(
        id,
        _drafts[id] ?? ChatDraft.empty,
        expectedRevision: _revisions[id],
      );
    } on AgentApiException catch (error) {
      if (error.code == 'draft_conflict') {
        await _reload(id, backend);
      } else {
        _dirty.add(id);
      }
    }
  }

  Future<void> _saveEdits(String id, DraftPersistence backend) async {
    try {
      _revisions[id] = await backend.saveMessageEdits(
        id,
        _edits[id] ?? const {},
        expectedRevision: _revisions[id],
      );
    } on AgentApiException catch (error) {
      if (error.code == 'draft_conflict') {
        await _reload(id, backend);
      } else {
        _editsDirty.add(id);
      }
    }
  }

  /// Принимает версию чата с сервера: например, после SSE о чужом изменении.
  /// Возвращает true, если версия действительно новее локальной.
  bool applyRemote(String chatId, Chat chat) {
    // Пока пользователь печатает, его неотправленный текст не затираем чужим SSE.
    if (_dirty.contains(chatId) || _editsDirty.contains(chatId)) return false;
    final current = _revisions[chatId];
    if (current != null && chat.draftRevision <= current) return false;
    _drafts[chatId] = chat.draft;
    _edits[chatId] = chat.messageEdits;
    _revisions[chatId] = chat.draftRevision;
    _dirty.remove(chatId);
    _editsDirty.remove(chatId);
    return true;
  }

  Future<void> _reload(String chatId, DraftPersistence backend) async {
    try {
      final chat = await backend.chat(chatId);
      if (chat != null) applyRemote(chatId, chat);
    } on Object {
      // Следующее открытие или SSE попробует снова.
    }
  }

  /// Чат удалён: его черновик и правки больше не нужны.
  void discard(String chatId) {
    _drafts.remove(chatId);
    _dirty.remove(chatId);
    _edits.remove(chatId);
    _editsDirty.remove(chatId);
    _revisions.remove(chatId);
  }
}

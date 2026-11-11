import 'dart:async';

import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/core/data/chat_repository.dart';

/// Черновики полей ввода и неотправленных правок по чатам. Актуальная версия держится в памяти:
/// переключение чата и создание нового читают её сразу, без ожидания БД. В БД запись идёт с небольшой
/// задержкой, пока пользователь печатает, и сразу при закрытии чата, переносе и выходе из приложения.
@lazySingleton
class ChatDraftStore {
  ChatDraftStore(this._chats);

  final ChatRepository _chats;

  final _drafts = <String, ChatDraft>{};
  final _edits = <String, Map<String, ChatDraft>>{};
  final _dirty = <String>{};
  final _editsDirty = <String>{};
  Timer? _timer;

  static const _saveDelay = Duration(milliseconds: 500);

  /// Черновик чата из памяти. Если в памяти его нет — из [fallback] (запись из списка чатов).
  ChatDraft of(String chatId, {Chat? fallback}) =>
      _drafts[chatId] ?? fallback?.draft ?? ChatDraft.empty;

  /// Запоминает черновик и правки из записи чата, если в памяти их ещё нет.
  /// Возвращает true, если запомнил хотя бы одно.
  bool prime(String chatId, Chat? stored) {
    if (stored == null) return false;
    var added = false;
    if (!_drafts.containsKey(chatId)) {
      _drafts[chatId] = stored.draft;
      added = true;
    }
    if (!_edits.containsKey(chatId)) {
      _edits[chatId] = stored.messageEdits;
      added = true;
    }
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

  /// Записывает в БД все изменённые черновики.
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    final ids = _dirty.toList();
    final editIds = _editsDirty.toList();
    _dirty.clear();
    _editsDirty.clear();
    for (final id in ids) {
      await _chats.saveDraft(id, _drafts[id] ?? ChatDraft.empty);
    }
    for (final id in editIds) {
      await _chats.saveMessageEdits(id, _edits[id] ?? const {});
    }
  }

  /// Чат удалён: его черновик и правки больше не нужны.
  void discard(String chatId) {
    _drafts.remove(chatId);
    _dirty.remove(chatId);
    _edits.remove(chatId);
    _editsDirty.remove(chatId);
  }
}

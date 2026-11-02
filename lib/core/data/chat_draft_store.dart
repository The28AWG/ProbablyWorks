import 'dart:async';

import 'package:injectable/injectable.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/core/data/chat_repository.dart';

/// Черновики полей ввода по чатам. Актуальная версия держится в памяти: переключение чата и создание
/// нового читают её сразу, без ожидания БД. В БД черновик пишется с небольшой задержкой, пока пользователь
/// печатает, и сразу при закрытии чата, переносе и выходе из приложения.
@lazySingleton
class ChatDraftStore {
  ChatDraftStore(this._chats);

  final ChatRepository _chats;

  final _drafts = <String, ChatDraft>{};
  final _dirty = <String>{};
  Timer? _timer;

  static const _saveDelay = Duration(milliseconds: 500);

  /// Черновик чата из памяти. Если в памяти его нет — из [fallback] (запись из списка чатов).
  ChatDraft of(String chatId, {Chat? fallback}) =>
      _drafts[chatId] ?? fallback?.draft ?? ChatDraft.empty;

  /// Запоминает черновик из записи чата, если в памяти его ещё нет. Возвращает true, если запомнил.
  bool prime(String chatId, Chat? stored) {
    if (stored == null || _drafts.containsKey(chatId)) return false;
    _drafts[chatId] = stored.draft;
    return true;
  }

  /// Новый черновик чата: сразу в памяти, в БД — с задержкой.
  void update(String chatId, ChatDraft draft) {
    if (_drafts[chatId] == draft) return;
    _drafts[chatId] = draft;
    _dirty.add(chatId);
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
    _dirty.clear();
    for (final id in ids) {
      await _chats.saveDraft(id, _drafts[id] ?? ChatDraft.empty);
    }
  }

  /// Чат удалён: его черновик больше не нужен.
  void discard(String chatId) {
    _drafts.remove(chatId);
    _dirty.remove(chatId);
  }
}

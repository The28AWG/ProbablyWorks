import 'dart:async';

import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/chat_api.dart';
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

  /// Черновик из попытки, ответ на которую потерян.
  ///
  /// Он мог уже записаться на сервере. При следующем конфликте сверяем
  /// серверную версию с этим снимком, а не с текущим текстом: пока ответ
  /// терялся, пользователь мог продолжить печатать.
  final _unconfirmedDrafts = <String, ChatDraft>{};
  final _unconfirmedEdits = <String, Map<String, ChatDraft>>{};

  final _conflicts = <String, List<DraftConflict>>{};
  final _conflictChanges = StreamController<DraftConflict>.broadcast();
  Future<void>? _flushing;
  bool _flushAgain = false;

  /// Сколько раз подряд запись не удалась. Растёт только при сбое, сбрасывается
  /// при новой правке пользователя: иначе недоступный сервер получал бы запрос
  /// каждые полсекунды бесконечно.
  var _retryAttempt = 0;

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

  /// Пауза перед повтором после сбоя: растёт вдвое и упирается в [_retryMaxDelay].
  static const _retryBaseDelay = Duration(seconds: 2);
  static const _retryMaxDelay = Duration(seconds: 30);
  static const _maxRetryShift = 4;

  /// Черновик чата из памяти. Если в памяти его нет — из [fallback] (запись из списка чатов).
  ChatDraft of(String chatId, {Chat? fallback}) =>
      _drafts[chatId] ?? fallback?.draft ?? ChatDraft.empty;

  /// Запоминает черновик и правки из записи чата, если в памяти их ещё нет
  /// или серверная версия новее.
  ///
  /// Возвращает true, если изменился сам черновик или набор правок. Этим
  /// пользуется открытие чата: если серверная версия новее, поле ввода нужно
  /// переписать, даже когда запись в памяти уже была.
  bool prime(String chatId, Chat? stored) {
    if (stored == null) return false;
    _updateConflictRemote(chatId, stored);
    final draftRevision = _draftRevisions[chatId];
    final editRevision = _editRevisions[chatId];
    final draftDirty = _dirty.contains(chatId);
    final editsDirty = _editsDirty.contains(chatId);
    final draftConflict = _conflictFor(chatId, DraftConflictKind.draft);
    final editsConflict = _conflictFor(chatId, DraftConflictKind.messageEdits);
    var changed = false;
    if (draftConflict == null &&
        !draftDirty &&
        (draftRevision == null || stored.draftRevision > draftRevision)) {
      if (_drafts[chatId] != stored.draft) changed = true;
      _drafts[chatId] = stored.draft;
      _draftRevisions[chatId] = stored.draftRevision;
    }
    if (editsConflict == null &&
        !editsDirty &&
        (editRevision == null || stored.messageEditsRevision > editRevision)) {
      if (!_sameEdits(_edits[chatId], stored.messageEdits)) changed = true;
      _edits[chatId] = stored.messageEdits;
      _editRevisions[chatId] = stored.messageEditsRevision;
    }
    if (!_drafts.containsKey(chatId)) {
      _drafts[chatId] = draftConflict?.local ?? stored.draft;
      changed = true;
    }
    if (!_edits.containsKey(chatId)) {
      _edits[chatId] = editsConflict?.localEdits ?? stored.messageEdits;
      changed = true;
    }
    _draftRevisions.putIfAbsent(chatId, () => stored.draftRevision);
    _editRevisions.putIfAbsent(chatId, () => stored.messageEditsRevision);
    return changed;
  }

  /// Новый черновик чата: сразу в памяти, в БД — с задержкой.
  void update(String chatId, ChatDraft draft) {
    if (_drafts[chatId] == draft) return;
    _drafts[chatId] = draft;
    _dirty.add(chatId);
    _scheduleEdit();
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
    _scheduleEdit();
  }

  /// Убирает правку: сообщение отправили или текст снова совпал с исходным.
  void removeEdit(String chatId, String messageId) {
    final current = _edits[chatId];
    if (current == null || !current.containsKey(messageId)) return;
    _edits[chatId] = Map<String, ChatDraft>.of(current)..remove(messageId);
    _editsDirty.add(chatId);
    _scheduleEdit();
  }

  void _schedule([Duration delay = _saveDelay]) {
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(flush()));
  }

  /// Отложенная запись после правки пользователя: короткая пауза, повторы
  /// сбрасываются — данные появились заново.
  void _scheduleEdit() {
    _retryAttempt = 0;
    _schedule();
  }

  /// Повтор после сбоя с удвоением паузы. Растущая задержка не даёт
  /// недоступному серверу получать запрос на каждое событие.
  void _scheduleRetry() {
    final shift = _retryAttempt > _maxRetryShift
        ? _maxRetryShift
        : _retryAttempt;
    final millis = _retryBaseDelay.inMilliseconds * (1 << shift);
    final delay = millis > _retryMaxDelay.inMilliseconds
        ? _retryMaxDelay
        : Duration(milliseconds: millis);
    if (_retryAttempt < _maxRetryShift) _retryAttempt++;
    _schedule(delay);
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
  ///
  /// Параллельные вызовы не запускают вторую запись: второй вызов только
  /// просит текущий цикл пройти ещё раз. Это не даёт двум запросам уйти с
  /// одной `expectedRevision` и получить ложный конфликт.
  Future<void> flush() {
    final running = _flushing;
    if (running != null) {
      _flushAgain = true;
      return running;
    }
    final future = _flushLoop();
    _flushing = future;
    return future;
  }

  Future<void> _flushLoop() async {
    try {
      do {
        _flushAgain = false;
        await _flushTo(_chats);
      } while (_flushAgain && (_dirty.isNotEmpty || _editsDirty.isNotEmpty));
    } finally {
      _flushing = null;
    }
  }

  Future<void> _flushTo(DraftPersistence backend) async {
    _timer?.cancel();
    _timer = null;
    final ids = _dirty.toList();
    final editIds = _editsDirty.toList();
    _dirty.removeAll(ids);
    _editsDirty.removeAll(editIds);
    var failed = false;
    for (final id in ids) {
      if (await _saveDraft(id, backend)) failed = true;
    }
    for (final id in editIds) {
      if (await _saveEdits(id, backend)) failed = true;
    }
    // Повтор только после сбоя. Если грязными остались свежие правки, их
    // запись уже запланирована `_scheduleEdit`.
    if (failed) _scheduleRetry();
  }

  /// Сохраняет черновик. `true` — изменение осталось несохранённым и требует
  /// повтора; `false` — записано, разрешено конфликтом или уже не нужно.
  Future<bool> _saveDraft(String id, DraftPersistence backend) async {
    final draft = _drafts[id] ?? ChatDraft.empty;
    try {
      _draftRevisions[id] = await backend.saveDraft(
        id,
        draft,
        expectedRevision: _draftRevisions[id],
      );
      _unconfirmedDrafts.remove(id);
      _removeConflict(id, DraftConflictKind.draft);
      return false;
    } on AgentApiException catch (error) {
      if (error.code == 'draft_conflict') {
        return _rememberConflict(id, backend, DraftConflictKind.draft);
      }
      if (_isTerminal(error)) {
        // Чат удалён или токен отозван: повтор не поможет и только крутит цикл.
        discard(id);
        return false;
      }
      // Ответ мог потеряться уже после записи на сервере: запоминаем, что
      // именно ушло, чтобы следующий конфликт не считался чужим изменением.
      _unconfirmedDrafts[id] = draft;
      _markDirty(id, DraftConflictKind.draft);
      return true;
    } on Object {
      // Сеть, таймаут или битый ответ: изменение не должно исчезнуть.
      _unconfirmedDrafts[id] = draft;
      _markDirty(id, DraftConflictKind.draft);
      return true;
    }
  }

  /// Сохраняет правки сообщений. См. [_saveDraft] о возвращаемом значении.
  Future<bool> _saveEdits(String id, DraftPersistence backend) async {
    final edits = _edits[id] ?? const {};
    try {
      _editRevisions[id] = await backend.saveMessageEdits(
        id,
        edits,
        expectedRevision: _editRevisions[id],
      );
      _unconfirmedEdits.remove(id);
      _removeConflict(id, DraftConflictKind.messageEdits);
      return false;
    } on AgentApiException catch (error) {
      if (error.code == 'draft_conflict') {
        return _rememberConflict(id, backend, DraftConflictKind.messageEdits);
      }
      if (_isTerminal(error)) {
        discard(id);
        return false;
      }
      _unconfirmedEdits[id] = edits;
      _markDirty(id, DraftConflictKind.messageEdits);
      return true;
    } on Object {
      // Сеть, таймаут или битый ответ: изменение не должно исчезнуть.
      _unconfirmedEdits[id] = edits;
      _markDirty(id, DraftConflictKind.messageEdits);
      return true;
    }
  }

  /// Ошибка, при которой повтор бессмысленен: чата больше нет или доступ
  /// отозван. Данные уже не восстановить, поэтому черновик убирается.
  static bool _isTerminal(AgentApiException error) =>
      error.code == 'chat_not_found' || error.code == 'unauthorized';

  /// Читает удалённую версию для конфликта.
  ///
  /// `true` — запись осталась грязной и требует повтора: серверный снимок не
  /// получен или после потерянного ответа у пользователя появился новый текст.
  Future<bool> _rememberConflict(
    String id,
    DraftPersistence backend,
    DraftConflictKind kind,
  ) async {
    try {
      final chat = backend is DraftRefreshSource
          ? await backend.chatForDraft(id)
          : await backend.chat(id);
      if (chat == null) {
        _markDirty(id, kind);
        return true;
      }
      // Ответ на первую запись мог потеряться: на сервере уже лежит ровно
      // наша версия, а повтор пришёл со старой ревизией. Это успех, а не
      // конфликт: обновляем ревизию и не показываем баннер пользователю.
      //
      // Сверяемся со снимком, который ушёл в потерянной попытке, а не с
      // текущим текстом: пока ответ терялся, пользователь мог напечатать
      // больше, и тогда текущий текст заведомо не совпадёт с серверным.
      final localDraft = _drafts[id] ?? ChatDraft.empty;
      if (kind == DraftConflictKind.draft) {
        final sentDraft = _unconfirmedDrafts.remove(id) ?? localDraft;
        // Совпадение с текущим текстом тоже успех: сервер уже содержит то,
        // что пользователь видит, и терять нечего.
        if (_sameDraft(sentDraft, chat.draft) ||
            _sameDraft(localDraft, chat.draft)) {
          _draftRevisions[id] = chat.draftRevision;
          _removeConflict(id, kind);
          if (!_sameDraft(localDraft, chat.draft)) {
            // Пользователь успел напечатать больше: этот текст ещё не на
            // сервере и уходит обычной отложенной записью, а не повтором сбоя.
            _markDirty(id, kind);
            _scheduleEdit();
          }
          return false;
        }
      }
      final localEdits = _edits[id] ?? const {};
      if (kind == DraftConflictKind.messageEdits) {
        final sentEdits = _unconfirmedEdits.remove(id) ?? localEdits;
        if (_sameEdits(sentEdits, chat.messageEdits) ||
            _sameEdits(localEdits, chat.messageEdits)) {
          _editRevisions[id] = chat.messageEditsRevision;
          _removeConflict(id, kind);
          if (!_sameEdits(localEdits, chat.messageEdits)) {
            _markDirty(id, kind);
            _scheduleEdit();
          }
          return false;
        }
      }
      final conflict = kind == DraftConflictKind.draft
          ? DraftConflict(
              chatId: id,
              kind: kind,
              remoteRevision: chat.draftRevision,
              local: localDraft,
              remote: chat.draft,
            )
          : DraftConflict(
              chatId: id,
              kind: kind,
              remoteRevision: chat.messageEditsRevision,
              localEdits: localEdits,
              remoteEdits: chat.messageEdits,
            );
      _conflicts.putIfAbsent(id, () => [])
        ..removeWhere((item) => item.kind == kind)
        ..add(conflict);
      // Новые правки, появившиеся во время загрузки серверного снимка,
      // остаются грязными и будут отправлены следующим flush.
      if (!_conflictChanges.isClosed) _conflictChanges.add(conflict);
      return false;
    } on Object {
      // Оставляем изменение грязным: следующая запись повторит попытку.
      _markDirty(id, kind);
      return true;
    }
  }

  void _markDirty(String id, DraftConflictKind kind) {
    if (kind == DraftConflictKind.draft) {
      _dirty.add(id);
    } else {
      _editsDirty.add(id);
    }
  }

  /// Подтягивает удалённую часть уже показанного конфликта.
  ///
  /// Пока пользователь читает баннер, другой клиент может изменить чат ещё
  /// раз. «Взять серверное» должно взять последнюю версию, а «оставить моё» —
  /// текущий локальный текст, а не снимок на момент появления баннера.
  void _updateConflictRemote(String chatId, Chat chat) {
    final draftConflict = _conflictFor(chatId, DraftConflictKind.draft);
    if (draftConflict != null &&
        chat.draftRevision > draftConflict.remoteRevision) {
      _replaceConflict(
        DraftConflict(
          chatId: chatId,
          kind: DraftConflictKind.draft,
          remoteRevision: chat.draftRevision,
          local: _drafts[chatId] ?? draftConflict.local,
          remote: chat.draft,
        ),
      );
    }
    final editsConflict = _conflictFor(chatId, DraftConflictKind.messageEdits);
    if (editsConflict != null &&
        chat.messageEditsRevision > editsConflict.remoteRevision) {
      _replaceConflict(
        DraftConflict(
          chatId: chatId,
          kind: DraftConflictKind.messageEdits,
          remoteRevision: chat.messageEditsRevision,
          localEdits: _edits[chatId] ?? editsConflict.localEdits,
          remoteEdits: chat.messageEdits,
        ),
      );
    }
  }

  void _replaceConflict(DraftConflict conflict) {
    final conflicts = _conflicts[conflict.chatId];
    if (conflicts == null) return;
    final index = conflicts.indexWhere((item) => item.kind == conflict.kind);
    if (index >= 0) conflicts[index] = conflict;
  }

  /// Черновики совпадают по сохранённым полям.
  ///
  /// Обычное `==` у [ChatDraft] сравнивает вложения по ссылке: сервер
  /// возвращает новые объекты, поэтому после успешной записи оно всегда
  /// ложно. Байты вложений в сравнение не входят — они не сохраняются.
  bool _sameDraft(ChatDraft a, ChatDraft b) =>
      a.text == b.text &&
      _sameAttachments(a.attachments, b.attachments) &&
      _sameMentions(a.mentions, b.mentions);

  bool _sameAttachments(List<AttachmentRef> a, List<AttachmentRef> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final left = a[i];
      final right = b[i];
      if (left.name != right.name ||
          left.mode != right.mode ||
          left.content != right.content ||
          left.mimeType != right.mimeType ||
          left.sizeBytes != right.sizeBytes) {
        return false;
      }
    }
    return true;
  }

  bool _sameMentions(List<MentionRef> a, List<MentionRef> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final left = a[i];
      final right = b[i];
      if (left.kind != right.kind ||
          left.path != right.path ||
          left.start != right.start ||
          left.end != right.end) {
        return false;
      }
    }
    return true;
  }

  bool _sameEdits(Map<String, ChatDraft>? a, Map<String, ChatDraft> b) {
    if (a == null || a.length != b.length) return false;
    for (final entry in a.entries) {
      final other = b[entry.key];
      if (other == null || !_sameDraft(entry.value, other)) return false;
    }
    return true;
  }

  /// Принимает версию чата с сервера: например, после SSE о чужом изменении.
  /// Возвращает true, если версия действительно новее локальной.
  bool applyRemote(String chatId, Chat chat) {
    _updateConflictRemote(chatId, chat);
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
    _unconfirmedDrafts.remove(chatId);
    _unconfirmedEdits.remove(chatId);
    if (conflict.kind == DraftConflictKind.draft) {
      // Пользователь мог продолжить печатать под баннером: сохраняем самую
      // свежую локальную версию, а не снимок на момент конфликта.
      _drafts[chatId] = _drafts[chatId] ?? conflict.local ?? ChatDraft.empty;
      _draftRevisions[chatId] = conflict.remoteRevision;
      _dirty.add(chatId);
    } else {
      _edits[chatId] = _edits[chatId] ?? conflict.localEdits ?? const {};
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
    _unconfirmedDrafts.remove(chatId);
    _unconfirmedEdits.remove(chatId);
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
    _unconfirmedDrafts.remove(chatId);
    _unconfirmedEdits.remove(chatId);
    _conflicts.remove(chatId);
  }

  /// Закрывает поток конфликтов, сохраняя несохранённые правки.
  ///
  /// Отложенная запись к этому моменту может ещё не сработать, а вызывающий
  /// закрывает хранилище на выходе из приложения: терять последний черновик
  /// нельзя.
  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    await flush();
    _timer?.cancel();
    _timer = null;
    await _conflictChanges.close();
  }
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

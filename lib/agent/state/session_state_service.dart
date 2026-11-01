import 'package:injectable/injectable.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/domain/session_state.dart';
import 'package:probably_works/core/data/chat_repository.dart';
import 'package:uuid/uuid.dart';

/// Ревизии состояния задачи (goal/plan/facts) по пользовательским сообщениям.
///
/// Модель: перед каждым пользовательским сообщением текущая ревизия запечатывается
/// (снимок «ДО», `sealedBeforeRevisionId`), после него открывается новая (`openedRevisionId`).
/// Edit N восстанавливает «ДО» N, delete-after N — ревизию, открытую N.
@lazySingleton
class SessionStateService {
  SessionStateService(this._chats);

  final ChatRepository _chats;

  static const _uuid = Uuid();

  /// Текущая (незапечатанная) ревизия чата; создаёт корневую, если её нет.
  Future<SessionStateRevision> current(Chat chat) async {
    final existingId = chat.currentRevisionId;
    if (existingId != null) {
      final existing = await _chats.revision(existingId);
      if (existing != null) return existing;
    }
    final root = SessionStateRevision(
      id: _uuid.v4(),
      chatId: chat.id,
      createdAt: DateTime.now(),
    );
    await _chats.saveRevision(root);
    await _chats.saveChat(chat.copyWith(currentRevisionId: root.id));
    return root;
  }

  /// Меняет текущую ревизию и сохраняет. Запечатанные ревизии не мутируются.
  Future<SessionStateRevision> mutate(
    Chat chat,
    void Function(SessionStateRevision rev) change,
  ) async {
    final rev = await current(chat);
    change(rev);
    await _chats.saveRevision(rev);
    return rev;
  }

  /// Вызывается при сохранении пользовательского сообщения. Возвращает обновлённые поля сообщения.
  Future<({String sealedBefore, String opened})> onUserMessage(
    Chat chat,
    String messageId,
  ) async {
    final before = await current(chat);
    before.sealed = true;
    await _chats.saveRevision(before);
    final opened = before.forkInto(
      newId: _uuid.v4(),
      triggeredBy: messageId,
      at: DateTime.now(),
    );
    await _chats.saveRevision(opened);
    await _chats.saveChat(chat.copyWith(currentRevisionId: opened.id));
    return (sealedBefore: before.id, opened: opened.id);
  }

  /// Edit сообщения N: текущей становится копия «ДО» N. Сообщения >= N удаляет вызывающий.
  Future<void> restoreBefore(Chat chat, ChatMessage message) async {
    final snapshotId = message.sealedBeforeRevisionId;
    if (snapshotId == null) return;
    await _restoreFrom(chat, snapshotId);
  }

  /// Delete-after N: текущей становится копия ревизии, открытой сообщением N.
  Future<void> restoreAfter(Chat chat, ChatMessage message) async {
    final openedId = message.openedRevisionId;
    if (openedId == null) return;
    await _restoreFrom(chat, openedId);
  }

  Future<void> _restoreFrom(Chat chat, String revisionId) async {
    final source = await _chats.revision(revisionId);
    if (source == null) return;
    final copy = source.restoreCopy(newId: _uuid.v4(), at: DateTime.now());
    await _chats.saveRevision(copy);
    await _chats.saveChat(chat.copyWith(currentRevisionId: copy.id));
  }

  /// Для модели: краткий индекс прошлых ревизий (только запечатанные).
  Future<List<String>> sealedIndex(String chatId) async => [
    for (final rev in await _chats.revisionsForChat(chatId))
      if (rev.sealed) rev.summaryLine(),
  ];
}

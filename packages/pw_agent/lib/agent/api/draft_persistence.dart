import 'package:pw_agent/agent/domain/chat_models.dart';

/// Сохранение черновика и неотправленных правок в конкретном backend'е.
///
/// Локальный профиль пишет в БД, удалённый — в HTTP API. Оба возвращают
/// новую версию черновика, чтобы клиент мог обнаружить конфликт.
abstract interface class DraftPersistence {
  Future<Chat?> chat(String id);

  Future<int> saveDraft(
    String chatId,
    ChatDraft draft, {
    int? expectedRevision,
  });

  Future<int> saveMessageEdits(
    String chatId,
    Map<String, ChatDraft> edits, {
    int? expectedRevision,
  });
}

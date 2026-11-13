import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/api/draft_persistence.dart';
import 'package:pw_agent/core/data/chat_repository.dart';

/// Связывает интерфейс черновиков с локальной реализацией.
///
/// `ChatDraftStore` зависит от [DraftPersistence], а не от `ChatRepository`:
/// в удалённом профиле черновики уходят в HTTP. Без этой привязки генератор
/// зависимостей не знает, какую реализацию подставить в локальном режиме.
@module
abstract class DraftPersistenceModule {
  @lazySingleton
  DraftPersistence draftPersistence(ChatRepository chats) => chats;
}

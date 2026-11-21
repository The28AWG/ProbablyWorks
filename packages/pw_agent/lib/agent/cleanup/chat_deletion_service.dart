import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/api/chat_run_stopper.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/exec/exec_log_store.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/project/project_lifecycle.dart';
import 'package:pw_agent/agent/turn/turn_changeset_service.dart';
import 'package:pw_agent/core/data/chat_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';

/// Полное удаление чата: строки базы, логи, снимки файлов и аренда карточек.
///
/// Один общий путь для удаления из списка чатов и для очистки истории.
/// Каскад внешних ключей убирает сообщения и задачи, но файлы лежат вне
/// SQLite, поэтому каждому потомку нужна своя очистка.
@lazySingleton
class ChatDeletionService {
  ChatDeletionService(
    this._chats,
    this._settings,
    this._broker,
    this._logs,
    this._turnChangesets,
    this._projects,
    this._stopper,
  );

  final ChatRepository _chats;
  final SettingsRepository _settings;
  final InteractionBroker _broker;
  final ExecLogStore _logs;
  final TurnChangesetService _turnChangesets;
  final ProjectLifecycleService _projects;
  final ChatRunStopper _stopper;

  /// Останавливает ход и удаляет чат вместе со скрытыми субагентами.
  ///
  /// Отсутствующий чат не считается ошибкой: список мог устареть, а повторное
  /// удаление уже удалённого не должно ломать очистку остальных.
  Future<void> delete(String chatId) async {
    final tree = await _chats.chatAndDescendants(chatId);
    if (tree.isEmpty) return;
    await deleteTree(tree);
  }

  /// Удаляет уже собранное дерево чатов.
  ///
  /// [tree] должен идти от самых глубоких потомков к корню: очистке истории
  /// выгодно собрать его один раз на снимке базы, а не читать все чаты для
  /// каждого корня.
  Future<void> deleteTree(List<Chat> tree) async {
    if (tree.isEmpty) return;
    final projectIds = <String>{for (final chat in tree) ?chat.projectId};
    for (final chat in tree) {
      await _stopper.stopChat(chat.id);
    }
    // Дети идут раньше родителя: к моменту удаления родителя его потомков
    // уже нет, и рекурсия в репозитории ничего не пропустит.
    for (final chat in tree) {
      await _chats.deleteChat(chat.id);
      await _settings.deleteChatData(chat.id);
      _broker.clearChatGrants(chat.id);
      await _logs.deleteChat(chat.id);
      await _turnChangesets.store.deleteChat(chat.id);
    }
    for (final projectId in projectIds) {
      await _projects.releaseIfEmpty(projectId);
    }
  }
}

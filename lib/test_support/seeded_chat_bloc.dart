import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:pw_agent/agent/api/chat_api.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/exec/live_output_bus.dart';
import 'package:pw_agent/core/data/chat_draft_store.dart';
import 'package:pw_agent/core/data/chat_repository.dart';
import 'package:pw_agent/host/host_terminal.dart';

/// Блок чата, который сразу показывает заготовленное состояние. Агент и БД не нужны:
/// виджет-тесты проверяют только отрисовку и реакцию UI.
///
/// Черновики по умолчанию пишутся в пустышку; [drafts] нужен тестам, которые проверяют сохранение.
class SeededChatBloc extends ChatBloc {
  SeededChatBloc(ChatState seed, {ChatDraftStore? drafts})
    : super(
        _UnusedHub(),
        _UnusedBus(),
        drafts ?? ChatDraftStore(_DiscardingChats()),
        // Начальное состояние задано сразу: хаб не нужен даже для пустого чата.
        initialState: seed,
      ) {
    // ignore: invalid_use_of_visible_for_testing_member, seed state for widget tests
    emit(seed);
  }

  /// Без агента терминалов нет: активные шаги показывают текстовый вывод.
  @override
  HostTerminal? terminalFor(String runId) => null;
}

class _UnusedHub implements ChatApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('ChatApi is not available in widget tests');
}

class _UnusedBus implements LiveOutputBus {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('LiveOutputBus is not available in widget tests');
}

/// Черновики в виджет-тестах не нужно хранить: запись просто не происходит.
class _DiscardingChats implements ChatRepository {
  @override
  Future<void> saveDraft(String chatId, ChatDraft draft) =>
      Future<void>.value();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('ChatRepository is not available in widget tests');
}

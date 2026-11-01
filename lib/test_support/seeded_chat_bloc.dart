import 'package:probably_works/agent/exec/live_output_bus.dart';
import 'package:probably_works/agent/loop/agent_hub.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/host/host_terminal.dart';

/// Блок чата, который сразу показывает заготовленное состояние. Агент и БД не нужны:
/// виджет-тесты проверяют только отрисовку и реакцию UI.
class SeededChatBloc extends ChatBloc {
  SeededChatBloc(ChatState seed) : super(_UnusedHub(), _UnusedBus()) {
    // ignore: invalid_use_of_visible_for_testing_member, seed state for widget tests
    emit(seed);
  }

  /// Без агента терминалов нет: активные шаги показывают текстовый вывод.
  @override
  HostTerminal? terminalFor(String runId) => null;
}

class _UnusedHub implements AgentHub {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('AgentHub is not available in widget tests');
}

class _UnusedBus implements LiveOutputBus {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('LiveOutputBus is not available in widget tests');
}

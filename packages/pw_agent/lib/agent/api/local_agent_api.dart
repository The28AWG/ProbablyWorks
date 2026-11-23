import 'dart:async';

import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/local_chat_api.dart';

/// Локальный [AgentApi] поверх встроенного агента. Для экрана чата достаточно
/// [LocalChatApi]: счётчик задач и форк с выбором есть уже там.
@lazySingleton
final class LocalAgentApi extends LocalChatApi
    implements AgentApi, InteractionEventsApi {
  LocalAgentApi(super.hub, super.runtime);

  @override
  AgentStatus get status => AgentStatus.online;

  @override
  Stream<AgentStatus> get statusChanges => const Stream<AgentStatus>.empty();

  @override
  Future<bool> checkConnection() async => true;
}

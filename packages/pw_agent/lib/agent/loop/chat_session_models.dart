part of 'chat_session.dart';

/// Последний ответ модели, у которого не каждый вызов уже есть в ленте.
ChatMessage? _unfinishedAssistant(List<ChatMessage> messages) {
  final answered = _toolResultIds(messages);
  ChatMessage? open;
  for (final message in messages) {
    if (message.role != MessageRole.assistant || message.toolCalls.isEmpty) {
      continue;
    }
    for (final call in message.toolCalls) {
      if (answered.contains(call.id)) continue;
      open = message;
      break;
    }
  }
  return open;
}

/// Id вызовов, для которых в ленте уже лежит результат.
Set<String> _toolResultIds(List<ChatMessage> messages) => {
  for (final message in messages)
    if (message.role == MessageRole.tool && message.toolCallId != null)
      message.toolCallId!,
};

/// Подтверждение или вопрос, который старт приложения не кладёт в брокер.
class _ParkedCard {
  _ParkedCard(this.run) : decision = Completer<WaitingDecision>();

  final ToolRun run;
  final Completer<WaitingDecision> decision;

  /// Уже передана в брокер. Повторное открытие чата карточку не регистрирует снова.
  var shown = false;
}

class _Prepared {
  const _Prepared({
    required this.chat,
    required this.host,
    required this.runtime,
    required this.policy,
    required this.limit,
    required this.model,
    required this.inlineIds,
    required this.request,
    this.project,
  });

  final Chat chat;
  final Host host;
  final HostRuntime runtime;
  final PolicyEngine policy;
  final int limit;
  final String model;

  /// Проект чата. Null, пока у чата нет явной папки: дом общим проектом не становится.
  final Project? project;

  /// Сообщения, чьи файлы входят в этот запрос; после ответа модели их байты освобождаются.
  final List<String> inlineIds;
  final LlmRequest request;
}

/// Провайдеры называют лимит вывода по-разному: `length` у OpenRouter,
/// `max_tokens` у некоторых совместимых API.
bool _isLengthFinish(String? reason) {
  final value = reason?.toLowerCase();
  return value != null &&
      (value.contains('length') || value.contains('max_tokens'));
}

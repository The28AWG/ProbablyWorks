/// Порт провайдера ИИ. AgentLoop зависит только от этих типов, не от OpenRouter.
library;

enum LlmRole { system, user, assistant, tool }

class LlmToolCall {
  const LlmToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  final String id;
  final String name;

  /// Сырой JSON аргументов, как его вернула модель (может быть битым).
  final String arguments;
}

class LlmMessage {
  const LlmMessage({
    required this.role,
    this.content = '',
    this.toolCalls = const [],
    this.toolCallId,
  });

  const LlmMessage.system(String content)
    : this(role: LlmRole.system, content: content);
  const LlmMessage.user(String content)
    : this(role: LlmRole.user, content: content);

  final LlmRole role;
  final String content;
  final List<LlmToolCall> toolCalls;
  final String? toolCallId;
}

class LlmToolSpec {
  const LlmToolSpec({
    required this.name,
    required this.description,
    required this.parameters,
  });

  final String name;
  final String description;

  /// JSON Schema аргументов.
  final Map<String, dynamic> parameters;
}

class LlmRequest {
  const LlmRequest({
    required this.model,
    required this.messages,
    this.tools = const [],
    this.maxTokens,
    this.temperature,
    this.skipReasoning = false,
  });

  final String model;
  final List<LlmMessage> messages;
  final List<LlmToolSpec> tools;
  final int? maxTokens;
  final double? temperature;

  /// Просит модель не тратить токены на рассуждения (для коротких служебных ответов).
  final bool skipReasoning;
}

class LlmUsage {
  const LlmUsage({required this.promptTokens, required this.completionTokens});

  final int promptTokens;
  final int completionTokens;
}

sealed class LlmEvent {
  const LlmEvent();
}

final class LlmTextDelta extends LlmEvent {
  const LlmTextDelta(this.text);

  final String text;
}

/// Финал ответа: инструменты целиком (чанки аргументов уже склеены), usage, причина.
final class LlmCompleted extends LlmEvent {
  const LlmCompleted({
    this.finishReason,
    this.toolCalls = const [],
    this.usage,
  });

  final String? finishReason;
  final List<LlmToolCall> toolCalls;
  final LlmUsage? usage;
}

class LlmModelInfo {
  const LlmModelInfo({
    required this.id,
    required this.name,
    this.contextLength,
    this.supportsTools = false,
    this.promptPrice,
    this.completionPrice,
  });

  final String id;
  final String name;
  final int? contextLength;
  final bool supportsTools;
  final String? promptPrice;
  final String? completionPrice;
}

abstract interface class LlmProvider {
  /// Стрим ответа. Ошибки выбрасываются как [LlmFailure] (см. core/error).
  Stream<LlmEvent> stream(LlmRequest request);

  Future<List<LlmModelInfo>> listModels();
}

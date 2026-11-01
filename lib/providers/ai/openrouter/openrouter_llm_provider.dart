import 'dart:async';
import 'dart:io';

import 'package:openrouter/openrouter.dart';
import 'package:probably_works/core/error/app_failure.dart';
import 'package:probably_works/providers/ai/llm_port.dart';

/// Адаптер OpenRouter к порту [LlmProvider]. Ключ читается при каждом вызове,
/// поэтому смена ключа в Settings действует сразу.
class OpenRouterLlmProvider implements LlmProvider {
  OpenRouterLlmProvider({required this._apiKey, this.baseUrl});

  final Future<String?> Function() _apiKey;
  final String? baseUrl;

  static const _appTitle = 'ProbablyWorks';

  Future<OpenRouter> _client() async {
    final key = await _apiKey();
    if (key == null || key.isEmpty) {
      throw const LlmFailure('OpenRouter API key is not set');
    }
    return OpenRouter(
      apiKey: key,
      baseUrl: baseUrl,
      xOpenrouterTitle: _appTitle,
      xOpenrouterCategories: 'cli-agent',
    );
  }

  @override
  Stream<LlmEvent> stream(LlmRequest request) async* {
    final client = await _client();
    final accumulated = <int, _PartialToolCall>{};
    String? finishReason;
    LlmUsage? usage;
    try {
      await for (final response in client.chat.sendStream(
        body: _toRequest(request),
      )) {
        final chunk = response.data;
        final usageValue = chunk.usage;
        if (usageValue != null) {
          usage = LlmUsage(
            promptTokens: usageValue.promptTokens,
            completionTokens: usageValue.completionTokens,
          );
        }
        for (final choice in chunk.choices) {
          final delta = choice.delta;
          final text = delta.content;
          if (text != null && text.isNotEmpty) yield LlmTextDelta(text);
          for (final call in delta.toolCalls ?? const <ChatStreamToolCall>[]) {
            accumulated.putIfAbsent(call.indexValue, _PartialToolCall.new)
              ..id ??= call.id
              ..name ??= call.function?.nameValue
              ..arguments.write(call.function?.arguments ?? '');
          }
          if (choice.finishReason != null) {
            finishReason = choice.finishReason!.name;
          }
        }
      }
    } on OpenRouterException catch (error, stack) {
      Error.throwWithStackTrace(_mapError(error), stack);
    } on SocketException catch (error, stack) {
      Error.throwWithStackTrace(
        LlmFailure('Network error: ${error.message}', retryable: true),
        stack,
      );
    } on HttpException catch (error, stack) {
      Error.throwWithStackTrace(
        LlmFailure('HTTP error: ${error.message}', retryable: true),
        stack,
      );
    } finally {
      client.close();
    }

    final calls = [
      for (final index in accumulated.keys.toList()..sort())
        LlmToolCall(
          id: accumulated[index]!.id ?? 'call_$index',
          name: accumulated[index]!.name ?? '',
          arguments: accumulated[index]!.arguments.toString(),
        ),
    ];
    yield LlmCompleted(
      finishReason: finishReason,
      toolCalls: calls,
      usage: usage,
    );
  }

  @override
  Future<List<LlmModelInfo>> listModels() async {
    final client = await _client();
    try {
      final response = await client.models.list();
      return [
        for (final model in response.data)
          LlmModelInfo(
            id: model.id,
            name: model.nameValue,
            contextLength: model.contextLength,
            supportsTools: model.supportedParameters.contains(Parameter.tools),
            promptPrice: model.pricing.prompt,
            completionPrice: model.pricing.completion,
          ),
      ];
    } on OpenRouterException catch (error, stack) {
      Error.throwWithStackTrace(_mapError(error), stack);
    } finally {
      client.close();
    }
  }

  ChatRequest _toRequest(LlmRequest request) => ChatRequest(
    model: request.model,
    messages: [for (final m in request.messages) _toMessage(m)],
    tools: request.tools.isEmpty
        ? null
        : [for (final t in request.tools) _toTool(t)],
    maxTokens: request.maxTokens,
    temperature: request.temperature,
    reasoning: request.skipReasoning
        ? const ChatRequestReasoningValue(
            effort: ChatRequestReasoningValueEffortValue.none,
          )
        : null,
  );

  ChatMessages _toMessage(LlmMessage message) => switch (message.role) {
    LlmRole.system => ChatMessages.system(
      value: ChatSystemMessage(
        role: ChatSystemMessageRoleValue.system,
        content: ChatSystemMessageContentValue.string(value: message.content),
      ),
    ),
    LlmRole.user => ChatMessages.user(
      value: ChatUserMessage(
        role: ChatUserMessageRoleValue.user,
        content: ChatUserMessageContentValue.string(value: message.content),
      ),
    ),
    LlmRole.assistant => ChatMessages.assistant(
      value: ChatAssistantMessage(
        role: ChatAssistantMessageRoleValue.assistant,
        content: message.content.isEmpty
            ? null
            : ChatAssistantMessageContentValue.string(value: message.content),
        toolCalls: message.toolCalls.isEmpty
            ? null
            : [
                for (final call in message.toolCalls)
                  ChatToolCall(
                    id: call.id,
                    type: ChatToolCallTypeValue.function,
                    function: ChatToolCallFunctionValue(
                      nameValue: call.name,
                      arguments: call.arguments,
                    ),
                  ),
              ],
      ),
    ),
    LlmRole.tool => ChatMessages.tool(
      value: ChatToolMessage(
        role: ChatToolMessageRoleValue.tool,
        toolCallId: message.toolCallId ?? '',
        content: ChatToolMessageContentValue.string(value: message.content),
      ),
    ),
  };

  ChatFunctionTool _toTool(LlmToolSpec spec) => ChatFunctionTool.function(
    value: ChatFunctionToolFunctionFunction(
      type: ChatFunctionToolFunctionFunctionTypeValue.function,
      function: ChatFunctionToolFunctionFunctionFunctionValue(
        nameValue: spec.name,
        description: spec.description,
        parameters: spec.parameters,
      ),
    ),
  );

  LlmFailure _mapError(OpenRouterException error) {
    final status = error.statusCode;
    final message = error.message;
    final lower = message.toLowerCase();
    final contextExceeded =
        lower.contains('context') &&
        (lower.contains('length') || lower.contains('maximum'));
    final retryable = status == 429 || (status != null && status >= 500);
    return LlmFailure(
      message,
      statusCode: status,
      retryable: retryable,
      contextLengthExceeded: contextExceeded,
    );
  }
}

class _PartialToolCall {
  String? id;
  String? name;
  final StringBuffer arguments = StringBuffer();
}

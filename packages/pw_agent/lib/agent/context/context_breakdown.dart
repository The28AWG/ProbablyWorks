import 'dart:convert';

import 'package:pw_agent/providers/ai/llm_port.dart';

/// Из чего складывается запрос к модели. Символы, а не точные токены:
/// оценка нужна для инспектора, а не для бюджета провайдера.
final class ContextBreakdown {
  const ContextBreakdown({
    this.systemChars = 0,
    this.historyChars = 0,
    this.toolResultChars = 0,
    this.attachmentBytes = 0,
    this.toolSchemaChars = 0,
  });

  factory ContextBreakdown.of(
    List<LlmMessage> messages, {
    List<LlmToolSpec> tools = const [],
  }) {
    var system = 0;
    var history = 0;
    var toolResults = 0;
    var attachments = 0;
    for (final message in messages) {
      switch (message.role) {
        case LlmRole.system:
          system += message.content.length;
        case LlmRole.tool:
          toolResults += message.content.length;
        case LlmRole.user:
        case LlmRole.assistant:
          history += message.content.length;
          for (final call in message.toolCalls) {
            history += call.name.length + call.arguments.length;
          }
      }
      for (final file in message.files) {
        attachments += file.bytes.length;
      }
    }
    var schema = 0;
    for (final tool in tools) {
      schema +=
          tool.name.length +
          tool.description.length +
          jsonEncode(tool.parameters).length;
    }
    return ContextBreakdown(
      systemChars: system,
      historyChars: history,
      toolResultChars: toolResults,
      attachmentBytes: attachments,
      toolSchemaChars: schema,
    );
  }

  final int systemChars;
  final int historyChars;
  final int toolResultChars;
  final int attachmentBytes;
  final int toolSchemaChars;

  int get totalChars =>
      systemChars +
      historyChars +
      toolResultChars +
      attachmentBytes +
      toolSchemaChars;

  /// Грубая оценка для показа рядом с процентами. Точный счётчик приходит
  /// от провайдера в usage.
  int get estimatedTokens => estimatedTokensOf(totalChars);

  int estimatedTokensOf(int chars) => (chars / 4).ceil();

  int get systemTokens => estimatedTokensOf(systemChars);
  int get historyTokens => estimatedTokensOf(historyChars);
  int get toolResultTokens => estimatedTokensOf(toolResultChars);
  int get attachmentTokens => estimatedTokensOf(attachmentBytes);
  int get toolSchemaTokens => estimatedTokensOf(toolSchemaChars);
}

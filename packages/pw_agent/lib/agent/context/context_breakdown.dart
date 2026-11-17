import 'dart:convert';

import 'package:pw_agent/providers/ai/llm_port.dart';

/// Из чего складывается запрос к модели. Символы, а не точные токены:
/// оценка нужна для инспектора, а не для бюджета провайдера.
///
/// Кроме символьных долей хранится UTF-8 размер каждой текстовой части
/// ([systemBytes], [historyBytes] и т. д.): по байтам считается и вес
/// уходящего запроса ([requestBytes]), и оценка токенов. Символы и байты
/// расходятся на не-ASCII тексте, поэтому одного счётчика недостаточно.
final class ContextBreakdown {
  const ContextBreakdown({
    this.systemChars = 0,
    this.historyChars = 0,
    this.toolResultChars = 0,
    this.attachmentBytes = 0,
    this.toolSchemaChars = 0,
    this.systemBytes = 0,
    this.historyBytes = 0,
    this.toolResultBytes = 0,
    this.toolSchemaBytes = 0,
    this.textBytes = 0,
  });

  factory ContextBreakdown.of(
    List<LlmMessage> messages, {
    List<LlmToolSpec> tools = const [],
  }) {
    var system = 0;
    var history = 0;
    var toolResults = 0;
    var attachments = 0;
    var systemBytes = 0;
    var historyBytes = 0;
    var toolResultBytes = 0;

    // Символы и UTF-8 байты одной строки за один проход: `utf8.encode` считает
    // байты по кодовым точкам, а `String.length` — по UTF-16 единицам. Для
    // символов вне BMP значения расходятся, и это ожидаемо: токенайзеру ближе
    // длина строки, а размеру запроса — байты.
    int charsOf(String text) => text.length;
    int bytesOf(String text) => utf8.encode(text).length;

    for (final message in messages) {
      switch (message.role) {
        case LlmRole.system:
          system += charsOf(message.content);
          systemBytes += bytesOf(message.content);
        case LlmRole.tool:
          toolResults += charsOf(message.content);
          toolResultBytes += bytesOf(message.content);
        case LlmRole.user:
        case LlmRole.assistant:
          history += charsOf(message.content);
          historyBytes += bytesOf(message.content);
          for (final call in message.toolCalls) {
            history += charsOf(call.name) + charsOf(call.arguments);
            historyBytes += bytesOf(call.name) + bytesOf(call.arguments);
          }
      }
      for (final file in message.files) {
        attachments += file.bytes.length;
      }
    }
    var schema = 0;
    var schemaBytes = 0;
    for (final tool in tools) {
      schema +=
          charsOf(tool.name) +
          charsOf(tool.description) +
          charsOf(jsonEncode(tool.parameters));
      schemaBytes +=
          bytesOf(tool.name) +
          bytesOf(tool.description) +
          bytesOf(jsonEncode(tool.parameters));
    }
    return ContextBreakdown(
      systemChars: system,
      historyChars: history,
      toolResultChars: toolResults,
      attachmentBytes: attachments,
      toolSchemaChars: schema,
      systemBytes: systemBytes,
      historyBytes: historyBytes,
      toolResultBytes: toolResultBytes,
      toolSchemaBytes: schemaBytes,
      textBytes: systemBytes + historyBytes + toolResultBytes + schemaBytes,
    );
  }

  final int systemChars;
  final int historyChars;
  final int toolResultChars;

  /// Размер вложений в байтах: это уже готовые файлы, а не текст.
  final int attachmentBytes;
  final int toolSchemaChars;

  final int systemBytes;
  final int historyBytes;
  final int toolResultBytes;
  final int toolSchemaBytes;

  /// Размер текста в UTF-8. Ноль трактуется как «байты не измерены»: так
  /// выглядит разбивка, собранная конструктором, а не через [ContextBreakdown.of].
  /// В этом случае [requestBytes] и оценка токенов считают символы байтами,
  /// как для ASCII.
  final int textBytes;

  /// Символы текстовых частей без вложений: основа оценки токенов.
  int get totalTextChars =>
      systemChars + historyChars + toolResultChars + toolSchemaChars;

  int get totalChars => totalTextChars + attachmentBytes;

  /// Сколько примерно весит уходящий провайдеру текст: UTF-8 текст плюс
  /// вложения как есть. Обвязка запроса (JSON, имена ролей, base64 вложений,
  /// mime-префиксы) не учитывается, поэтому значение — нижняя оценка и
  /// показывается с «≈».
  int get requestBytes =>
      (textBytes > 0 ? textBytes : totalTextChars) + attachmentBytes;

  /// Вес запроса в килобайтах (1024 байта) для показа человеку.
  double get requestKilobytes => requestBytes / 1024;

  /// Грубая оценка для показа рядом с процентами. Точный счётчик приходит
  /// от провайдера в usage.
  int get estimatedTokens =>
      estimatedTokensOf(textBytes > 0 ? textBytes : totalTextChars) +
      estimatedTokensOf(attachmentBytes);

  /// ~4 байта UTF-8 на токен. Для русского текста консервативнее, чем
  /// символы: кириллица занимает два байта на символ.
  int estimatedTokensOf(int bytes) => (bytes / 4).ceil();

  int get systemTokens => _tokensOf(systemBytes, systemChars);
  int get historyTokens => _tokensOf(historyBytes, historyChars);
  int get toolResultTokens => _tokensOf(toolResultBytes, toolResultChars);
  int get attachmentTokens => estimatedTokensOf(attachmentBytes);
  int get toolSchemaTokens => _tokensOf(toolSchemaBytes, toolSchemaChars);

  /// Байты, а не символы; для разбивки, собранной вручную, остаётся старый
  /// расчёт по символам, иначе токены были бы нулевыми.
  int _tokensOf(int bytes, int chars) =>
      estimatedTokensOf(bytes > 0 ? bytes : chars);
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:openrouter/openrouter.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/core/util/redactor.dart';
import 'package:pw_agent/core/util/text_clip.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/text_tool_call_parser.dart';
import 'package:pw_agent/providers/ai/think_tag_parser.dart';

/// Адаптер OpenRouter к порту [LlmProvider]. Ключ читается при каждом вызове,
/// поэтому смена ключа в Settings действует сразу.
///
/// Если провайдер модели не разобрал tool call, OpenRouter оставляет разметку
/// в `content`. Её забирает [TextToolCallParser] и кладёт в [LlmCompleted.toolCalls].
/// Рассуждения не разбираются: вызов из `<think>` исполнять нельзя.
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

  /// Ключ задан. Используется агрегатором, чтобы не трогать сеть без ключа.
  Future<bool> get hasKey async {
    final key = await _apiKey();
    return key != null && key.isNotEmpty;
  }

  @override
  Stream<LlmEvent> stream(LlmRequest request) async* {
    final client = await _client();
    final accumulated = <int, _PartialToolCall>{};
    final thinkTags = ThinkTagParser();
    final textCalls = request.tools.isEmpty
        ? null
        : TextToolCallParser(request.tools);
    String? finishReason;
    LlmUsage? usage;

    List<LlmEvent> show(LlmEvent event) {
      final parser = textCalls;
      if (parser == null || event is! LlmTextDelta) return [event];
      // List инвариантен: куски текста нельзя вернуть как List<LlmEvent> напрямую.
      return [for (final piece in parser.add(event.text)) piece];
    }

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
          final reasoning = delta.reasoning;
          if (reasoning != null && reasoning.isNotEmpty) {
            yield LlmReasoningDelta(reasoning);
          }
          final text = delta.content;
          if (text != null && text.isNotEmpty) {
            for (final event in thinkTags.add(text)) {
              for (final piece in show(event)) {
                yield piece;
              }
            }
          }
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
      Error.throwWithStackTrace(llmFailureOf(error), stack);
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

    for (final event in thinkTags.flush()) {
      for (final piece in show(event)) {
        yield piece;
      }
    }
    if (textCalls != null) {
      for (final piece in textCalls.flush()) {
        yield piece;
      }
    }
    final structured = [
      for (final index in accumulated.keys.toList()..sort())
        LlmToolCall(
          id: accumulated[index]!.id ?? 'call_$index',
          name: accumulated[index]!.name ?? '',
          arguments: accumulated[index]!.arguments.toString(),
        ),
    ];
    final calls = mergeToolCalls(structured, textCalls?.calls ?? const []);
    yield LlmCompleted(
      finishReason: finishReason,
      toolCalls: calls,
      usage: usage,
    );
  }

  /// Метаданные текущего ключа: он же подтверждает, что ключ принят сервисом.
  @override
  Future<LlmKeyInfo> checkKey() async {
    final client = await _client();
    try {
      final key = (await client.apiKeys.getCurrentKeyMetadata()).data;
      return LlmKeyInfo(
        label: key.label,
        usage: key.usage.toDouble(),
        limit: key.limit?.toDouble(),
        limitRemaining: key.limitRemaining?.toDouble(),
        limitReset: key.limitReset,
        isFreeTier: key.isFreeTier,
        // Строка ISO 8601 в UTC; пустая или неразобранная дата трактуется как бессрочный ключ.
        expiresAt: DateTime.tryParse(key.expiresAt ?? ''),
      );
    } on OpenRouterException catch (error, stack) {
      Error.throwWithStackTrace(llmFailureOf(error), stack);
    } on SocketException catch (error, stack) {
      Error.throwWithStackTrace(
        LlmFailure('Network error: ${error.message}', retryable: true),
        stack,
      );
    } finally {
      client.close();
    }
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
            created: model.created,
            inputModalities: [
              for (final modality in model.architecture.inputModalities)
                if (modality != InputModality.unknown_) modality.name,
            ],
          ),
      ];
    } on OpenRouterException catch (error, stack) {
      Error.throwWithStackTrace(llmFailureOf(error), stack);
    } finally {
      client.close();
    }
  }

  ChatRequest _toRequest(LlmRequest request) => ChatRequest(
    model: request.model,
    messages: [for (final m in request.messages) openRouterMessageOf(m)],
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
}

/// Сообщение порта → сообщение OpenRouter. Файлы уходят частями content (base64 data URL).
ChatMessages openRouterMessageOf(LlmMessage message) => switch (message.role) {
  LlmRole.system => ChatMessages.system(
    value: ChatSystemMessage(
      role: ChatSystemMessageRoleValue.system,
      content: ChatSystemMessageContentValue.string(value: message.content),
    ),
  ),
  LlmRole.user => ChatMessages.user(
    value: ChatUserMessage(
      role: ChatUserMessageRoleValue.user,
      content: message.files.isEmpty
          ? ChatUserMessageContentValue.string(value: message.content)
          : ChatUserMessageContentValue.list(
              value: [
                if (message.content.isNotEmpty)
                  ChatContentItems.text(
                    value: ChatContentText(
                      text: message.content,
                      type: ChatContentTextTypeValue.text,
                    ),
                  ),
                for (final file in message.files) _filePartOf(file),
              ],
            ),
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

/// Файл → часть content: изображение как image_url, аудио и видео — свои
/// типы, остальное как file (PDF и т.п.). Всё в data URL.
ChatContentItems _filePartOf(LlmFilePart file) {
  final dataUrl = 'data:${file.mimeType};base64,${base64Encode(file.bytes)}';
  if (file.isImage) {
    return ChatContentItems.imageUrl(
      value: ChatContentImage(
        imageUrl: ChatContentImageImageUrlValue(url: dataUrl),
        type: ChatContentImageTypeValue.imageUrl,
      ),
    );
  }
  if (file.mimeType.startsWith('audio/')) {
    return ChatContentItems.inputAudio(
      value: ChatContentAudio(
        inputAudio: ChatContentAudioInputAudioValue(
          data: base64Encode(file.bytes),
          format: _audioFormat(file.mimeType),
        ),
        type: ChatContentAudioTypeValue.inputAudio,
      ),
    );
  }
  if (file.mimeType.startsWith('video/')) {
    return ChatContentItems.videoUrl(
      value: ChatContentVideo(
        type: ChatContentVideoTypeValue.videoUrl,
        videoUrl: ChatContentVideoInput(url: dataUrl),
      ),
    );
  }
  return ChatContentItems.file(
    value: ChatContentFile(
      file: ChatContentFileFileValue(fileData: dataUrl, filename: file.name),
      type: ChatContentFileTypeValue.file,
    ),
  );
}

/// MIME-тип аудио → формат, который понимает OpenRouter.
String _audioFormat(String mimeType) {
  final subtype = mimeType.split('/').last;
  return switch (subtype) {
    'mpeg' || 'mp3' => 'mp3',
    'wav' || 'x-wav' => 'wav',
    'flac' || 'x-flac' => 'flac',
    'ogg' => 'ogg',
    'mp4' || 'm4a' || 'x-m4a' => 'm4a',
    'webm' => 'webm',
    _ => subtype,
  };
}

/// Ошибка OpenRouter → типизированная [LlmFailure]. Модель, которой нет на сервере, отдаётся с 404.
/// Причину от сервера (поле `error.message` в теле ответа) добавляем к тексту, очищая секреты.
LlmFailure llmFailureOf(OpenRouterException error) {
  final status = error.statusCode;
  final detail = _serverDetail(error.body);
  final message = detail == null
      ? error.message
      : '${error.message}: ${Redactor.redact(detail)}';
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
    modelNotFound: status == 404,
  );
}

/// Текст причины из JSON-тела ошибки. Если тело не JSON (например, страница прокси), берём его начало.
String? _serverDetail(String? body) {
  if (body == null || body.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map && decoded['error'] is Map) {
      final message = (decoded['error'] as Map)['message'];
      if (message is String && message.isNotEmpty) return message;
    }
    return null;
  } on FormatException {
    return TextClip.headTail(
      body.replaceAll(RegExp(r'\s+'), ' ').trim(),
      maxChars: 160,
    );
  }
}

class _PartialToolCall {
  String? id;
  String? name;
  final StringBuffer arguments = StringBuffer();
}

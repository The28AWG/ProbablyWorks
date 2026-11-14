/// Адаптер llama.cpp server к порту [LlmProvider].
///
/// Использует OpenAI-совместимый `/v1/chat/completions` и `/v1/models`:
/// сервер llama.cpp отдаёт их в single-model и router режимах. Список
/// возможностей берётся из OWN `/models`, когда он доступен (router cache).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:llama_cpp/llama_cpp.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/providers/ai/llama_cpp/llama_cpp_connection.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/text_tool_call_parser.dart';
import 'package:pw_agent/providers/ai/think_tag_parser.dart';

/// Провайдер llama.cpp. Настройки читаются при каждом вызове, поэтому
/// смена адреса или ключа в Settings действует сразу.
class LlamaCppLlmProvider implements LlmProvider, LlamaCppStatusProvider {
  LlamaCppLlmProvider({
    required this._settings,
    this.requestTimeout = const Duration(seconds: 60),
  });

  final LlamaCppSettingsReader _settings;
  final Duration requestTimeout;

  /// Включён ли провайдер. Выключенный не опрашивается и не попадает в каталог.
  @override
  Future<bool> get isEnabled async => (await _settings.read()).enabled;

  /// Сервер отвечает на health-запрос. Выключенный провайдер всегда недоступен.
  @override
  Future<bool> get isAvailable async {
    final connection = await _settings.read();
    if (!connection.enabled) return false;
    return _client(connection).isAvailable;
  }

  /// Проверка доступности и размера каталога. Не бросает исключение:
  /// ошибка возвращается в [LlamaCppStatus.error].
  @override
  Future<LlamaCppStatus> checkHealth() async {
    final connection = await _settings.read();
    final base = LlamaCppStatus(
      enabled: connection.enabled,
      baseUrl: connection.baseUrl,
      apiKeySet: connection.hasApiKey,
      apiKeyTail: connection.keyTail,
      checkedAt: DateTime.now(),
    );
    if (!connection.enabled) return base;
    try {
      final available = await _client(connection).isAvailable;
      if (!available) {
        return base.copyWith(error: 'llama.cpp server is not responding');
      }
      final models = await listModels();
      return base.copyWith(available: true, modelCount: models.length);
    } on Object catch (error) {
      return base.copyWith(error: llamaCppFailureOf(error).message);
    }
  }

  /// Ключа с лимитами у llama.cpp нет; метод подтверждает доступность сервера.
  @override
  Future<LlmKeyInfo> checkKey() async {
    final connection = await _settings.read();
    if (!connection.enabled) {
      throw const LlmFailure('llama.cpp provider is disabled');
    }
    if (!await _client(connection).isAvailable) {
      throw const LlmFailure(
        'llama.cpp server is not available',
        retryable: true,
      );
    }
    return const LlmKeyInfo(label: 'llama.cpp server', usage: 0);
  }

  @override
  Future<List<LlmModelInfo>> listModels() async {
    final connection = await _settings.read();
    if (!connection.enabled) return const [];
    final router = LlamaCpp(
      baseUrl: connection.baseUrl,
      requestTimeout: requestTimeout,
      apiKey: connection.apiKey,
    );
    try {
      final routerModels = await router.listModels();
      final models = [
        for (final model in routerModels.data ?? const <LlamaCppModelInfo>[])
          if (model.id != null && model.id!.isNotEmpty)
            LlmModelInfo(
              id: llamaCppModelId(model.id!),
              name: _displayName(model),
              contextLength: model.meta?.nCtxTrain ?? model.meta?.nCtx,
              // В router cache есть теги; пустой список тегов ничего не
              // говорит о tool calling, поэтому не отказываем заранее.
              supportsTools:
                  model.toolsTagged ||
                  model.tags == null ||
                  model.tags!.isEmpty,
              created: model.created,
              inputModalities: model.architecture?.inputModalities,
            ),
      ];
      if (models.isNotEmpty) return models;
    } on LlamaCppException {
      // Router cache не всегда доступен (single-model режим).
    } on SocketException {
      // Сервер недоступен — пусть ошибка всплывёт из OpenAI-клиента.
    } on TimeoutException {
      // См. выше.
    } on HttpException {
      // См. выше.
    }

    final openAi = _client(connection);
    try {
      final response = await openAi.listModels();
      return [
        for (final model
            in response.data ?? const <LlamaCppOpenAiModelSummary>[])
          if (model.id != null && model.id!.isNotEmpty)
            LlmModelInfo(
              id: llamaCppModelId(model.id!),
              name: _stripQuantization(model.id!),
              contextLength: model.meta?.nCtxTrain,
              created: model.created,
            ),
      ];
    } on LlamaCppException catch (error, stack) {
      Error.throwWithStackTrace(llamaCppFailureOf(error), stack);
    } on SocketException catch (error, stack) {
      Error.throwWithStackTrace(
        LlmFailure('Network error: ${error.message}', retryable: true),
        stack,
      );
    } on TimeoutException catch (error, stack) {
      Error.throwWithStackTrace(
        LlmFailure('llama.cpp timeout: ${error.message}', retryable: true),
        stack,
      );
    } on HttpException catch (error, stack) {
      Error.throwWithStackTrace(
        LlmFailure('HTTP error: ${error.message}', retryable: true),
        stack,
      );
    }
  }

  @override
  Stream<LlmEvent> stream(LlmRequest request) async* {
    final connection = await _settings.read();
    if (!connection.enabled) {
      throw const LlmFailure('llama.cpp provider is disabled');
    }
    final client = _client(connection);
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
      return [for (final piece in parser.add(event.text)) piece];
    }

    try {
      await for (final chunk in client.chatStream(_toRequest(request))) {
        final chunkUsage = chunk.usage;
        if (chunkUsage != null) {
          usage = LlmUsage(
            promptTokens: chunkUsage.promptTokens ?? 0,
            completionTokens: chunkUsage.completionTokens ?? 0,
          );
        }
        for (final choice
            in chunk.choices ?? const <LlamaCppOpenAiChatStreamChoice>[]) {
          final delta = choice.delta;
          if (delta == null) continue;
          final reasoning = delta.reasoningContent;
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
          for (final call
              in delta.toolCalls ?? const <LlamaCppOpenAiToolCall>[]) {
            final index = call.index ?? 0;
            accumulated.putIfAbsent(index, _PartialToolCall.new)
              ..id ??= call.id
              ..name ??= call.function?.name
              ..arguments.write(call.function?.arguments ?? '');
          }
          if (choice.finishReason != null) {
            finishReason = choice.finishReason;
          }
        }
      }
    } on LlamaCppException catch (error, stack) {
      Error.throwWithStackTrace(llamaCppFailureOf(error), stack);
    } on SocketException catch (error, stack) {
      Error.throwWithStackTrace(
        LlmFailure('Network error: ${error.message}', retryable: true),
        stack,
      );
    } on TimeoutException catch (error, stack) {
      Error.throwWithStackTrace(
        LlmFailure('llama.cpp timeout: ${error.message}', retryable: true),
        stack,
      );
    } on HttpException catch (error, stack) {
      Error.throwWithStackTrace(
        LlmFailure('HTTP error: ${error.message}', retryable: true),
        stack,
      );
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

  LlamaCppOpenAi _client(LlamaCppConnection connection) => LlamaCppOpenAi(
    baseUrl: connection.baseUrl,
    requestTimeout: requestTimeout,
    apiKey: connection.apiKey,
  );

  LlamaCppOpenAiChatRequest _toRequest(LlmRequest request) =>
      LlamaCppOpenAiChatRequest(
        model: llamaCppModelId(request.model),
        messages: [for (final message in request.messages) _messageOf(message)],
        stream: true,
        temperature: request.temperature,
        maxTokens: request.maxTokens,
        tools: request.tools.isEmpty
            ? null
            : [for (final tool in request.tools) _toolOf(tool)],
        toolChoice: request.tools.isEmpty ? null : 'auto',
        parseToolCalls: true,
        reasoningEffort: request.skipReasoning ? 'none' : null,
        streamOptions: const LlamaCppOpenAiStreamOptions(includeUsage: true),
      );
}

LlamaCppOpenAiToolDefinition _toolOf(LlmToolSpec spec) =>
    LlamaCppOpenAiToolDefinition(
      type: 'function',
      function: LlamaCppOpenAiFunctionDefinition(
        name: spec.name,
        description: spec.description,
        parameters: spec.parameters,
      ),
    );

/// Сообщение порта → сообщение llama.cpp. Файлы уходят частями content:
/// изображения — `image_url`, остальные — текстовой ссылкой на файл.
LlamaCppOpenAiChatMessage _messageOf(LlmMessage message) =>
    switch (message.role) {
      LlmRole.system => LlamaCppOpenAiChatMessage(
        role: LlamaCppOpenAiMessageRole.system,
        content: message.content,
      ),
      LlmRole.user => LlamaCppOpenAiChatMessage(
        role: LlamaCppOpenAiMessageRole.user,
        content: message.files.isEmpty
            ? message.content
            : [
                if (message.content.isNotEmpty)
                  LlamaCppOpenAiTextPart(text: message.content),
                for (final file in message.files) _filePartOf(file),
              ],
      ),
      LlmRole.assistant => LlamaCppOpenAiChatMessage(
        role: LlamaCppOpenAiMessageRole.assistant,
        content: message.content.isEmpty ? null : message.content,
        toolCalls: message.toolCalls.isEmpty
            ? null
            : [
                for (final call in message.toolCalls)
                  LlamaCppOpenAiToolCall(
                    id: call.id,
                    type: 'function',
                    function: LlamaCppOpenAiFunctionCall(
                      name: call.name,
                      arguments: call.arguments,
                    ),
                  ),
              ],
      ),
      LlmRole.tool => LlamaCppOpenAiChatMessage(
        role: LlamaCppOpenAiMessageRole.tool,
        toolCallId: message.toolCallId ?? '',
        content: message.content,
      ),
    };

/// Файл → часть content. Изображение — `image_url`, аудио и видео — свои
/// типы, читаемый текст — `text` с содержимым. Остальные бинарные файлы
/// уходят частью `file`: сервер llama.cpp сам проверит формат и вернёт
/// ошибку, если вложение не поддержано.
LlamaCppOpenAiContentPart _filePartOf(LlmFilePart file) {
  final data = base64Encode(file.bytes);
  if (file.isImage) {
    return LlamaCppOpenAiImageUrlPart(
      imageUrl: LlamaCppOpenAiImageUrl(
        url: 'data:${file.mimeType};base64,$data',
      ),
    );
  }
  if (file.mimeType.startsWith('audio/')) {
    return LlamaCppOpenAiInputAudioPart(
      inputAudio: LlamaCppOpenAiInputAudio(
        data: data,
        format: _audioFormat(file.mimeType),
      ),
    );
  }
  if (file.mimeType.startsWith('video/')) {
    return LlamaCppOpenAiInputVideoPart(
      inputVideo: LlamaCppOpenAiInputVideo(data: data),
    );
  }
  final text = _decodeText(file.bytes);
  if (text != null) {
    return LlamaCppOpenAiTextPart(
      text: '--- attachment: ${file.name} ---\n$text',
    );
  }
  // Отдельного DTO для `file` в пакете нет, но сервер llama.cpp сам
  // проверит вложение и вернёт ошибку, если формат не поддержан. Так
  // сообщение об ошибке увидит пользователь, а не модель в промпте.
  return LlamaCppOpenAiUnknownPart(
    raw: {
      'type': 'file',
      'file': {
        'filename': file.name,
        'file_data': 'data:${file.mimeType};base64,$data',
      },
    },
  );
}

/// Текст из байтов, если файл читается как UTF-8. Иначе null.
String? _decodeText(Uint8List bytes) {
  if (bytes.contains(0)) return null;
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

/// MIME-тип аудио → формат, который понимает llama.cpp server.
String? _audioFormat(String mimeType) {
  final subtype = mimeType.split('/').last;
  return switch (subtype) {
    'mpeg' || 'mp3' => 'mp3',
    'wav' || 'x-wav' => 'wav',
    'flac' || 'x-flac' => 'flac',
    'ogg' => 'ogg',
    'mp4' || 'm4a' || 'x-m4a' => 'm4a',
    'webm' => 'webm',
    _ => null,
  };
}

/// Отображаемое имя модели: alias сервера, иначе id без суффикса квантизации.
String _displayName(LlamaCppModelInfo model) {
  final aliases = model.aliases;
  if (aliases != null && aliases.isNotEmpty) {
    final alias = aliases.first;
    if (alias.isNotEmpty) return alias;
  }
  return _stripQuantization(model.id ?? '');
}

/// `Hy-MT2-1.8B-Q4_K_M` → `Hy-MT2-1.8B`, `gemma-4-E4B-it-Q4_K_M` → `gemma-4-E4B-it`.
///
/// Квантование остаётся в id и бейдже модели: по нему видно, какой файл
/// загружен, но в названии оно только мешает.
String _stripQuantization(String id) {
  final suffix = RegExp(
    r'[-_](?:UD[-_])?(?:Q\d+(?:_[A-Z0-9]+)*|IQ\d+(?:_[A-Z0-9]+)*|F16|F32|BF16)(?:\.gguf)?$',
    caseSensitive: false,
  );
  return id.replaceFirst(suffix, '');
}

class _PartialToolCall {
  String? id;
  String? name;
  final StringBuffer arguments = StringBuffer();
}

/// Мост между средой выполнения и llamadart.
///
/// Среда хранит файлы и очередь, но не знает API библиотеки. Весь llamadart
/// живёт в [LlamadartLocalEngine]: загрузка файла в память, параметры,
/// отображение сообщений и событий порта. Тесты подставляют фейковый
/// [LocalEngine] и не тянут нативные рантаймы.
library;

import 'dart:convert';

import 'package:llamadart/llamadart.dart';
import 'package:logging/logging.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/local_models.dart';

/// Один загруженный файл модели в памяти процесса.
abstract interface class LocalEngine {
  /// Загружен ли файл.
  bool get isLoaded;

  /// Путь загруженного файла; null — ничего не загружено.
  String? get loadedPath;

  /// Загружает файл с параметрами. Повторная загрузка заменяет модель.
  ///
  /// [projectorPath] — уже разрешённый локальный путь к `mmproj.gguf`; null —
  /// модель текстовая.
  Future<void> load({
    required String path,
    required LocalModelSettings settings,
    String? projectorPath,
  });

  /// Освобождает память, оставляя движок пригодным для новой загрузки.
  Future<void> unload();

  /// Освобождает движок полностью. После вызова нужен новый экземпляр.
  Future<void> dispose();

  /// Стрим ответа. Инструменты уже описаны в [request].
  Stream<LlmEvent> generate(LlmRequest request, LocalModelSettings settings);

  /// Останавливает текущую генерацию. Безопасно вызывать без активной.
  Future<void> cancel();
}

/// Реализация [LocalEngine] поверх llamadart (llama.cpp).
final class LlamadartLocalEngine implements LocalEngine {
  static final _log = Logger('LlamadartEngine');

  LlamaEngine? _engine;
  String? _loadedPath;

  @override
  bool get isLoaded => _loadedPath != null;

  @override
  String? get loadedPath => _loadedPath;

  @override
  Future<void> load({
    required String path,
    required LocalModelSettings settings,
    String? projectorPath,
  }) async {
    final error = settings.validate();
    if (error != null) {
      throw LlmFailure('Model settings are invalid: $error');
    }
    final engine = _engine ??= LlamaEngine(LlamaBackend());
    try {
      await engine.setModel(
        LlamaModel(
          ModelSource.path(path),
          projector: projectorPath == null
              ? null
              : ModelSource.path(projectorPath),
        ),
        params: _modelParams(settings),
      );
      _loadedPath = path;
    } on Object catch (error, stack) {
      _loadedPath = null;
      Error.throwWithStackTrace(_failureOf(error), stack);
    }
  }

  @override
  Future<void> unload() async {
    final engine = _engine;
    if (engine == null) {
      _loadedPath = null;
      return;
    }
    try {
      await engine.unloadModel();
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(_failureOf(error), stack);
    } finally {
      _loadedPath = null;
    }
  }

  @override
  Future<void> dispose() async {
    final engine = _engine;
    _engine = null;
    _loadedPath = null;
    if (engine == null) return;
    try {
      await engine.dispose();
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(_failureOf(error), stack);
    }
  }

  @override
  Future<void> cancel() async {
    final engine = _engine;
    if (engine == null) return;
    engine.cancelGeneration();
  }

  @override
  Stream<LlmEvent> generate(
    LlmRequest request,
    LocalModelSettings settings,
  ) async* {
    final engine = _engine;
    if (engine == null || !engine.isReady) {
      throw const LlmFailure('Model is not loaded into memory');
    }
    final toolNames = _toolNames(request.messages);
    final messages = [
      for (final message in request.messages) _messageOf(message, toolNames),
    ];
    final tools = _toolsOf(request.tools);
    final params = _generationParams(request, settings);
    try {
      await for (final chunk in engine.create(
        messages,
        params: params,
        tools: tools,
        toolChoice: tools == null ? null : ToolChoice.auto,
        // Явный уровень `none` — единственный, который просит не думать.
        enableThinking: request.reasoning != ReasoningEffort.none,
      )) {
        final thinking = chunk.thinking;
        if (thinking.isNotEmpty) yield LlmReasoningDelta(thinking);
        final text = chunk.text;
        if (text.isNotEmpty) yield LlmTextDelta(text);
        final finish = chunk.finishReason;
        if (finish == null) continue;
        final usage = chunk.usage;
        yield LlmCompleted(
          finishReason: finish.wireValue,
          toolCalls: [
            for (final call in chunk.toolCalls)
              LlmToolCall(
                id: call.id ?? 'call_${call.index}',
                name: call.function?.name ?? '',
                arguments: call.function?.arguments ?? '',
              ),
          ],
          usage: usage == null
              ? null
              : LlmUsage(
                  promptTokens: usage.promptTokens,
                  completionTokens: usage.completionTokens,
                ),
        );
        return;
      }
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(_failureOf(error), stack);
    }
  }

  /// Параметры загрузки файла в память.
  LlamaCppModelParams _modelParams(LocalModelSettings settings) =>
      LlamaCppModelParams(
        contextSize: settings.contextSize,
        gpuLayers: settings.gpuLayers,
        numberOfThreads: settings.threads,
        batchSize: settings.batchSize,
        useMmap: settings.useMmap,
      );

  /// Параметры генерации. Значения запроса важнее параметров файла.
  GenerationParams _generationParams(
    LlmRequest request,
    LocalModelSettings settings,
  ) => GenerationParams(
    maxTokens: request.maxTokens ?? settings.maxTokens,
    temp: request.temperature ?? settings.temperature,
    topK: settings.topK,
    topP: settings.topP,
    minP: settings.minP,
    penalty: settings.penalty,
    presencePenalty: settings.presencePenalty,
    stopSequences: settings.stopSequences,
    thinkingBudget: settings.thinkingBudget == null
        ? null
        : ThinkingBudget(maxTokens: settings.thinkingBudget!),
  );

  /// Инструменты для грамматики модели. Схемы, которые llamadart не
  /// поддерживает, пропускаются: иначе один MCP-инструмент с `oneOf`
  /// ломал бы весь ход.
  List<ToolDefinition>? _toolsOf(List<LlmToolSpec> specs) {
    if (specs.isEmpty) return null;
    final tools = <ToolDefinition>[];
    for (final spec in specs) {
      try {
        tools.add(
          ToolDefinition.fromJsonSchema(
            name: spec.name,
            description: spec.description,
            schema: spec.parameters,
          ),
        );
      } on Object catch (error) {
        _log.warning(
          'tool ${spec.name} is not supported by llamadart and is skipped',
          error,
        );
      }
    }
    return tools.isEmpty ? null : tools;
  }

  /// Имена инструментов по id вызова: сообщение `tool` несёт только id,
  /// а шаблону нужно имя.
  Map<String, String> _toolNames(List<LlmMessage> messages) => {
    for (final message in messages)
      if (message.role == LlmRole.assistant)
        for (final call in message.toolCalls) call.id: call.name,
  };

  LlamaChatMessage _messageOf(LlmMessage message, Map<String, String> names) {
    switch (message.role) {
      case LlmRole.system:
        return LlamaChatMessage.fromText(
          role: LlamaChatRole.system,
          text: message.content,
        );
      case LlmRole.user:
        if (message.files.isEmpty) {
          return LlamaChatMessage.fromText(
            role: LlamaChatRole.user,
            text: message.content,
          );
        }
        return LlamaChatMessage.withContent(
          role: LlamaChatRole.user,
          content: [
            if (message.content.isNotEmpty) LlamaTextContent(message.content),
            for (final file in message.files) _filePartOf(file),
          ],
        );
      case LlmRole.assistant:
        if (message.toolCalls.isEmpty) {
          return LlamaChatMessage.fromText(
            role: LlamaChatRole.assistant,
            text: message.content,
          );
        }
        return LlamaChatMessage.withContent(
          role: LlamaChatRole.assistant,
          content: [
            if (message.content.isNotEmpty) LlamaTextContent(message.content),
            for (final call in message.toolCalls)
              LlamaToolCallContent(
                id: call.id,
                name: call.name,
                arguments: _argumentsOf(call.arguments),
                rawJson: call.arguments,
              ),
          ],
        );
      case LlmRole.tool:
        final id = message.toolCallId ?? '';
        return LlamaChatMessage.withContent(
          role: LlamaChatRole.tool,
          content: [
            LlamaToolResultContent(
              id: id.isEmpty ? null : id,
              name: names[id] ?? 'tool',
              result: message.content,
            ),
          ],
        );
    }
  }

  /// Вложение → часть сообщения. Изображения и аудио уходят байтами:
  /// путь на диске у порта не передаётся, а байты уже есть в памяти.
  static LlamaContentPart _filePartOf(LlmFilePart file) {
    if (file.isImage) return LlamaImageContent(bytes: file.bytes);
    if (file.mimeType.startsWith('audio/')) {
      return LlamaAudioContent(bytes: file.bytes);
    }
    throw LlmFailure(
      'llamadart supports image and audio attachments only: ${file.name}',
    );
  }

  /// Аргументы вызова как объект. Битый JSON остаётся в `rawJson`, а шаблон
  /// получает пустой объект: бросать ошибку из-за одной строки нельзя.
  static Map<String, dynamic> _argumentsOf(String raw) {
    if (raw.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : const <String, dynamic>{};
    } on FormatException {
      return const {};
    }
  }

  /// Ошибка llamadart → [LlmFailure] с понятными флагами.
  static LlmFailure _failureOf(Object error) {
    if (error is LlmFailure) return error;
    final message = '$error';
    if (error is LlamaContextException) {
      return LlmFailure(message, contextLengthExceeded: true);
    }
    if (error is LlamaUnsupportedException) {
      return LlmFailure(message);
    }
    if (error is LlamaArgumentException) {
      return LlmFailure(message);
    }
    if (error is LlamaStateException) {
      return LlmFailure(message, retryable: message.contains('cancel'));
    }
    if (error is LlamaModelException) {
      return LlmFailure(message);
    }
    if (error is LlamaBackendInitializationException) {
      return LlmFailure(message);
    }
    return LlmFailure('llamadart: $message');
  }
}

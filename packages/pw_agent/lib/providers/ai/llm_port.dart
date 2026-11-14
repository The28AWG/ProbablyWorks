/// Порт провайдера ИИ. AgentLoop зависит только от этих типов, не от OpenRouter.
library;

import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:pw_agent/providers/ai/llm_provider_meta.dart';

export 'llm_provider_meta.dart';

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

/// Файл, переданный модели содержимым (base64 в адаптере). Путь на диске не передаётся.
class LlmFilePart {
  const LlmFilePart({
    required this.name,
    required this.mimeType,
    required this.bytes,
  });

  final String name;
  final String mimeType;
  final Uint8List bytes;

  bool get isImage => mimeType.startsWith('image/');
}

class LlmMessage {
  const LlmMessage({
    required this.role,
    this.content = '',
    this.toolCalls = const [],
    this.toolCallId,
    this.files = const [],
  });

  const LlmMessage.system(String content)
    : this(role: LlmRole.system, content: content);
  const LlmMessage.user(String content)
    : this(role: LlmRole.user, content: content);

  final LlmRole role;
  final String content;
  final List<LlmToolCall> toolCalls;
  final String? toolCallId;

  /// Файлы пользователя для multimodal-модели (только user-сообщения).
  final List<LlmFilePart> files;
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

/// Рассуждения модели (thinking): отдельно от текста ответа. Нет у моделей без рассуждений.
final class LlmReasoningDelta extends LlmEvent {
  const LlmReasoningDelta(this.text);

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
    this.created,
    this.inputModalities,
  });

  final String id;
  final String name;
  final int? contextLength;
  final bool supportsTools;
  final String? promptPrice;
  final String? completionPrice;

  /// Время создания модели в OpenRouter (unix, секунды). Null — неизвестно.
  final int? created;

  /// Входные модальности (`text`, `image`, `file`, ...). Null — неизвестно.
  final List<String>? inputModalities;

  /// Копия модели с заменённым id: реестр добавляет префикс провайдера.
  LlmModelInfo copyWith({
    String? id,
    String? name,
    int? contextLength,
    bool? supportsTools,
    String? promptPrice,
    String? completionPrice,
    int? created,
    List<String>? inputModalities,
  }) => LlmModelInfo(
    id: id ?? this.id,
    name: name ?? this.name,
    contextLength: contextLength ?? this.contextLength,
    supportsTools: supportsTools ?? this.supportsTools,
    promptPrice: promptPrice ?? this.promptPrice,
    completionPrice: completionPrice ?? this.completionPrice,
    created: created ?? this.created,
    inputModalities: inputModalities ?? this.inputModalities,
  );
}

/// Сведения о ключе сервиса: что показывает экран настроек. Все суммы в USD.
/// Вынесены в `llm_provider_meta.dart`; здесь остались только типы порта.

/// Принимает ли модель файл данного типа: `image/*` требует модальность image,
/// `audio/*` — audio, `video/*` — video, остальное — file.
/// Неизвестные модальности (null) означают «не принимает»: лучше отказать, чем отправить зря.
bool acceptsFileType(List<String>? modalities, String mimeType) {
  if (modalities == null) return false;
  final needed = mimeType.startsWith('image/')
      ? 'image'
      : mimeType.startsWith('audio/')
      ? 'audio'
      : mimeType.startsWith('video/')
      ? 'video'
      : 'file';
  return modalities.contains(needed);
}

/// Выбранная модель с деталями, сохранённая в БД. Показывается до загрузки каталога.
class SavedModel extends Equatable {
  const SavedModel({
    required this.id,
    required this.name,
    this.contextLength,
    this.supportsTools = false,
    this.inputModalities,
  });

  final String id;
  final String name;
  final int? contextLength;
  final bool supportsTools;

  /// Входные модальности; null — модель ещё не описана каталогом.
  final List<String>? inputModalities;

  @override
  List<Object?> get props => [
    id,
    name,
    contextLength,
    supportsTools,
    inputModalities,
  ];
}

abstract interface class LlmProvider {
  /// Провайдеры, которые обслуживает этот экземпляр.
  ///
  /// Обычный адаптер возвращает один дескриптор, [LlmProviderRegistry] —
  /// все зарегистрированные. Общие слои читают отсюда id, подписи и префиксы.
  List<LlmProviderDescriptor> get providers;

  /// Стрим ответа. Ошибки выбрасываются как [LlmFailure] (см. core/error).
  Stream<LlmEvent> stream(LlmRequest request);

  /// Список моделей провайдера в его локальных id (без префикса).
  Future<List<LlmModelInfo>> listModels();

  /// Настройки без обращения к сети: включённость, адрес, наличие ключа.
  /// Нужны каталогу и настройкам до первой проверки.
  Future<List<LlmProviderStatus>> configStatuses();

  /// Проверка доступности и статуса. Ошибки возвращаются в
  /// [LlmProviderStatus.error], метод не бросает: один недоступный провайдер
  /// не должен ломать статусы остальных.
  Future<List<LlmProviderStatus>> statuses();
}

/// Удобная база для провайдеров без собственных настроек и проверки.
///
/// Адаптеру достаточно задать дескриптор, [stream] и [listModels].
/// Статусы по умолчанию описывают включённого провайдера без ключа.
abstract class LlmProviderBase implements LlmProvider {
  const LlmProviderBase(this.descriptor);

  final LlmProviderDescriptor descriptor;

  @override
  List<LlmProviderDescriptor> get providers => [descriptor];

  @override
  Future<List<LlmProviderStatus>> configStatuses() async => [
    LlmProviderStatus(id: descriptor.id),
  ];

  @override
  Future<List<LlmProviderStatus>> statuses() => configStatuses();
}

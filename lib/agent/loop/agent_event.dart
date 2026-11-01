import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/core/error/app_failure.dart';
import 'package:probably_works/providers/ai/llm_port.dart';

/// События хода агента для UI. UI перечитывает данные из БД по событиям записи.
sealed class AgentEvent {
  const AgentEvent(this.chatId);

  final String chatId;
}

final class AgentTurnStarted extends AgentEvent {
  const AgentTurnStarted(super.chatId);
}

final class AgentTurnFinished extends AgentEvent {
  const AgentTurnFinished(super.chatId, this.end);

  final TurnEnd end;
}

/// Сообщение записано в БД.
final class AgentMessageAdded extends AgentEvent {
  const AgentMessageAdded(super.chatId, this.message);

  final ChatMessage message;
}

/// Фрагмент текста ассистента (живой стрим, не сохраняется до конца шага).
final class AgentTextDelta extends AgentEvent {
  const AgentTextDelta(super.chatId, this.text, {this.reset = false});

  final String text;

  /// Повтор запроса: UI должен очистить черновик ответа.
  final bool reset;
}

/// Запись инструмента изменилась (статус, pid, результат).
final class AgentRunChanged extends AgentEvent {
  const AgentRunChanged(super.chatId, this.run);

  final ToolRun run;
}

final class AgentQueueChanged extends AgentEvent {
  const AgentQueueChanged(super.chatId, this.size);

  final int size;
}

final class AgentFailureRaised extends AgentEvent {
  const AgentFailureRaised(super.chatId, this.failure);

  final AppFailure failure;
}

/// В workspace есть AGENTS.md/skills, но каталог не доверен.
final class AgentTrustNeeded extends AgentEvent {
  const AgentTrustNeeded(super.chatId, this.workspace);

  final String? workspace;
}

final class AgentUsageUpdated extends AgentEvent {
  const AgentUsageUpdated(super.chatId, this.promptTokens, this.limit);

  final int promptTokens;
  final int limit;
}

final class AgentStateChanged extends AgentEvent {
  const AgentStateChanged(super.chatId);
}

enum TurnEnd {
  /// Модель ответила без инструментов или вызвала finish.
  completed,

  /// Пользователь нажал Stop.
  stopped,

  /// Достигнут лимит шагов: продолжение по кнопке.
  stepLimit,

  /// Ошибка провайдера или Host.
  failed,
}

/// Служебный тип для ответа стрима одного шага.
class StepResult {
  const StepResult({
    required this.text,
    this.toolCalls = const [],
    this.usage,
    this.interruptedBySendNow = false,
    this.stopped = false,
  });

  final String text;
  final List<LlmToolCall> toolCalls;
  final LlmUsage? usage;
  final bool interruptedBySendNow;
  final bool stopped;
}

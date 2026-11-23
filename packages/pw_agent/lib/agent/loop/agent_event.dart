import 'package:pw_agent/agent/context/context_breakdown.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/loop/prompt_queue.dart';
import 'package:pw_agent/agent/turn/turn_changeset.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';

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

/// Фрагмент рассуждений модели (живой стрим, пока шаг не записан в БД).
final class AgentReasoningDelta extends AgentEvent {
  const AgentReasoningDelta(super.chatId, this.text, {this.reset = false});

  final String text;

  /// Повтор запроса: UI должен очистить черновик рассуждений.
  final bool reset;
}

/// Запись инструмента изменилась (статус, pid, результат).
/// Снимок текущего живого шага. Приходит при открытии/переподключении SSE,
/// чтобы клиент догнал уже накопленный текст.
final class AgentTurnSnapshot extends AgentEvent {
  const AgentTurnSnapshot(
    super.chatId, {
    this.text = '',
    this.reasoning = '',
    this.isRunning = true,
  });

  final String text;
  final String reasoning;
  final bool isRunning;
}

final class AgentRunChanged extends AgentEvent {
  const AgentRunChanged(super.chatId, this.run);

  final ToolRun run;
}

/// Снимок изменений файлов хода (manifest на диске обновился).
final class AgentTurnChangesetChanged extends AgentEvent {
  const AgentTurnChangesetChanged(super.chatId, this.changeset);

  final TurnChangeset changeset;
}

final class AgentQueueChanged extends AgentEvent {
  const AgentQueueChanged(super.chatId, this.queue, {this.revision = 0});

  /// Полная очередь на момент события. Размер отдельно не передаётся:
  /// он всегда совпадает с длиной списка.
  final List<QueuedPrompt> queue;

  /// Растёт при каждом изменении очереди. Поздний снимок с меньшей
  /// ревизией не должен перетирать более новый.
  final int revision;

  int get size => queue.length;
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
  const AgentUsageUpdated(
    super.chatId,
    this.promptTokens,
    this.limit, {
    this.estimated = false,
    this.contextWindowKnown = true,
    this.breakdown,
    this.dailyCostUsd,
    this.dailyBudgetUsd,
  });

  final int promptTokens;
  final int limit;

  /// Значение — оценка до первого точного usage от провайдера. Если провайдер
  /// уже присылал точное значение в этом ходе, оценка не отправляется вовсе.
  final bool estimated;

  /// Известен ли размер окна модели. false — [limit] подставлен консервативно,
  /// и интерфейс должен предупредить, что он может быть неточным.
  final bool contextWindowKnown;
  final ContextBreakdown? breakdown;
  final double? dailyCostUsd;
  final double? dailyBudgetUsd;
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

  /// Исчерпан бюджет хода (токены, стоимость или время): продолжение по кнопке.
  budget,

  /// Агент повторяет действия без нового результата: продолжение по кнопке.
  stalled,

  /// Ошибка провайдера или Host.
  failed,
}

/// Служебный тип для ответа стрима одного шага.
class StepResult {
  const StepResult({
    required this.text,
    this.reasoning = '',
    this.toolCalls = const [],
    this.usage,
    this.finishReason,
    this.interruptedBySendNow = false,
    this.stopped = false,
    this.model,
  });

  final String text;
  final String reasoning;
  final List<LlmToolCall> toolCalls;
  final LlmUsage? usage;

  /// Причина завершения ответа провайдером (`stop`, `length`, `tool_calls`).
  /// Нужна, чтобы не считать обрезанный по лимиту ответ полным.
  final String? finishReason;
  final bool interruptedBySendNow;
  final bool stopped;

  /// Фактически использованная модель, если она отличается от запрошенной.
  final String? model;
}

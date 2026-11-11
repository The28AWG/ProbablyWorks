import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/context/context_builder.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/core/data/chat_repository.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/core/util/char_substring.dart';
import 'package:pw_agent/core/util/redactor.dart';
import 'package:pw_agent/core/util/text_clip.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';

/// Сжатие истории: при `softContextRatio` окна — сводка старой части; при `hardContextRatio` —
/// сводка с меньшим окном. Граница сжатия ставится на user/assistant, поэтому пары
/// tool-call/результат не разрываются. Пороги и резерв под ответ задаются [AppLimits].
@lazySingleton
class ContextCompactor {
  ContextCompactor(this._chats, this._llm, this._builder);

  final ChatRepository _chats;
  final LlmProvider _llm;
  final ContextBuilder _builder;

  static const defaultContextLength = 128000;

  /// Порог числа результатов инструментов после границы сжатия, после которого сводка
  /// создаётся даже при малом бюджете: один шаг может принести десятки результатов.
  static const stepGrowthThreshold = 40;
  static const _maxSummaryChars = 6000;

  /// Возвращает обновлённый чат (с новой сводкой), если сжатие выполнено; иначе тот же чат.
  ///
  /// Триггеры: бюджет ≥ `softContextRatio` (hard — окно вдвое меньше), рост числа
  /// tool-результатов после границы сжатия, принудительный запуск ([force]) — ручное
  /// сжатие или смена модели с меньшим окном. Порог считается от полной истории,
  /// а не от уже усечённого окна: иначе десятки коротких сообщений терялись бы без сводки.
  Future<Chat> compactIfNeeded(
    ContextInput input, {
    required String summaryModel,
    bool force = false,
    AppLimits limits = AppLimits.defaults,
  }) async {
    final chat = input.chat;
    final limit = chat.contextLength ?? defaultContextLength;
    final maxReserve = limit > 1 ? limit - 1 : 0;
    final reserve = limits.contextReserveTokens.clamp(0, maxReserve);
    final budget = limit - reserve;
    final estimate = ContextCompactor.estimate(_builder.build(input));
    final stepGrowth = _toolResultsAfterCut(input) > stepGrowthThreshold;
    final soft = budget * limits.softContextRatio;
    final hard = budget * limits.hardContextRatio;
    if (!force && !stepGrowth && estimate < soft) return chat;
    final hardExceeded = !force && estimate >= hard;
    final window = force || hardExceeded
        ? _halfWindow(input.recentWindow)
        : _fullWindow(input.recentWindow);
    return _compact(input, window: window, summaryModel: summaryModel);
  }

  /// Окно не может быть нулевым: иначе сжатие нечего оставлять и `_compact` ничего не сделает.
  static int _fullWindow(int recentWindow) =>
      recentWindow < 1 ? 1 : recentWindow;

  static int _halfWindow(int recentWindow) {
    final full = _fullWindow(recentWindow);
    return full == 1 ? 1 : (full / 2).ceil();
  }

  int _toolResultsAfterCut(ContextInput input) => input.messages
      .where(
        (m) =>
            m.seq > input.chat.compactedUntilSeq && m.role == MessageRole.tool,
      )
      .length;

  static int estimate(List<LlmMessage> messages) =>
      ContextBuilder.estimateTokens(messages);

  Future<Chat> _compact(
    ContextInput input, {
    required int window,
    required String summaryModel,
  }) async {
    final chat = input.chat;
    final history = input.messages
        .where((m) => m.seq > chat.compactedUntilSeq)
        .toList();
    // Обычно хвост — это window. Но при force/hard история может быть короче
    // окна и всё равно не помещаться в модель; тогда сворачиваем половину,
    // иначе сжатие не сделает ничего.
    final effectiveWindow = history.length <= window
        ? (history.length / 2).ceil()
        : window;
    if (effectiveWindow >= history.length) return chat;

    final keepFrom = history.length - effectiveWindow;
    final cutIndex = _safeCutIndex(history, keepFrom);
    if (cutIndex <= 0) return chat;

    final toSummarize = history.sublist(0, cutIndex);
    final cutSeq = history[cutIndex].seq;
    final summary = Redactor.redact(
      await _summarize(chat.compactionSummary, toSummarize, summaryModel),
    );
    final updated = chat.copyWith(
      compactionSummary: summary,
      compactedUntilSeq: cutSeq - 1,
    );
    await _chats.saveChat(updated);
    return updated;
  }

  /// Первый индекс, который можно оставить после сжатия.
  ///
  /// User и assistant — безопасная граница: вызов инструмента и его результаты
  /// не разрываются. Для tool/event ищем ближайшую такую границу назад; если её
  /// нет, сжатие не выполняется и вся история остаётся в контексте.
  static int _safeCutIndex(List<ChatMessage> history, int keepFrom) {
    var index = keepFrom >= history.length ? history.length - 1 : keepFrom;
    while (index >= 0) {
      final role = history[index].role;
      if (role == MessageRole.user || role == MessageRole.assistant) {
        return index;
      }
      index--;
    }
    return -1;
  }

  Future<String> _summarize(
    String? previous,
    List<ChatMessage> messages,
    String model,
  ) async {
    final transcript = StringBuffer();
    for (final m in messages) {
      transcript.writeln(
        '${m.role.name}: ${TextClip.headTail(m.text, maxChars: 800)}',
      );
    }
    final request = LlmRequest(
      model: model,
      messages: [
        const LlmMessage.system(
          'Summarize the conversation for an agent that continues the task. Keep: goal, decisions, '
          'facts, paths, commands and their outcomes, open problems. Be concise, use the user\'s language.',
        ),
        LlmMessage.user(
          'Previous summary:\n${previous ?? '(none)'}\n\nNew messages:\n$transcript',
        ),
      ],
    );
    try {
      final text = StringBuffer();
      await for (final event in _llm.stream(request)) {
        if (event is LlmTextDelta) text.write(event.text);
      }
      final result = text.toString().trim();
      if (result.isNotEmpty) {
        return TextClip.headTail(result, maxChars: _maxSummaryChars);
      }
    } on AppFailure {
      // Heuristic fallback below.
    }
    return _heuristic(previous, messages);
  }

  /// Без LLM: короткий список запросов пользователя и итогов ассистента.
  static String _heuristic(String? previous, List<ChatMessage> messages) {
    final buffer = StringBuffer();
    if (previous != null) buffer.writeln(previous);
    for (final m in messages) {
      if (m.role == MessageRole.user) {
        buffer.writeln('- user asked: ${_short(m.text)}');
      } else if (m.role == MessageRole.assistant && m.text.isNotEmpty) {
        buffer.writeln('- assistant: ${_short(m.text)}');
      }
    }
    return TextClip.headTail(buffer.toString(), maxChars: _maxSummaryChars);
  }

  static String _short(String text) {
    final single = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return single.length <= 200 ? single : '${charPrefix(single, 200)}…';
  }
}

import 'package:injectable/injectable.dart';
import 'package:probably_works/agent/context/context_builder.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/core/data/chat_repository.dart';
import 'package:probably_works/core/error/app_failure.dart';
import 'package:probably_works/core/util/char_substring.dart';
import 'package:probably_works/core/util/redactor.dart';
import 'package:probably_works/core/util/text_clip.dart';
import 'package:probably_works/providers/ai/llm_port.dart';

/// Сжатие истории: при 70% окна — сводка старой части; при 90% — сводка с меньшим окном.
/// Граница сжатия всегда на пользовательском сообщении, пары tool-call не разрываются.
@lazySingleton
class ContextCompactor {
  ContextCompactor(this._chats, this._llm, this._builder);

  final ChatRepository _chats;
  final LlmProvider _llm;
  final ContextBuilder _builder;

  static const defaultContextLength = 128000;
  static const softRatio = 0.7;
  static const hardRatio = 0.9;

  /// Порог числа результатов инструментов в окне, после которого сжатие идёт даже при малом бюджете.
  static const stepGrowthThreshold = 40;
  static const _maxSummaryChars = 6000;

  /// Возвращает обновлённый чат (с новой сводкой), если сжатие выполнено; иначе тот же чат.
  ///
  /// Триггеры: бюджет ≥ 70% (soft) и ≥ 90% (hard, окно вдвое меньше), рост числа tool-результатов
  /// в окне, принудительный запуск ([force]) — ручное сжатие или смена модели с меньшим окном.
  Future<Chat> compactIfNeeded(
    ContextInput input, {
    required String summaryModel,
    bool force = false,
  }) async {
    final chat = input.chat;
    final limit = chat.contextLength ?? defaultContextLength;
    final estimate = ContextCompactor.estimate(_builder.build(input));
    final stepGrowth = _toolResultsInWindow(input) > stepGrowthThreshold;
    if (!force && !stepGrowth && estimate < limit * softRatio) return chat;
    final hard = !force && estimate >= limit * hardRatio;
    final window = force || hard
        ? (input.recentWindow / 2).ceil()
        : input.recentWindow;
    return _compact(input, window: window, summaryModel: summaryModel);
  }

  int _toolResultsInWindow(ContextInput input) {
    final history = input.messages
        .where((m) => m.seq > input.chat.compactedUntilSeq)
        .toList();
    final window = history.length > input.recentWindow
        ? history.sublist(history.length - input.recentWindow)
        : history;
    return window.where((m) => m.role == MessageRole.tool).length;
  }

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
    if (history.length <= window) return chat;

    final keepFrom = history.length - window;
    var cutIndex = -1;
    for (var i = keepFrom; i >= 0; i--) {
      if (history[i].role == MessageRole.user) {
        cutIndex = i;
        break;
      }
    }
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

import 'dart:convert';

/// Расход одного чата за календарный день.
///
/// Хранится в kv-настройках, а не в отдельной таблице: это небольшой счётчик,
/// который читается только при открытии чата и перед шагом модели.
final class ChatDailyUsage {
  const ChatDailyUsage({
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.costUsd = 0,
    this.requests = 0,
  });

  factory ChatDailyUsage.decode(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return const ChatDailyUsage();
      int intOf(String key) {
        final value = json[key];
        return value is num ? value.toInt() : 0;
      }

      final cost = json['costUsd'];
      return ChatDailyUsage(
        promptTokens: intOf('promptTokens'),
        completionTokens: intOf('completionTokens'),
        costUsd: cost is num ? cost.toDouble() : 0,
        requests: intOf('requests'),
      );
    } on FormatException {
      return const ChatDailyUsage();
    }
  }

  final int promptTokens;
  final int completionTokens;

  /// Оценка трат в USD по ценам каталога на момент запроса.
  final double costUsd;

  /// Число запросов к модели за день.
  final int requests;

  int get totalTokens => promptTokens + completionTokens;

  /// Прибавляет один запрос. Расход в USD может быть 0, если цены модели
  /// ещё неизвестны; токены при этом всё равно учитываются.
  ChatDailyUsage plus({
    required int promptTokens,
    required int completionTokens,
    required double costUsd,
  }) => ChatDailyUsage(
    promptTokens: this.promptTokens + promptTokens,
    completionTokens: this.completionTokens + completionTokens,
    costUsd: this.costUsd + costUsd,
    requests: requests + 1,
  );

  String encode() => jsonEncode({
    'promptTokens': promptTokens,
    'completionTokens': completionTokens,
    'costUsd': costUsd,
    'requests': requests,
  });
}

/// Последнее сжатие истории: когда и почему оно произошло.
final class ChatCompactionInfo {
  const ChatCompactionInfo({
    required this.at,
    required this.reason,
    required this.cutoffSeq,
    required this.summaryChars,
  });

  factory ChatCompactionInfo.decode(String raw) {
    final json = jsonDecode(raw);
    if (json is! Map) throw const FormatException('not an object');
    return ChatCompactionInfo(
      at: DateTime.parse('${json['at']}'),
      reason: '${json['reason'] ?? 'threshold'}',
      cutoffSeq: (json['cutoffSeq'] as num?)?.toInt() ?? 0,
      summaryChars: (json['summaryChars'] as num?)?.toInt() ?? 0,
    );
  }

  /// Момент сжатия.
  final DateTime at;

  /// `threshold` или `forced`: автоматический триггер или явное сжатие
  /// (ручное либо после смены модели на меньшее окно).
  final String reason;

  /// Сообщения с `seq <= cutoffSeq` заменены сводкой.
  final int cutoffSeq;

  /// Длина сохранённой сводки в символах.
  final int summaryChars;

  String encode() => jsonEncode({
    'at': at.toIso8601String(),
    'reason': reason,
    'cutoffSeq': cutoffSeq,
    'summaryChars': summaryChars,
  });
}

/// Ключ дня для расхода и лимита. Локальная дата, без времени и часового пояса.
String usageDayKey(DateTime day) {
  final month = day.month.toString().padLeft(2, '0');
  final date = day.day.toString().padLeft(2, '0');
  return '${day.year.toString().padLeft(4, '0')}-$month-$date';
}

import 'package:pw_agent/core/config/app_limits.dart';

/// Накопленный расход одного хода и проверка его потолков.
///
/// Бюджеты считаются по сумме всех запросов хода, а не по последнему:
/// каждый шаг заново отправляет историю, поэтому prompt-токены растут
/// быстрее, чем кажется по размеру контекста. Ноль в любом поле
/// [AppLimits] отключает соответствующий потолок.
class TurnBudget {
  TurnBudget({required this.limits, DateTime? startedAt})
    : startedAt = startedAt ?? DateTime.now();

  final AppLimits limits;

  /// Начало хода: от него считается [AppLimits.turnMaxWallClock].
  final DateTime startedAt;

  /// Суммарные prompt+completion токены хода.
  int tokens = 0;

  /// Накопленная оценка стоимости хода в USD.
  double costUsd = 0;

  /// Добавляет расход одного ответа модели.
  ///
  /// [costUsd] может быть null: каталог не знает цену модели. Такой ответ
  /// не увеличивает денежный бюджет, но его токены всё равно учитываются.
  void add({
    required int promptTokens,
    required int completionTokens,
    double? costUsd,
  }) {
    tokens += promptTokens + completionTokens;
    this.costUsd += costUsd ?? 0;
  }

  /// Причина остановки или null, если бюджеты не исчерпаны.
  ///
  /// Проверка `>=`: ровно выбранный бюджет уже считается достигнутым,
  /// как и дневной лимит расходов.
  String? exceededAt(DateTime now) {
    if (limits.maxTurnTokens > 0 && tokens >= limits.maxTurnTokens) {
      return 'token budget reached: $tokens >= ${limits.maxTurnTokens}';
    }
    if (limits.maxTurnCostUsd > 0 && costUsd >= limits.maxTurnCostUsd) {
      return 'cost budget reached: \$${costUsd.toStringAsFixed(4)} >= '
          '\$${limits.maxTurnCostUsd.toStringAsFixed(2)}';
    }
    if (limits.turnMaxWallClock > Duration.zero &&
        now.difference(startedAt) >= limits.turnMaxWallClock) {
      return 'time budget reached: ${now.difference(startedAt).inSeconds}s >= '
          '${limits.turnMaxWallClock.inSeconds}s';
    }
    return null;
  }
}

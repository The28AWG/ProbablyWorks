import 'dart:math' as math;

/// Решение лимитера: запрос разрешён либо отклонён с паузой до следующей попытки.
final class ApiRateLimitDecision {
  const ApiRateLimitDecision.allowed() : retryAfter = null;

  const ApiRateLimitDecision.denied(this.retryAfter);

  /// Ноль/положительная длительность для `Retry-After`; null — запрос разрешён.
  final Duration? retryAfter;

  bool get allowed => retryAfter == null;
}

/// Простой fixed-window лимитер запросов по ключу (обычно IP клиента).
///
/// Окно выбрано вместо token bucket ради предсказуемого `Retry-After` и
/// простых тестов. Лимит нужен прежде всего для внешнего bind демона: при
/// ошибке клиента и переборе токена сервер не должен молча тратить ресурсы.
final class ApiRateLimiter {
  ApiRateLimiter({
    this.maxRequests = 600,
    this.window = const Duration(minutes: 1),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       assert(maxRequests > 0),
       assert(window > Duration.zero);

  final int maxRequests;
  final Duration window;
  final DateTime Function() _now;

  final _buckets = <String, _Bucket>{};

  /// Учитывает запрос. Повторный вызов в том же окне увеличивает счётчик.
  ApiRateLimitDecision consume(String key) {
    final now = _now();
    _prune(now);
    final bucket = _buckets[key];
    if (bucket == null || now.difference(bucket.startedAt) >= window) {
      _buckets[key] = _Bucket(now);
      return const ApiRateLimitDecision.allowed();
    }
    if (bucket.count >= maxRequests) {
      final left = window - now.difference(bucket.startedAt);
      return ApiRateLimitDecision.denied(
        left < const Duration(seconds: 1) ? const Duration(seconds: 1) : left,
      );
    }
    bucket.count++;
    return const ApiRateLimitDecision.allowed();
  }

  /// Убирает старые окна, чтобы карта не росла от случайных адресов.
  void _prune(DateTime now) {
    if (_buckets.length < 1024) return;
    _buckets.removeWhere(
      (_, bucket) => now.difference(bucket.startedAt) >= window,
    );
    if (_buckets.length >= 2048) {
      // Аварийный предел: лучше забыть старые окна, чем хранить их бесконечно.
      _buckets.clear();
    }
  }
}

final class _Bucket {
  _Bucket(this.startedAt);

  final DateTime startedAt;
  var count = 1;
}

/// Секунды для заголовка `Retry-After`; ограничение защищает от абсурдных
/// значений при больших окнах.
int retryAfterSeconds(Duration value) =>
    math.max(1, math.min(3600, value.inSeconds));

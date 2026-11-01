import 'dart:async';

/// Ограничивает число одновременных операций (например, exec на один Host).
class AsyncSemaphore {
  AsyncSemaphore(this.maxConcurrent) : assert(maxConcurrent > 0);

  final int maxConcurrent;
  int _active = 0;
  final _waiters = <Completer<void>>[];

  int get active => _active;

  Future<T> run<T>(Future<T> Function() action) async {
    await acquire();
    try {
      return await action();
    } finally {
      release();
    }
  }

  /// Ждёт слот. Каждый успешный [acquire] должен быть парным [release].
  Future<void> acquire() {
    if (_active < maxConcurrent) {
      _active++;
      return Future.value();
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _active--;
    }
  }
}

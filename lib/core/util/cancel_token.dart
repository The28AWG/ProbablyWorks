import 'dart:async';

/// Одноразовый сигнал отмены. Подписчики получают уведомление через [whenCancelled].
class CancelToken {
  final Completer<void> _completer = Completer<void>();

  bool get isCancelled => _completer.isCompleted;

  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }
}

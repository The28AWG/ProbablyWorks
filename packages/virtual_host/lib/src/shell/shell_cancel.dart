import 'dart:async';

/// Одноразовый сигнал отмены одного запуска оболочки.
///
/// Своя копия, чтобы пакет не зависел от приложения. Токен создаёт интерпретатор
/// внутри запуска и не отдаёт его наружу: отмена — это закрытие потока событий.
class CancelToken {
  final Completer<void> _completer = Completer<void>();

  /// Уже попросили остановиться.
  bool get isCancelled => _completer.isCompleted;

  /// Завершается, когда вызван [cancel]. Повторный вызов ничего не меняет.
  Future<void> get whenCancelled => _completer.future;

  /// Сигналит отмену. Второй вызов игнорируется.
  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }
}

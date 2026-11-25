import 'dart:async';

Future<void> _tail = Future<void>.value();

/// Выполняет [action] после предыдущего создания `clientId` в этом процессе.
///
/// На платформах без Web Locks конкурирующих вкладок нет, но старт приложения
/// и фоновый запуск могут создать id одновременно. Очередь не даёт им записать
/// два разных значения и потерять запись соседа.
Future<void> withClientIdLock(Future<void> Function() action) async {
  final previous = _tail;
  final completer = Completer<void>();
  _tail = completer.future;
  await previous;
  try {
    await action();
  } finally {
    completer.complete();
  }
}

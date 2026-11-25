import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Имя блокировки в Web Locks. Общее для всех вкладок одного origin.
const _lockName = 'probably-works.client-id';

Future<void> _tail = Future<void>.value();

/// Выполняет [action] под блокировкой Web Locks.
///
/// Web Locks держат блокировку, пока не завершится промис из [action]. Без неё
/// две вкладки, одновременно стартовавшие с пустым `localStorage`, прочитали
/// бы `null` и записали разные id, и одно устройство выглядело бы двумя.
///
/// Если API недоступен (небезопасный контекст, старый браузер), остаётся
/// очередь внутри вкладки. Это не защищает от гонки между вкладками, но лучше,
/// чем ничего: id нужен для группировки, а не для доступа.
Future<void> withClientIdLock(Future<void> Function() action) async {
  web.LockManager? locks;
  try {
    locks = web.window.navigator.locks;
  } on Object {
    locks = null;
  }
  if (locks == null) {
    await _serial(action);
    return;
  }
  try {
    final callback = ((web.Lock _) => action().toJS).toJS;
    await locks.request(_lockName, callback).toDart;
  } on Object {
    // Запрос блокировки неожиданно не удался. Операция идемпотентна: повторное
    // чтение вернёт уже записанный id, поэтому локальная очередь безопасна.
    await _serial(action);
  }
}

Future<void> _serial(Future<void> Function() action) async {
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

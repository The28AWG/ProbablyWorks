import 'dart:async';
import 'dart:js_interop';

import 'package:pw_client/pw_client.dart';
import 'package:web/web.dart' as web;

/// `BroadcastChannel` не хранит состояние и не синхронизирует id между
/// вкладками. Он только позволяет спросить: «этот id уже кто-то держит?».
///
/// Это нужно после дублирования вкладки: некоторые браузеры копируют
/// `sessionStorage`, и без проверки две вкладки стали бы одной сессией.
final class PlatformClientSessionChannel implements ClientSessionChannel {
  PlatformClientSessionChannel() {
    try {
      _channel = web.BroadcastChannel('pworks.client-session');
      _channel?.onmessage = ((web.Event event) {
        final data = (event as web.MessageEvent).data?.dartify();
        if (data is Map) {
          _handle(Map<Object?, Object?>.from(data));
        }
      }).toJS;
    } on Object {
      // BroadcastChannel нет: дубликат вкладки останется на усмотрение
      // серверной проверки и TTL.
      _channel = null;
    }
  }

  web.BroadcastChannel? _channel;
  final _messages = StreamController<Map<Object?, Object?>>.broadcast();

  /// Префикс ключей [PlatformClientSessionStore] в `sessionStorage`.
  static const _sessionKeyPrefix = 'pworks.session.';

  /// Спрашивает другие вкладки, не занят ли этот id.
  @override
  Future<bool> isActive(String id) async {
    final channel = _channel;
    if (channel == null) return false;
    final answer = Completer<bool>();
    final sub = _messages.stream.listen((message) {
      if (message['type'] == 'taken' && message['id'] == id) {
        if (!answer.isCompleted) answer.complete(true);
      }
    });
    channel.postMessage({'type': 'claim', 'id': id}.jsify());
    try {
      // Запас для вкладки в фоне, где событие BroadcastChannel может быть
      // отложено. Это по-прежнему best-effort: если вкладка не ответила,
      // сервер переиспользует сессию, и дубликат останется одной сессией.
      // Секунда задерживала каждый reload, даже когда соседей нет: ответ
      // живой вкладки приходит за миллисекунды, а фоновая может не успеть
      // и за секунду. Длинное ожидание не спасало, а только тормозило
      // открытие; компромисс — 150 мс.
      return await answer.future.timeout(const Duration(milliseconds: 150));
    } on TimeoutException {
      return false;
    } finally {
      await sub.cancel();
    }
  }

  void _handle(Map<Object?, Object?> message) {
    final id = message['id'];
    if (message['type'] == 'claim' && id is String && _owns(id)) {
      _channel?.postMessage({'type': 'taken', 'id': id}.jsify());
    }
    if (!_messages.isClosed) _messages.add(message);
  }

  /// Держит ли эта вкладка сессию [id].
  ///
  /// Отвечать `taken` на любой `claim` нельзя: любая открытая вкладка
  /// запретила бы reload другой вкладки, даже если у неё другой id.
  bool _owns(String id) {
    try {
      final storage = web.window.sessionStorage;
      for (var index = 0; index < storage.length; index++) {
        final key = storage.key(index);
        if (key != null &&
            key.startsWith(_sessionKeyPrefix) &&
            storage.getItem(key) == id) {
          return true;
        }
      }
    } on Object {
      // Хранилище недоступно: дубликат остаётся best-effort.
    }
    return false;
  }

  /// Закрывает BroadcastChannel и его поток сообщений.
  @override
  void close() {
    _channel?.close();
    _channel = null;
    unawaited(_messages.close());
  }
}

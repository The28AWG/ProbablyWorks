import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Отправляет серверу сигнал `closing` так, чтобы запрос пережил выгрузку
/// страницы.
///
/// `keepalive` позволяет браузеру довести запрос после закрытия вкладки.
/// Ответ не читаем: страница уже уходит, а сервер сам решит, когда удалить
/// сессию. Заголовки нужны те же, что у обычного запроса: Bearer-токен и
/// `X-Client-Session`.
Future<void> sendSessionClosing({
  required Uri baseUri,
  required String token,
  required String sessionId,
  required Map<String, String> headers,
}) async {
  final requestHeaders = web.Headers()
    ..set('Authorization', 'Bearer $token')
    ..set('x-client-session', sessionId)
    ..set('Content-Type', 'application/json');
  for (final entry in headers.entries) {
    requestHeaders.set(entry.key, entry.value);
  }
  await web.window
      .fetch(
        baseUri.resolve('/api/v1/client/session').toString().toJS,
        web.RequestInit(
          method: 'PUT',
          headers: requestHeaders,
          body: '{"closing":true}'.toJS,
          keepalive: true,
        ),
      )
      .toDart;
}

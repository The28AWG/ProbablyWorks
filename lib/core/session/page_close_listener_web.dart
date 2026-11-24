import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Обработчик закрытия web-вкладки.
typedef PageCloseCallback = Future<void> Function();

/// Сообщает приложению, что вкладка уходит со страницы.
///
/// `pagehide` надёжнее `beforeunload`: он не отменяется и приходит и при
/// закрытии вкладки, и при уходе с сайта. Переход в bfcache (`persisted`)
/// пропускаем: страница ещё жива и может вернуться без нового рукопожатия.
/// `unload` не используем — он устарел и на мобильных часто не срабатывает.
void listenForPageClose(PageCloseCallback callback) {
  var closingSent = false;
  void onPageShow(web.Event event) {
    if (event.isA<web.PageTransitionEvent>() &&
        (event as web.PageTransitionEvent).persisted) {
      // Страница вернулась из bfcache: следующий уход снова должен сообщить.
      closingSent = false;
    }
  }

  void onPageHide(web.Event event) {
    if (event.isA<web.PageTransitionEvent>() &&
        (event as web.PageTransitionEvent).persisted) {
      return;
    }
    if (closingSent) return;
    closingSent = true;
    unawaited(callback());
  }

  web.window.addEventListener('pagehide', onPageHide.toJS);
  web.window.addEventListener('pageshow', onPageShow.toJS);
}

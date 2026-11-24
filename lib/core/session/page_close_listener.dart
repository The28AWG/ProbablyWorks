/// Сигнал о том, что web-вкладка уходит со страницы.
library;

export 'page_close_listener_stub.dart'
    if (dart.library.js_interop) 'page_close_listener_web.dart';

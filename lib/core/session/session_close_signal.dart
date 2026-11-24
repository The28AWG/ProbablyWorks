/// Keepalive-сигнал о закрытии web-вкладки.
library;

export 'session_close_signal_stub.dart'
    if (dart.library.js_interop) 'session_close_signal_web.dart';

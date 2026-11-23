/// Проверка занятости `sessionId` между вкладками web-клиента.
library;

export 'client_session_channel_stub.dart'
    if (dart.library.js_interop) 'client_session_channel_web.dart';

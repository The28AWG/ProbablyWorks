/// Хранилище клиентской сессии: `sessionStorage` на web, память на остальных
/// платформах.
library;

export 'client_session_store_stub.dart'
    if (dart.library.js_interop) 'client_session_store_web.dart';

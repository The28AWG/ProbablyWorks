/// Платформенный бейдж web-приложения.
///
/// Реализация подменяется conditional import: на VM и в тестах нет
/// `navigator.setAppBadge`, а импортировать `dart:js_interop` в общий код
/// нельзя.
library;

export 'web_app_badge_stub.dart'
    if (dart.library.js_interop) 'web_app_badge_web.dart';

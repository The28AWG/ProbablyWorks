import 'package:pw_client/pw_client.dart';
import 'package:web/web.dart' as web;

/// `sessionStorage` переживает reload вкладки и умирает вместе с вкладкой.
///
/// Не `localStorage`: он общий для всех вкладок и переживает закрытие браузера,
/// а нам нужны разные сессии у разных вкладок.
final class PlatformClientSessionStore implements ClientSessionStore {
  static const _prefix = 'pworks.session.';

  @override
  String? read(String key) {
    try {
      return web.window.sessionStorage.getItem('$_prefix$key');
    } on Object {
      // Приватный режим, отключённое хранилище или sandbox iframe.
      return null;
    }
  }

  @override
  void write(String key, String value) {
    try {
      web.window.sessionStorage.setItem('$_prefix$key', value);
    } on Object {
      // Работаем без сохранения между перезагрузками.
    }
  }

  @override
  void delete(String key) {
    try {
      web.window.sessionStorage.removeItem('$_prefix$key');
    } on Object {
      // Нечего чистить.
    }
  }
}

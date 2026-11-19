/// Значения web-сборки, которые зависят от способа её размещения.
///
/// Статический web-клиент и страница, которую отдаёт сервер, — разные
/// релизы. У них отличается только адрес сервера по умолчанию: статике нужен
/// явный адрес API, а встроенной странице — текущий origin.
final class WebHostConfig {
  const WebHostConfig({required this.defaultServerUrl});

  /// Web-клиент размещён отдельно от API: по умолчанию предлагаем локальный
  /// демон, потому что публичный статический хостинг не содержит API.
  factory WebHostConfig.staticHosting() =>
      const WebHostConfig(defaultServerUrl: 'http://127.0.0.1:7787');

  /// Web-клиент отдаёт сам сервер: API находится на том же origin.
  factory WebHostConfig.hosted() {
    final base = Uri.base;
    return WebHostConfig(
      defaultServerUrl: base.hasAuthority
          ? base.origin
          : 'http://127.0.0.1:7787',
    );
  }

  /// Адрес сервера, который подставляется на экране подключения.
  final String defaultServerUrl;
}

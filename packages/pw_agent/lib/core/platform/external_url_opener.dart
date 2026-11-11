/// Открывает внешний URL (например, страницу OAuth) в браузере пользователя.
///
/// Агент не зависит от Flutter: клиент использует `url_launcher`, демон —
/// системную команду или печать ссылки в лог.
abstract interface class ExternalUrlOpener {
  Future<void> open(Uri url);
}

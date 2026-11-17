/// Сырой результат загрузки страницы.
final class FetchedPage {
  const FetchedPage({
    required this.requestedUrl,
    required this.finalUrl,
    required this.statusCode,
    required this.contentType,
    required this.body,
    required this.fetchedAt,
    this.etag = '',
    this.lastModified = '',
  });

  final String requestedUrl;
  final String finalUrl;
  final int statusCode;
  final String contentType;

  /// Тело уже декодировано с учётом charset из заголовка или `<meta charset>`.
  final String body;
  final DateTime fetchedAt;
  final String etag;
  final String lastModified;

  bool get isHtml {
    final type = contentType.toLowerCase();
    return type.contains('text/html') || type.contains('application/xhtml+xml');
  }

  bool get isJson =>
      contentType.toLowerCase().contains('application/json') ||
      contentType.toLowerCase().contains('+json');
}

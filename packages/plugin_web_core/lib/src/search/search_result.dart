/// Один результат поиска в нормализованном виде.
final class SearchResult {
  const SearchResult({
    required this.title,
    required this.url,
    this.snippet = '',
    this.published = '',
  });

  final String title;
  final String url;
  final String snippet;
  final String published;
}

/// Параметры поискового запроса.
final class SearchQuery {
  const SearchQuery({
    required this.text,
    this.count = 5,
    this.freshness = 'any',
    this.sites = const [],
  });

  final String text;
  final int count;

  /// `any`, `day`, `week`, `month`, `year`.
  final String freshness;
  final List<String> sites;
}

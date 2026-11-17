/// Раздел оглавления страницы.
final class PageOutlineEntry {
  const PageOutlineEntry({
    required this.level,
    required this.title,
    required this.offset,
  });

  final int level;
  final String title;

  /// Смещение в символах от начала [PageDocument.text].
  final int offset;
}

/// Нормализованный документ страницы.
///
/// [text] — единственный источник истины для чтения и grep. [cleanedHtml]
/// хранится отдельно и нужен только для `extract` по CSS-селекторам; это не
/// исходная страница, а DOM после удаления скриптов, стилей и обвязки.
final class PageDocument {
  const PageDocument({
    required this.requestedUrl,
    required this.finalUrl,
    required this.title,
    required this.text,
    required this.cleanedHtml,
    required this.outline,
    this.lang = '',
    this.published = '',
    this.contentType = '',
    this.fetchedAt,
  });

  final String requestedUrl;
  final String finalUrl;
  final String title;
  final String lang;
  final String published;
  final String contentType;
  final DateTime? fetchedAt;

  /// Текущее представление: статья, main, full, selector, links или tables.
  final String text;

  /// Очищенный DOM. Пустая строка — страница не HTML.
  final String cleanedHtml;

  final List<PageOutlineEntry> outline;

  int get charCount => text.length;
  bool get canExtract => cleanedHtml.isNotEmpty;
}

import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:plugin_web_core/src/fetch/fetched_page.dart';
import 'package:plugin_web_core/src/fetch/markdown_writer.dart';
import 'package:plugin_web_core/src/fetch/page_document.dart';
import 'package:plugin_web_core/src/web_error.dart';

/// Очищенная HTML-страница: DOM без скриптов, стилей и обвязки.
final class CleanedPage {
  const CleanedPage({
    required this.document,
    required this.html,
    required this.title,
    required this.lang,
    required this.published,
    this.hadScripts = false,
  });

  final dom.Document document;
  final String html;
  final String title;
  final String lang;
  final String published;

  /// Были ли на странице скрипты до очистки. Нужно, чтобы отличить пустую
  /// страницу от страницы, которой нужен JavaScript.
  final bool hadScripts;
}

/// Разбирает HTML и превращает его в нормализованный документ.
final class PageExtractor {
  const PageExtractor();

  static const _removeSelectors = [
    'script',
    'style',
    'noscript',
    'template',
    'svg',
    'canvas',
    'iframe',
    'form',
    'button',
    'input',
    'select',
    'textarea',
    'nav',
    'footer',
    'aside',
    '[role="navigation"]',
    '[role="banner"]',
    '[role="contentinfo"]',
    '[aria-hidden="true"]',
    '[hidden]',
  ];

  /// Разбирает и очищает страницу. Метаданные читаются до удаления script,
  /// чтобы не потерять JSON-LD.
  CleanedPage clean(FetchedPage page) {
    final document = html.parse(page.body);
    final hadScripts = document.querySelectorAll('script').isNotEmpty;
    final title = _titleOf(document);
    final lang = document.documentElement?.attributes['lang']?.trim() ?? '';
    final published = _publishedOf(document);
    for (final selector in _removeSelectors) {
      for (final node in document.querySelectorAll(selector)) {
        node.remove();
      }
    }
    for (final node in document.querySelectorAll('[style]')) {
      final style = (node.attributes['style'] ?? '').toLowerCase();
      if (style.contains('display:none') ||
          style.contains('display: none') ||
          style.contains('visibility:hidden') ||
          style.contains('visibility: hidden')) {
        node.remove();
      } else {
        node.attributes.remove('style');
      }
    }
    for (final node in document.querySelectorAll('*')) {
      for (final name in node.attributes.keys.toList()) {
        final key = '$name'.toLowerCase();
        if (key.startsWith('on') || key == 'srcset' || key == 'sizes') {
          node.attributes.remove(name);
        }
      }
    }
    final root = document.documentElement;
    return CleanedPage(
      document: document,
      html: root?.outerHtml ?? document.outerHtml,
      title: title,
      lang: lang,
      published: published,
      hadScripts: hadScripts,
    );
  }

  /// Строит представление страницы в запрошенном режиме.
  PageDocument render(
    CleanedPage page, {
    required FetchedPage source,
    required String mode,
    String? selector,
  }) {
    final writer = const MarkdownWriter();
    final baseUrl = source.finalUrl;
    final (text, outline) = switch (mode) {
      'full' => _write(writer, page.document.body, baseUrl),
      'selector' => _selector(writer, page.document, selector, baseUrl),
      'links' => (_links(page.document, baseUrl), const <PageOutlineEntry>[]),
      'tables' => _tables(writer, page.document, baseUrl),
      'main' => _write(
        writer,
        page.document.querySelector('main') ??
            page.document.querySelector('article') ??
            page.document.querySelector('[role="main"]') ??
            page.document.body,
        baseUrl,
      ),
      _ => _write(
        writer,
        page.document.querySelector('article') ??
            page.document.querySelector('main') ??
            page.document.querySelector('[role="main"]') ??
            page.document.body,
        baseUrl,
      ),
    };
    if (text.trim().isEmpty) {
      if (page.hadScripts) {
        throw const WebToolException(
          'page_requires_javascript',
          'the page has no readable HTML text and may require JavaScript',
          hint: 'the web plugin does not run JavaScript in this version',
        );
      }
      throw const WebToolException(
        'extraction_empty',
        'no readable text was found on the page',
        hint: 'try mode=full or mode=selector',
      );
    }
    return PageDocument(
      requestedUrl: source.requestedUrl,
      finalUrl: source.finalUrl,
      title: page.title,
      lang: page.lang,
      published: page.published,
      contentType: source.contentType,
      fetchedAt: source.fetchedAt,
      text: text,
      cleanedHtml: page.html,
      outline: outline,
    );
  }

  /// Строит документ из уже очищенного HTML (например, при повторном open).
  PageDocument renderStored(
    String cleanedHtml, {
    required String requestedUrl,
    required String finalUrl,
    required String title,
    String lang = '',
    String published = '',
    String contentType = 'text/html',
    DateTime? fetchedAt,
    required String mode,
    String? selector,
  }) {
    final document = html.parse(cleanedHtml);
    final cleaned = CleanedPage(
      document: document,
      html: cleanedHtml,
      title: title,
      lang: lang,
      published: published,
    );
    return render(
      cleaned,
      source: FetchedPage(
        requestedUrl: requestedUrl,
        finalUrl: finalUrl,
        statusCode: 200,
        contentType: contentType,
        body: cleanedHtml,
        fetchedAt: fetchedAt ?? DateTime.now(),
      ),
      mode: mode,
      selector: selector,
    );
  }

  /// Проверяет, что из HTML можно собирать данные.
  dom.Document parseCleaned(String cleanedHtml) => html.parse(cleanedHtml);

  static (String, List<PageOutlineEntry>) _write(
    MarkdownWriter writer,
    dom.Element? root,
    String baseUrl,
  ) {
    if (root == null) return ('', const []);
    final result = writer.write(root, baseUrl: baseUrl);
    return (result.text, result.outline);
  }

  static (String, List<PageOutlineEntry>) _selector(
    MarkdownWriter writer,
    dom.Document document,
    String? selector,
    String baseUrl,
  ) {
    final value = selector?.trim() ?? '';
    if (value.isEmpty) {
      throw const WebToolException(
        'bad_arguments',
        'mode=selector requires selector',
      );
    }
    final elements = document.querySelectorAll(value);
    if (elements.isEmpty) {
      throw WebToolException(
        'selector_matched_nothing',
        'selector matched nothing: $value',
        hint: 'use mode=links to inspect the page structure',
      );
    }
    final parts = <String>[];
    final outline = <PageOutlineEntry>[];
    var offset = 0;
    const separator = '\n\n---\n\n';
    for (final element in elements) {
      final result = writer.write(element, baseUrl: baseUrl);
      if (result.text.isEmpty) continue;
      if (parts.isNotEmpty) offset += separator.length;
      parts.add(result.text);
      outline.addAll([
        for (final entry in result.outline)
          PageOutlineEntry(
            level: entry.level,
            title: entry.title,
            offset: offset + entry.offset,
          ),
      ]);
      offset += result.text.length;
    }
    return (parts.join(separator), outline);
  }

  static String _links(dom.Document document, String baseUrl) {
    final seen = <String>{};
    final buffer = StringBuffer();
    for (final link in document.querySelectorAll('a[href]')) {
      final href = (link.attributes['href'] ?? '').trim();
      if (href.isEmpty || href.startsWith('#')) continue;
      final uri = Uri.tryParse(href);
      final resolved = uri == null
          ? href
          : (uri.hasScheme
                ? href
                : Uri.tryParse(baseUrl)?.resolveUri(uri).toString() ?? href);
      if (resolved.startsWith('javascript:') ||
          resolved.startsWith('mailto:')) {
        continue;
      }
      final text = link.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      final line = text.isEmpty ? resolved : '$text — $resolved';
      if (seen.add(line)) buffer.writeln(line);
    }
    return buffer.toString().trim();
  }

  static (String, List<PageOutlineEntry>) _tables(
    MarkdownWriter writer,
    dom.Document document,
    String baseUrl,
  ) {
    final parts = <String>[];
    const separator = '\n\n---\n\n';
    for (final table in document.querySelectorAll('table')) {
      final result = writer.write(table, baseUrl: baseUrl);
      if (result.text.isEmpty) continue;
      parts.add(result.text);
    }
    return (parts.join(separator), const []);
  }

  static String _titleOf(dom.Document document) {
    final og = document
        .querySelector('meta[property="og:title"]')
        ?.attributes['content']
        ?.trim();
    if (og != null && og.isNotEmpty) return og;
    final title = document.querySelector('title')?.text.trim() ?? '';
    if (title.isNotEmpty) return title;
    return document.querySelector('h1')?.text.trim() ?? '';
  }

  static String _publishedOf(dom.Document document) {
    const selectors = [
      'meta[property="article:published_time"]',
      'meta[name="date"]',
      'meta[name="publishdate"]',
      'meta[itemprop="datePublished"]',
      'time[datetime]',
    ];
    for (final selector in selectors) {
      final element = document.querySelector(selector);
      final value =
          element?.attributes['content'] ??
          element?.attributes['datetime'] ??
          element?.text;
      if (value != null && value.trim().isNotEmpty) return value.trim();
    }
    for (final script in document.querySelectorAll(
      'script[type="application/ld+json"]',
    )) {
      final value = _jsonLdDate(script.text);
      if (value != null && value.isNotEmpty) return value;
    }
    return '';
  }

  static String? _jsonLdDate(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return _findDate(decoded);
    } on FormatException {
      return null;
    }
  }

  static String? _findDate(Object? value) {
    if (value is List) {
      for (final item in value) {
        final found = _findDate(item);
        if (found != null) return found;
      }
      return null;
    }
    if (value is Map) {
      final date = value['datePublished'];
      if (date is String && date.isNotEmpty) return date;
      final graph = value['@graph'];
      if (graph != null) {
        final found = _findDate(graph);
        if (found != null) return found;
      }
    }
    return null;
  }
}

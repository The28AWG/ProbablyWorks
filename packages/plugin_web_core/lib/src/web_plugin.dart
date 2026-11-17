import 'dart:convert';
import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:html/dom.dart' as dom;
import 'package:plugin_api/plugin_api.dart';
import 'package:plugin_web_core/src/fetch/fetched_page.dart';
import 'package:plugin_web_core/src/fetch/page_document.dart';
import 'package:plugin_web_core/src/fetch/page_extractor.dart';
import 'package:plugin_web_core/src/fetch/page_fetcher.dart';
import 'package:plugin_web_core/src/page_store.dart';
import 'package:plugin_web_core/src/search/search_registry.dart';
import 'package:plugin_web_core/src/search/search_result.dart';
import 'package:plugin_web_core/src/web_config.dart';
import 'package:plugin_web_core/src/web_error.dart';
import 'package:plugin_web_core/src/web_secrets.dart';

/// Плагин «Веб»: поиск, чтение страниц и сбор данных.
///
/// Инструменты read-only: `mutatesHost` равен false, поэтому ход остаётся
/// откатываемым. Сеть идёт только через [PluginHost], а страницы живут в
/// ограниченном [WebPageStore], а не в контексте модели.
final class WebPlugin implements Plugin {
  WebPlugin({
    WebPageStore? pages,
    SearchSessionStore? sessions,
    PageFetcher? fetcher,
    PageExtractor? extractor,
  }) : _pages = pages ?? WebPageStore(),
       _sessions = sessions ?? SearchSessionStore(),
       _fetcher = fetcher ?? PageFetcher(),
       _extractor = extractor ?? const PageExtractor();

  static const _maxToolChars = 20000;
  static const _openModes = {
    'article',
    'main',
    'full',
    'selector',
    'links',
    'tables',
  };

  final WebPageStore _pages;
  final SearchSessionStore _sessions;
  final PageFetcher _fetcher;
  final PageExtractor _extractor;

  @override
  String get id => 'web';

  @override
  Set<String> get dependsOn => const {};

  @override
  bool get defaultEnabled => false;

  @override
  Future<List<PluginTool>> createTools(PluginSettings settings) async {
    final config = WebConfig.fromJson(await settings.read());
    final hasKey =
        !config.search.needsKey ||
        await settings.hasSecret(WebSecrets.searchKey);
    final canSearch =
        config.search.effectiveEndpoint.trim().isNotEmpty && hasKey;
    return [
      if (canSearch)
        PluginTool(
          name: 'search',
          title: 'Найти в интернете',
          description:
              'Search the web. Returns numbered results with title, URL, '
              'snippet and date. Pass the number as ref to web_open or '
              'web_extract instead of repeating the URL.',
          inputSchema: _searchSchema,
          mutatesHost: false,
          run: (arguments, host) =>
              _guard(() => _search(arguments, host, config)),
        ),
      PluginTool(
        name: 'open',
        title: 'Открыть страницу',
        description:
            'Open a web page and return its readable text as Markdown. '
            'Returns page_id, outline and next_offset. Use web_read to '
            'continue, grep or show the outline. Use web_extract to collect '
            'structured records with CSS selectors.',
        inputSchema: _openSchema,
        mutatesHost: false,
        run: (arguments, host) => _guard(() => _open(arguments, host, config)),
      ),
      PluginTool(
        name: 'read',
        title: 'Прочитать страницу',
        description:
            'Read an opened page by page_id: a character chunk, a literal '
            'or regex grep over lines, or the outline. Does not use the '
            'network and does not need a new approval.',
        inputSchema: _readSchema,
        mutatesHost: false,
        run: (arguments, host) => _guard(() => _read(arguments, host)),
      ),
      PluginTool(
        name: 'extract',
        title: 'Собрать данные со страницы',
        description:
            'Collect structured records from an opened page with a CSS '
            'selector per record and a CSS selector per field. Attribute '
            'values use selector@href or selector@data-id. Returns JSON.',
        inputSchema: _extractSchema,
        mutatesHost: false,
        run: (arguments, host) =>
            _guard(() => _extract(arguments, host, config)),
      ),
    ];
  }

  Future<PluginToolResult> _guard(
    Future<PluginToolResult> Function() body,
  ) async {
    try {
      return await body();
    } on WebToolException catch (error) {
      return PluginToolResult(error.format(), isError: true);
    } on StateError catch (error) {
      if (error.message.contains('plugin secret not found')) {
        return const PluginToolResult(
          'error: search_not_configured\n'
          'message: the search API key is not saved\n'
          'hint: open the web plugin settings and save the key',
          isError: true,
        );
      }
      return PluginToolResult(
        'error: internal_error\nmessage: ${error.message}',
        isError: true,
      );
    } on Object catch (error) {
      return PluginToolResult(
        'error: internal_error\nmessage: $error',
        isError: true,
      );
    }
  }

  Future<PluginToolResult> _search(
    Map<String, dynamic> arguments,
    PluginHost host,
    WebConfig config,
  ) async {
    final query = _argString(arguments, 'query');
    if (query.isEmpty) {
      throw const WebToolException('bad_arguments', 'query is required');
    }
    final provider = SearchRegistry.providerFor(config.search.provider);
    final requested = _argInt(
      arguments,
      'count',
      fallback: config.search.maxResults,
    );
    final count = _clampInt(requested, 1, 10);
    final results = await provider.search(
      query: SearchQuery(
        text: query,
        count: count,
        freshness: _argString(arguments, 'freshness', fallback: 'any'),
        sites: _argStrings(arguments['site']),
      ),
      config: config,
      host: host,
    );
    final unique = <String, SearchResult>{};
    for (final result in results) {
      unique.putIfAbsent(_normalizeUrl(result.url), () => result);
    }
    final normalized = unique.values.take(count).toList();
    _sessions.put(host.chatId, normalized);
    if (normalized.isEmpty) {
      return const PluginToolResult(
        'query: done\nresults: 0\n\nNo results. Try another query or fewer '
        'site restrictions.',
      );
    }
    final buffer = StringBuffer()
      ..writeln('query: $query')
      ..writeln('provider: ${config.search.provider.name}')
      ..writeln('results: ${normalized.length}')
      ..writeln();
    for (var index = 0; index < normalized.length; index++) {
      final result = normalized[index];
      buffer
        ..writeln('[${index + 1}] ${result.title}')
        ..writeln('    url: ${result.url}');
      if (result.published.isNotEmpty) {
        buffer.writeln('    published: ${result.published}');
      }
      if (result.snippet.isNotEmpty) {
        buffer.writeln('    snippet: ${_clip(result.snippet, 500)}');
      }
      buffer.writeln();
    }
    return PluginToolResult(buffer.toString().trim());
  }

  Future<PluginToolResult> _open(
    Map<String, dynamic> arguments,
    PluginHost host,
    WebConfig config,
  ) async {
    final pageId = _argString(arguments, 'page_id');
    final url = _argString(arguments, 'url');
    final ref = _argString(arguments, 'ref');
    final mode = _argString(arguments, 'mode', fallback: 'article');
    if (!_openModes.contains(mode)) {
      throw WebToolException(
        'bad_arguments',
        'unknown open mode: $mode',
        hint: 'use article, main, full, selector, links or tables',
      );
    }
    final selector = _argString(arguments, 'selector');
    final maxChars = _argInt(
      arguments,
      'max_chars',
      fallback: config.fetch.maxChars,
    );
    final chars = _clampInt(maxChars, 1000, 30000);
    final offset = _clampInt(_argInt(arguments, 'offset'), 0, 1 << 31);

    if (pageId.isNotEmpty) {
      if (url.isNotEmpty || ref.isNotEmpty) {
        throw const WebToolException(
          'bad_arguments',
          'pass either page_id, url or ref, not several',
        );
      }
      final snapshot = _pages.get(host.chatId, pageId);
      if (snapshot == null) {
        throw const WebToolException(
          'page_expired',
          'page is not in the cache anymore',
          hint: 'open the URL again',
        );
      }
      final rendered = _renderStored(snapshot, mode: mode, selector: selector);
      final updated = _pages.replaceView(
        host.chatId,
        pageId,
        mode: mode,
        text: rendered.text,
        outline: rendered.outline,
      );
      if (updated == null) {
        throw const WebToolException('page_expired', 'page is not in cache');
      }
      return _formatOpen(updated, maxChars: chars, offset: offset);
    }

    final target = _resolveTarget(host.chatId, url: url, ref: ref);
    final fetched = await _fetcher.fetch(
      url: target,
      config: config,
      host: host,
    );
    final snapshot = await _storeFetched(
      host.chatId,
      fetched,
      mode: mode,
      selector: selector,
      allowEmpty: false,
    );
    return _formatOpen(snapshot, maxChars: chars, offset: offset);
  }

  Future<PluginToolResult> _read(
    Map<String, dynamic> arguments,
    PluginHost host,
  ) async {
    final pageId = _argString(arguments, 'page_id');
    if (pageId.isEmpty) {
      throw const WebToolException('bad_arguments', 'page_id is required');
    }
    final snapshot = _pages.get(host.chatId, pageId);
    if (snapshot == null) {
      throw const WebToolException(
        'page_expired',
        'page is not in the cache anymore',
        hint: 'open the URL again',
      );
    }
    final mode = _argString(arguments, 'mode', fallback: 'chunk');
    return switch (mode) {
      'grep' => _grep(snapshot, arguments),
      'outline' => _outline(snapshot),
      'chunk' => _chunk(snapshot, arguments),
      _ => throw WebToolException(
        'bad_arguments',
        'unknown read mode: $mode',
        hint: 'use chunk, grep or outline',
      ),
    };
  }

  Future<PluginToolResult> _extract(
    Map<String, dynamic> arguments,
    PluginHost host,
    WebConfig config,
  ) async {
    final container = _argString(arguments, 'container');
    if (container.isEmpty) {
      throw const WebToolException('bad_arguments', 'container is required');
    }
    final fields = _argFields(arguments['fields']);
    if (fields.isEmpty) {
      throw const WebToolException('bad_arguments', 'fields are required');
    }
    final pageId = _argString(arguments, 'page_id');
    final url = _argString(arguments, 'url');
    final ref = _argString(arguments, 'ref');
    if ([pageId, url, ref].where((value) => value.isNotEmpty).length != 1) {
      throw const WebToolException(
        'bad_arguments',
        'pass exactly one of page_id, url or ref',
      );
    }
    final snapshot = pageId.isNotEmpty
        ? _pages.get(host.chatId, pageId)
        : await _storeFetched(
            host.chatId,
            await _fetcher.fetch(
              url: _resolveTarget(host.chatId, url: url, ref: ref),
              config: config,
              host: host,
            ),
            mode: 'full',
            allowEmpty: true,
          );
    if (snapshot == null) {
      throw const WebToolException('page_expired', 'page is not in cache');
    }
    if (snapshot.cleanedHtml.isEmpty) {
      throw const WebToolException(
        'not_html',
        'this page is not HTML, so CSS extraction is unavailable',
      );
    }
    final document = _extractor.parseCleaned(snapshot.cleanedHtml);
    final nodes = document.querySelectorAll(container);
    if (nodes.isEmpty) {
      throw WebToolException(
        'selector_matched_nothing',
        'container matched nothing: $container',
        hint: 'use web_open(mode: links) to inspect the page structure',
      );
    }
    final offset = _clampInt(_argInt(arguments, 'offset'), 0, nodes.length);
    final limit = _clampInt(_argInt(arguments, 'limit', fallback: 50), 1, 100);
    final end = math.min(offset + limit, nodes.length);
    var records = <Map<String, Object?>>[
      for (final node in nodes.skip(offset).take(end - offset))
        _recordOf(node, fields, snapshot.finalUrl),
    ];
    var truncated = end < nodes.length;
    var encoded = _encodeRecords(
      snapshot: snapshot,
      total: nodes.length,
      offset: offset,
      records: records,
      truncated: truncated,
    );
    while (records.length > 1 && encoded.length > _maxToolChars) {
      records = records.sublist(0, records.length - 1);
      truncated = true;
      encoded = _encodeRecords(
        snapshot: snapshot,
        total: nodes.length,
        offset: offset,
        records: records,
        truncated: truncated,
      );
    }
    return PluginToolResult(encoded);
  }

  Future<PageSnapshot> _storeFetched(
    String chatId,
    FetchedPage fetched, {
    required String mode,
    String? selector,
    required bool allowEmpty,
  }) async {
    if (!fetched.isHtml) {
      final document = PageDocument(
        requestedUrl: fetched.requestedUrl,
        finalUrl: fetched.finalUrl,
        title: _titleFromUrl(fetched.finalUrl),
        text: fetched.body,
        cleanedHtml: '',
        outline: const [],
        contentType: fetched.contentType,
        fetchedAt: fetched.fetchedAt,
      );
      return _pages.put(chatId: chatId, document: document, mode: mode);
    }
    final cleaned = _extractor.clean(fetched);
    try {
      final document = _extractor.render(
        cleaned,
        source: fetched,
        mode: mode,
        selector: selector,
      );
      return _pages.put(chatId: chatId, document: document, mode: mode);
    } on WebToolException {
      if (!allowEmpty) rethrow;
      final document = PageDocument(
        requestedUrl: fetched.requestedUrl,
        finalUrl: fetched.finalUrl,
        title: cleaned.title,
        text: '',
        cleanedHtml: cleaned.html,
        outline: const [],
        contentType: fetched.contentType,
        fetchedAt: fetched.fetchedAt,
      );
      return _pages.put(chatId: chatId, document: document, mode: mode);
    }
  }

  PageDocument _renderStored(
    PageSnapshot snapshot, {
    required String mode,
    String? selector,
  }) {
    if (snapshot.cleanedHtml.isEmpty) {
      return PageDocument(
        requestedUrl: snapshot.requestedUrl,
        finalUrl: snapshot.finalUrl,
        title: snapshot.title,
        text: snapshot.text,
        cleanedHtml: '',
        outline: snapshot.outline,
        contentType: snapshot.contentType,
        fetchedAt: snapshot.fetchedAt,
      );
    }
    return _extractor.renderStored(
      snapshot.cleanedHtml,
      requestedUrl: snapshot.requestedUrl,
      finalUrl: snapshot.finalUrl,
      title: snapshot.title,
      lang: snapshot.lang,
      published: snapshot.published,
      contentType: snapshot.contentType,
      fetchedAt: snapshot.fetchedAt,
      mode: mode,
      selector: selector,
    );
  }

  String _resolveTarget(
    String chatId, {
    required String url,
    required String ref,
  }) {
    if (url.isNotEmpty && ref.isNotEmpty) {
      throw const WebToolException(
        'bad_arguments',
        'pass either url or ref, not both',
      );
    }
    if (url.isNotEmpty) return url;
    if (ref.isNotEmpty) {
      final result = _sessions.resolve(chatId, ref);
      if (result == null) {
        throw const WebToolException(
          'unknown_ref',
          'search result reference is not available',
          hint: 'run web_search again or pass the URL',
        );
      }
      return result.url;
    }
    throw const WebToolException('bad_arguments', 'pass url, ref or page_id');
  }

  PluginToolResult _formatOpen(
    PageSnapshot snapshot, {
    required int maxChars,
    required int offset,
  }) {
    final text = snapshot.text;
    final start = _clampInt(offset, 0, text.length);
    final end = math.min(start + maxChars, text.length);
    final buffer = StringBuffer()
      ..writeln('page_id: ${snapshot.id}')
      ..writeln('url: ${snapshot.finalUrl}')
      ..writeln('title: ${snapshot.title}')
      ..writeln('content_type: ${snapshot.contentType}')
      ..writeln('fetched: ${snapshot.fetchedAt.toIso8601String()}')
      ..writeln('chars: ${text.length}')
      ..writeln('offset: $start');
    if (end < text.length) buffer.writeln('next_offset: $end');
    if (start == 0 && snapshot.outline.isNotEmpty) {
      buffer.writeln('outline:');
      for (final entry in snapshot.outline.take(30)) {
        buffer.writeln(
          '  ${'-' * entry.level} ${entry.title} @ ${entry.offset}',
        );
      }
    }
    buffer
      ..writeln()
      ..writeln('---')
      // ignore: avoid-substring, offsets are UTF-16 code units like String.length
      ..writeln(text.substring(start, end));
    return PluginToolResult(
      _clip(buffer.toString(), math.max(_maxToolChars, maxChars) + 4000),
    );
  }

  PluginToolResult _chunk(
    PageSnapshot snapshot,
    Map<String, dynamic> arguments,
  ) {
    final limit = _clampInt(
      _argInt(arguments, 'limit', fallback: 8000),
      100,
      20000,
    );
    final offset = _clampInt(
      _argInt(arguments, 'offset'),
      0,
      snapshot.text.length,
    );
    final end = math.min(offset + limit, snapshot.text.length);
    final buffer = StringBuffer()
      ..writeln('page_id: ${snapshot.id}')
      ..writeln('mode: chunk')
      ..writeln('chars: ${snapshot.text.length}')
      ..writeln('offset: $offset');
    if (end < snapshot.text.length) buffer.writeln('next_offset: $end');
    buffer
      ..writeln()
      ..writeln('---')
      // ignore: avoid-substring, offsets are UTF-16 code units like String.length
      ..writeln(snapshot.text.substring(offset, end));
    return PluginToolResult(_clip(buffer.toString(), _maxToolChars + 2000));
  }

  PluginToolResult _grep(
    PageSnapshot snapshot,
    Map<String, dynamic> arguments,
  ) {
    final pattern = _argString(arguments, 'pattern');
    if (pattern.isEmpty) {
      throw const WebToolException('bad_arguments', 'pattern is required');
    }
    if (pattern.length > 200) {
      throw const WebToolException(
        'bad_arguments',
        'pattern is too long',
        hint: 'keep the grep pattern under 200 characters',
      );
    }
    final context = _clampInt(_argInt(arguments, 'context'), 0, 5);
    final limit = _clampInt(_argInt(arguments, 'limit', fallback: 20), 1, 50);
    final ignoreCase = arguments['ignore_case'] != false;
    final regex = arguments['regex'] == true;
    RegExp? expression;
    if (regex) {
      try {
        expression = RegExp(pattern, caseSensitive: !ignoreCase);
      } on FormatException catch (error, stack) {
        Error.throwWithStackTrace(
          WebToolException(
            'bad_pattern',
            'invalid regular expression',
            hint: error.message,
          ),
          stack,
        );
      }
    }
    final lines = snapshot.text.split('\n');
    final offsets = <int>[];
    var position = 0;
    for (final line in lines) {
      offsets.add(position);
      position += line.length + 1;
    }
    final matches = <int>[];
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      final found = expression == null
          ? (ignoreCase
                ? line.toLowerCase().contains(pattern.toLowerCase())
                : line.contains(pattern))
          : expression.hasMatch(line);
      if (found) matches.add(index);
      if (matches.length > limit * 4) break;
    }
    if (matches.isEmpty) {
      return PluginToolResult(
        'page_id: ${snapshot.id}\nmode: grep\npattern: $pattern\nmatches: 0',
      );
    }
    final buffer = StringBuffer()
      ..writeln('page_id: ${snapshot.id}')
      ..writeln('mode: grep')
      ..writeln('pattern: $pattern')
      ..writeln('matches: ${matches.length}')
      ..writeln();
    final shown = matches.take(limit);
    for (final index in shown) {
      final first = math.max(0, index - context);
      final last = math.min(lines.length - 1, index + context);
      buffer.writeln('line ${index + 1} @ ${offsets[index]}: ${lines[index]}');
      for (var around = first; around <= last; around++) {
        if (around == index) continue;
        buffer.writeln(
          '  ${around + 1} @ ${offsets[around]}: ${lines[around]}',
        );
      }
      buffer.writeln();
    }
    return PluginToolResult(_clip(buffer.toString(), _maxToolChars));
  }

  PluginToolResult _outline(PageSnapshot snapshot) {
    final buffer = StringBuffer()
      ..writeln('page_id: ${snapshot.id}')
      ..writeln('mode: outline')
      ..writeln('chars: ${snapshot.text.length}');
    if (snapshot.outline.isEmpty) {
      buffer.writeln('\nNo headings were found.');
    } else {
      for (final entry in snapshot.outline.take(100)) {
        buffer.writeln(
          '${'  ' * (entry.level - 1)}${entry.title} @ ${entry.offset}',
        );
      }
    }
    return PluginToolResult(_clip(buffer.toString(), _maxToolChars));
  }

  Map<String, Object?> _recordOf(
    dom.Element node,
    Map<String, String> fields,
    String baseUrl,
  ) {
    final record = <String, Object?>{};
    for (final entry in fields.entries) {
      final spec = entry.value.trim();
      if (spec.isEmpty) {
        record[entry.key] = null;
        continue;
      }
      final attributeAt = spec.lastIndexOf('@');
      final hasAttribute = attributeAt > 0;
      final selector = hasAttribute
          ? spec.characters.take(attributeAt).toString().trim()
          : spec;
      final attribute = hasAttribute ? _attributeOf(spec, attributeAt) : '';
      final element = selector.isEmpty ? node : node.querySelector(selector);
      if (element == null) {
        record[entry.key] = null;
        continue;
      }
      if (attribute.isNotEmpty && attribute != 'text') {
        final value = element.attributes[attribute];
        record[entry.key] = value == null ? null : _absolute(value, baseUrl);
      } else {
        record[entry.key] = _clip(_normalize(element.text), 2000);
      }
    }
    return record;
  }

  static String _encodeRecords({
    required PageSnapshot snapshot,
    required int total,
    required int offset,
    required List<Map<String, Object?>> records,
    required bool truncated,
  }) => const JsonEncoder.withIndent('  ').convert({
    'url': snapshot.finalUrl,
    'count': total,
    'offset': offset,
    'returned': records.length,
    'truncated': truncated,
    'records': records,
  });

  static String _absolute(String value, String baseUrl) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.hasScheme) return value;
    return Uri.tryParse(baseUrl)?.resolveUri(uri).toString() ?? value;
  }

  static String _normalize(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _attributeOf(String spec, int at) =>
      spec.characters.skip(at + 1).toString().trim();

  static String _titleFromUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri?.host.isNotEmpty == true ? uri!.host : url;
  }

  static String _normalizeUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return value;
    final params = Map<String, String>.of(uri.queryParameters)
      ..removeWhere(
        (key, _) =>
            key.startsWith('utm_') ||
            key == 'gclid' ||
            key == 'fbclid' ||
            key == 'ref',
      );
    return uri
        .replace(queryParameters: params.isEmpty ? null : params, fragment: '')
        .toString();
  }

  static List<String> _argStrings(Object? value) => value is List
      ? [
          for (final item in value)
            if (item is String && item.trim().isNotEmpty) item.trim(),
        ]
      : const [];

  static String _argString(
    Map<String, dynamic> arguments,
    String name, {
    String fallback = '',
  }) {
    final value = arguments[name];
    return value is String ? value.trim() : fallback;
  }

  static int _argInt(
    Map<String, dynamic> arguments,
    String name, {
    int fallback = 0,
  }) {
    final value = arguments[name];
    if (value is num) return value.toInt();
    return int.tryParse('${value ?? ''}') ?? fallback;
  }

  static Map<String, String> _argFields(Object? value) {
    if (value is! Map) return const {};
    return {
      for (final entry in value.entries)
        if (entry.key is String && entry.value is String)
          '${entry.key}': '${entry.value}',
    };
  }

  static int _clampInt(int value, int min, int max) =>
      value < min ? min : (value > max ? max : value);

  static String _clip(String value, int max) {
    final chars = value.characters;
    if (chars.length <= max) return value;
    return '${chars.take(max)}…';
  }
}

const _searchSchema = <String, Object?>{
  'type': 'object',
  'properties': {
    'query': {'type': 'string', 'description': 'Search query'},
    'count': {
      'type': 'integer',
      'minimum': 1,
      'maximum': 10,
      'description': 'Number of results, default from settings',
    },
    'freshness': {
      'type': 'string',
      'enum': ['any', 'day', 'week', 'month', 'year'],
      'description': 'Restrict results by age',
    },
    'site': {
      'type': 'array',
      'items': {'type': 'string'},
      'description': 'Only these domains',
    },
  },
  'required': ['query'],
};

const _openSchema = <String, Object?>{
  'type': 'object',
  'properties': {
    'url': {'type': 'string', 'description': 'Page URL'},
    'ref': {
      'type': 'string',
      'description': 'Number from the latest web_search, e.g. "1"',
    },
    'page_id': {
      'type': 'string',
      'description': 'Re-render an already opened page',
    },
    'mode': {
      'type': 'string',
      'enum': ['article', 'main', 'full', 'selector', 'links', 'tables'],
      'description': 'What to extract from the page',
    },
    'selector': {
      'type': 'string',
      'description': 'CSS selector for mode=selector',
    },
    'max_chars': {
      'type': 'integer',
      'minimum': 1000,
      'maximum': 30000,
      'description': 'How many characters to return',
    },
    'offset': {
      'type': 'integer',
      'minimum': 0,
      'description': 'Continue from a previous next_offset',
    },
  },
};

const _readSchema = <String, Object?>{
  'type': 'object',
  'properties': {
    'page_id': {'type': 'string'},
    'mode': {
      'type': 'string',
      'enum': ['chunk', 'grep', 'outline'],
      'description':
          'chunk reads text, grep searches lines, outline lists headings',
    },
    'offset': {'type': 'integer', 'minimum': 0},
    'limit': {'type': 'integer', 'minimum': 1, 'maximum': 20000},
    'pattern': {'type': 'string', 'description': 'Grep pattern'},
    'context': {
      'type': 'integer',
      'minimum': 0,
      'maximum': 5,
      'description': 'Context lines around a grep match',
    },
    'ignore_case': {'type': 'boolean'},
    'regex': {'type': 'boolean'},
  },
  'required': ['page_id'],
};

const _extractSchema = <String, Object?>{
  'type': 'object',
  'properties': {
    'page_id': {'type': 'string'},
    'url': {'type': 'string'},
    'ref': {'type': 'string'},
    'container': {
      'type': 'string',
      'description': 'CSS selector of one record, e.g. ".product"',
    },
    'fields': {
      'type': 'object',
      'additionalProperties': {'type': 'string'},
      'description':
          'Field name to selector; use selector@href or selector@data-id '
          'for attributes',
    },
    'offset': {'type': 'integer', 'minimum': 0},
    'limit': {'type': 'integer', 'minimum': 1, 'maximum': 100},
  },
  'required': ['container', 'fields'],
};

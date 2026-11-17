import 'dart:convert';

import 'package:plugin_api/plugin_api.dart';
import 'package:plugin_web_core/plugin_web_core.dart';
import 'package:test/test.dart';

final class _Settings implements PluginSettings {
  _Settings(this.value);

  Map<String, Object?> value;
  var hasSearchKey = true;
  final secrets = <String, String>{};

  @override
  Future<Map<String, Object?>> read() async => value;

  @override
  Future<void> save(Map<String, Object?> value) async => this.value = value;

  @override
  Future<bool> hasSecret(String name) async => hasSearchKey;

  @override
  Future<void> writeSecret(String name, String? value) async {
    if (value == null) {
      secrets.remove(name);
      hasSearchKey = false;
    } else {
      secrets[name] = value;
      hasSearchKey = true;
    }
  }
}

final class _Host implements PluginHost {
  _Host(this.responses);

  final Map<String, PluginHttpResult> responses;
  final calls = <String>[];

  @override
  String get chatId => 'chat';

  @override
  String get cwd => '/tmp';

  @override
  Future<PluginCommandResult> runCommand(
    String executable,
    List<String> args, {
    Duration? timeout,
  }) => throw UnsupportedError('command is not used');

  @override
  Future<PluginHttpResult> httpRequest({
    required String method,
    required String url,
    Map<String, String> headers = const {},
    Object? body,
    Duration? timeout,
    bool followRedirects = true,
    bool allowLoopback = true,
    bool allowPrivateNetwork = true,
    int? maxBytes,
  }) async {
    calls.add(url);
    for (final entry in responses.entries) {
      if (url == entry.key || url.startsWith(entry.key)) return entry.value;
    }
    if (url.endsWith('/robots.txt')) {
      return const PluginHttpResult(statusCode: 404, body: 'not found');
    }
    return const PluginHttpResult(statusCode: 404, body: 'not found');
  }
}

PluginTool _tool(List<PluginTool> tools, String name) =>
    tools.firstWhere((tool) => tool.name == name);

String _pageId(String text) =>
    RegExp(r'page_id: (p_\S+)').firstMatch(text)!.group(1)!;

const _page = '''
<html lang="ru">
<head>
  <title>Test page</title>
  <meta property="article:published_time" content="2026-01-02T10:00:00Z">
</head>
<body>
  <nav>menu</nav>
  <article>
    <h1>Заголовок</h1>
    <p>Привет <strong>мир</strong>.</p>
    <h2>Тарифы</h2>
    <div class="plan"><span class="name">Basic</span><span class="price">5 €</span><a href="/buy">Купить</a></div>
    <div class="plan"><span class="name">Pro</span><span class="price">10 €</span><a href="/buy-pro">Купить</a></div>
    <table>
      <tr><th>План</th><th>Цена</th></tr>
      <tr><td>Basic</td><td>5</td></tr>
    </table>
    <a href="/more">Ещё</a>
    <script>bad()</script>
  </article>
  <footer>footer</footer>
</body>
</html>
''';

PluginHttpResult _html(String body) => PluginHttpResult(
  statusCode: 200,
  body: body,
  headers: const {'content-type': 'text/html; charset=utf-8'},
  contentType: 'text/html; charset=utf-8',
);

void main() {
  test('config parses defaults and domain policy', () {
    final config = WebConfig.fromJson(const {});
    expect(config.search.provider, WebSearchProvider.brave);
    expect(config.fetch.maxChars, 12000);
    expect(config.fetch.respectRobots, isTrue);
    expect(config.domains.allows('example.com'), isTrue);

    final policy = WebDomainPolicy(
      allow: const ['example.com'],
      deny: const ['ads.example.com'],
    );
    expect(policy.allows('docs.example.com'), isTrue);
    expect(policy.allows('ads.example.com'), isFalse);
    expect(policy.allows('other.com'), isFalse);
  });

  test('search, open, read, grep, outline and extract work together', () async {
    final host = _Host({
      'https://api.search.brave.com/res/v1/web/search': PluginHttpResult(
        statusCode: 200,
        contentType: 'application/json',
        body: jsonEncode({
          'web': {
            'results': [
              {
                'title': 'Test page',
                'url': 'https://example.com/page',
                'description': 'A page about plans',
                'page_age': '2026-01-02',
              },
            ],
          },
        }),
      ),
      'https://example.com/page': _html(_page),
    });
    final settings = _Settings({
      'version': 1,
      'search': {'provider': 'brave', 'maxResults': 5},
    });
    final tools = await WebPlugin().createTools(settings);

    final search = await _tool(tools, 'search').run({'query': 'plans'}, host);
    expect(search.isError, isFalse);
    expect(search.text, contains('[1] Test page'));
    expect(search.text, contains('https://example.com/page'));

    final opened = await _tool(tools, 'open').run({'ref': '1'}, host);
    expect(opened.isError, isFalse, reason: opened.text);
    expect(opened.text, contains('page_id:'));
    expect(opened.text, contains('# Заголовок'));
    expect(opened.text, isNot(contains('menu')));
    expect(opened.text, isNot(contains('bad()')));
    final pageId = _pageId(opened.text);

    final chunk = await _tool(
      tools,
      'read',
    ).run({'page_id': pageId, 'mode': 'chunk', 'limit': 100}, host);
    expect(chunk.isError, isFalse);
    expect(chunk.text, contains('next_offset:'));

    final grep = await _tool(
      tools,
      'read',
    ).run({'page_id': pageId, 'mode': 'grep', 'pattern': 'Привет'}, host);
    expect(grep.isError, isFalse);
    expect(grep.text, contains('Привет'));
    expect(grep.text, contains('matches: 1'));

    final outline = await _tool(
      tools,
      'read',
    ).run({'page_id': pageId, 'mode': 'outline'}, host);
    expect(outline.isError, isFalse);
    expect(outline.text, contains('Тарифы'));

    final records = await _tool(tools, 'extract').run({
      'page_id': pageId,
      'container': '.plan',
      'fields': {'name': '.name', 'price': '.price', 'link': 'a@href'},
    }, host);
    expect(records.isError, isFalse, reason: records.text);
    final json = jsonDecode(records.text) as Map<String, dynamic>;
    expect(json['count'], 2);
    final list = json['records'] as List<dynamic>;
    expect(list.first['name'], 'Basic');
    expect(list.first['link'], 'https://example.com/buy');
  });

  test('search result refs are scoped to a chat', () async {
    final host = _Host({
      'https://api.search.brave.com/res/v1/web/search': PluginHttpResult(
        statusCode: 200,
        contentType: 'application/json',
        body: jsonEncode({
          'web': {
            'results': [
              {'title': 'One', 'url': 'https://example.com/one'},
            ],
          },
        }),
      ),
    });
    final settings = _Settings({
      'search': {'provider': 'brave'},
    });
    final tools = await WebPlugin().createTools(settings);
    await _tool(tools, 'search').run({'query': 'one'}, host);
    final result = await _tool(tools, 'open').run({'ref': '2'}, host);
    expect(result.isError, isTrue);
    expect(result.text, contains('unknown_ref'));
  });

  test('missing search key hides the search tool', () async {
    final settings = _Settings({})..hasSearchKey = false;
    final tools = await WebPlugin().createTools(settings);
    expect(tools.map((tool) => tool.name), isNot(contains('search')));
    expect(tools.map((tool) => tool.name), contains('open'));
  });

  test('non-html pages open as text and cannot be extracted', () async {
    final host = _Host({
      'https://example.com/data.json': const PluginHttpResult(
        statusCode: 200,
        body: '{"ok":true}',
        contentType: 'application/json',
      ),
    });
    final settings = _Settings({});
    final tools = await WebPlugin().createTools(settings);
    final opened = await _tool(
      tools,
      'open',
    ).run({'url': 'https://example.com/data.json'}, host);
    expect(opened.isError, isFalse, reason: opened.text);
    expect(opened.text, contains('{"ok":true}'));
    final pageId = _pageId(opened.text);
    final extracted = await _tool(tools, 'extract').run({
      'page_id': pageId,
      'container': '.x',
      'fields': {'a': '.a'},
    }, host);
    expect(extracted.isError, isTrue);
    expect(extracted.text, contains('not_html'));
  });

  test('page store expires snapshots and enforces per-chat limit', () {
    var now = DateTime(2026, 1, 1);
    final store = WebPageStore(
      now: () => now,
      maxPagesPerChat: 2,
      ttl: const Duration(minutes: 10),
    );
    PageDocument document(int index) => PageDocument(
      requestedUrl: 'https://example.com/$index',
      finalUrl: 'https://example.com/$index',
      title: 'Page $index',
      text: 'text $index',
      cleanedHtml: '',
      outline: const [],
      fetchedAt: now,
    );
    final first = store.put(
      chatId: 'chat',
      document: document(1),
      mode: 'article',
    );
    final second = store.put(
      chatId: 'chat',
      document: document(2),
      mode: 'article',
    );
    final third = store.put(
      chatId: 'chat',
      document: document(3),
      mode: 'article',
    );
    expect(store.length, 2);
    expect(store.get('chat', first.id), isNull);
    expect(store.get('chat', second.id), isNotNull);
    now = now.add(const Duration(minutes: 11));
    expect(store.get('chat', third.id), isNull);
  });

  test('Tavily results are normalized', () async {
    final host = _Host({
      'https://api.tavily.com/search': PluginHttpResult(
        statusCode: 200,
        contentType: 'application/json',
        body: jsonEncode({
          'results': [
            {
              'title': 'Tavily page',
              'url': 'https://example.com/t',
              'content': 'Tavily snippet',
              'published_date': '2026-02-03',
            },
          ],
        }),
      ),
    });
    final settings = _Settings({
      'search': {'provider': 'tavily'},
    });
    final tools = await WebPlugin().createTools(settings);
    final result = await _tool(tools, 'search').run({'query': 'hello'}, host);
    expect(result.isError, isFalse, reason: result.text);
    expect(result.text, contains('Tavily page'));
    expect(result.text, contains('Tavily snippet'));
  });

  test('SearXNG works without a key', () async {
    final host = _Host({
      'https://searx.example/search': PluginHttpResult(
        statusCode: 200,
        contentType: 'application/json',
        body: jsonEncode({
          'results': [
            {
              'title': 'SearXNG page',
              'url': 'https://example.com/s',
              'content': 'SearXNG snippet',
            },
          ],
        }),
      ),
    });
    final settings = _Settings({
      'search': {'provider': 'searxng', 'endpoint': 'https://searx.example'},
    })..hasSearchKey = false;
    final tools = await WebPlugin().createTools(settings);
    expect(tools.map((tool) => tool.name), contains('search'));
    final result = await _tool(tools, 'search').run({'query': 'hello'}, host);
    expect(result.isError, isFalse, reason: result.text);
    expect(result.text, contains('SearXNG page'));
    expect(host.calls.first, contains('/search?'));
  });

  test('robots.txt disallow blocks the page', () async {
    final host = _Host({
      'https://example.com/robots.txt': const PluginHttpResult(
        statusCode: 200,
        body: 'User-agent: *\nDisallow: /private',
        contentType: 'text/plain',
      ),
      'https://example.com/private': _html('<p>secret</p>'),
    });
    final tools = await WebPlugin().createTools(_Settings({}));
    final result = await _tool(
      tools,
      'open',
    ).run({'url': 'https://example.com/private'}, host);
    expect(result.isError, isTrue);
    expect(result.text, contains('robots_disallowed'));
  });

  test('redirects are followed and validated one by one', () async {
    final host = _Host({
      'https://example.com/old': const PluginHttpResult(
        statusCode: 301,
        body: '',
        headers: {'location': '/new'},
        isError: true,
      ),
      'https://example.com/new': _html('<article><h1>New</h1></article>'),
    });
    final tools = await WebPlugin().createTools(_Settings({}));
    final result = await _tool(
      tools,
      'open',
    ).run({'url': 'https://example.com/old'}, host);
    expect(result.isError, isFalse, reason: result.text);
    expect(result.text, contains('url: https://example.com/new'));
    expect(result.text, contains('# New'));
  });

  test('meta charset is used when the header has none', () async {
    const html =
        '<html><head><meta charset="utf-8"><title>Т</title></head>'
        '<body><article><p>Привет</p></article></body></html>';
    final host = _Host({
      'https://example.com/utf8': PluginHttpResult(
        statusCode: 200,
        body: '',
        bodyBytes: utf8.encode(html),
        contentType: 'text/html',
      ),
    });
    final tools = await WebPlugin().createTools(_Settings({}));
    final result = await _tool(
      tools,
      'open',
    ).run({'url': 'https://example.com/utf8'}, host);
    expect(result.isError, isFalse, reason: result.text);
    expect(result.text, contains('Привет'));
  });

  test('open can render a stored page in another mode', () async {
    final host = _Host({'https://example.com/page': _html(_page)});
    final tools = await WebPlugin().createTools(_Settings({}));
    final opened = await _tool(
      tools,
      'open',
    ).run({'url': 'https://example.com/page'}, host);
    final pageId = _pageId(opened.text);
    final tables = await _tool(
      tools,
      'open',
    ).run({'page_id': pageId, 'mode': 'tables'}, host);
    expect(tables.isError, isFalse, reason: tables.text);
    expect(tables.text, contains('| План | Цена |'));
    expect(tables.text, contains('| Basic | 5 |'));
  });

  test('empty page with scripts reports page_requires_javascript', () async {
    final host = _Host({
      'https://example.com/app': _html(
        '<html><body><div id="app"></div><script>start()</script></body></html>',
      ),
    });
    final tools = await WebPlugin().createTools(_Settings({}));
    final result = await _tool(
      tools,
      'open',
    ).run({'url': 'https://example.com/app'}, host);
    expect(result.isError, isTrue);
    expect(result.text, contains('page_requires_javascript'));
  });
}

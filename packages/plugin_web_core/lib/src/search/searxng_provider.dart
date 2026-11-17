import 'package:plugin_api/plugin_api.dart';
import 'package:plugin_web_core/src/search/provider_http.dart';
import 'package:plugin_web_core/src/search/search_provider.dart';
import 'package:plugin_web_core/src/search/search_result.dart';
import 'package:plugin_web_core/src/web_config.dart';
import 'package:plugin_web_core/src/web_error.dart';

/// Поиск через self-hosted SearXNG.
///
/// Провайдер не требует ключа, но требует адрес инстанса с включённым JSON API
/// (`search.formats` должен содержать `json`).
final class SearxngSearchProvider implements SearchProvider {
  const SearxngSearchProvider();

  @override
  Future<List<SearchResult>> search({
    required SearchQuery query,
    required WebConfig config,
    required PluginHost host,
  }) async {
    final endpoint = Uri.tryParse(config.search.effectiveEndpoint);
    if (endpoint == null || !endpoint.hasScheme) {
      throw const WebToolException(
        'search_not_configured',
        'SearXNG endpoint is not configured',
        hint: 'set the URL of a SearXNG instance with JSON output enabled',
      );
    }
    final basePath = endpoint.path.endsWith('/')
        ? endpoint.path
        : '${endpoint.path}/';
    final uri = endpoint.replace(
      path: '${basePath}search',
      queryParameters: {
        'q': _queryWithSites(query),
        'format': 'json',
        'safesearch': config.search.safeSearch ? '1' : '0',
        if (config.search.language.isNotEmpty)
          'language': config.search.language,
        'time_range': ?_timeRange(query.freshness),
      },
    );
    final response = await host.httpRequest(
      method: 'GET',
      url: uri.toString(),
      headers: {'accept': 'application/json'},
      timeout: config.fetch.timeout,
      followRedirects: false,
      allowLoopback: true,
      allowPrivateNetwork: true,
      maxBytes: 512 * 1024,
    );
    final json = decodeProviderJson(response);
    return [
      for (final item in providerList(json['results']))
        if (!_isBlank(item))
          SearchResult(
            title: providerString(item['title']),
            url: providerString(item['url']),
            snippet: providerString(item['content']),
            published: providerString(item['publishedDate']),
          ),
    ];
  }

  static String _queryWithSites(SearchQuery query) {
    if (query.sites.isEmpty) return query.text;
    final sites = query.sites
        .map((site) => site.trim())
        .where((site) => site.isNotEmpty)
        .map((site) => 'site:$site')
        .join(' ');
    return '${query.text} $sites'.trim();
  }

  static String? _timeRange(String value) => switch (value) {
    'day' || 'week' || 'month' || 'year' => value,
    _ => null,
  };

  static bool _isBlank(Map<String, dynamic> item) =>
      providerString(item['url']).isEmpty ||
      providerString(item['title']).isEmpty;
}

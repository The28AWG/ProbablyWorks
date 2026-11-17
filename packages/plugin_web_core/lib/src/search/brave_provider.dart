import 'package:plugin_api/plugin_api.dart';
import 'package:plugin_web_core/src/search/provider_http.dart';
import 'package:plugin_web_core/src/search/search_provider.dart';
import 'package:plugin_web_core/src/search/search_result.dart';
import 'package:plugin_web_core/src/web_config.dart';
import 'package:plugin_web_core/src/web_error.dart';
import 'package:plugin_web_core/src/web_secrets.dart';

/// Поиск через Brave Search API.
///
/// Документация: https://api.search.brave.com/app/documentation/web-search
final class BraveSearchProvider implements SearchProvider {
  const BraveSearchProvider();

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
        'Brave endpoint is not configured',
      );
    }
    final params = <String, String>{
      'q': _queryWithSites(query),
      'count': '${query.count}',
      'safesearch': config.search.safeSearch ? 'strict' : 'off',
      'text_decorations': 'false',
    };
    final freshness = _freshness(query.freshness);
    if (freshness != null) params['freshness'] = freshness;
    final uri = endpoint.replace(
      queryParameters: {...endpoint.queryParameters, ...params},
    );
    final response = await host.httpRequest(
      method: 'GET',
      url: uri.toString(),
      headers: {
        'accept': 'application/json',
        'x-subscription-token': WebSecrets.searchKeyRef,
      },
      timeout: config.fetch.timeout,
      followRedirects: false,
      allowLoopback: false,
      allowPrivateNetwork: false,
      maxBytes: 512 * 1024,
    );
    final json = decodeProviderJson(response);
    final web = json['web'];
    final results = web is Map ? providerList(web['results']) : const [];
    return [
      for (final item in results)
        if (!_isBlank(item))
          SearchResult(
            title: providerString(item['title']),
            url: providerString(item['url']),
            snippet: providerString(item['description']),
            published: providerString(item['page_age'] ?? item['age']),
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

  static String? _freshness(String value) => switch (value) {
    'day' => 'pd',
    'week' => 'pw',
    'month' => 'pm',
    'year' => 'py',
    _ => null,
  };

  static bool _isBlank(Map<String, dynamic> item) =>
      providerString(item['url']).isEmpty ||
      providerString(item['title']).isEmpty;
}

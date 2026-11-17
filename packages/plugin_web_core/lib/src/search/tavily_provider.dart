import 'package:plugin_api/plugin_api.dart';
import 'package:plugin_web_core/src/search/provider_http.dart';
import 'package:plugin_web_core/src/search/search_provider.dart';
import 'package:plugin_web_core/src/search/search_result.dart';
import 'package:plugin_web_core/src/web_config.dart';
import 'package:plugin_web_core/src/web_secrets.dart';

/// Поиск через Tavily Search API.
final class TavilySearchProvider implements SearchProvider {
  const TavilySearchProvider();

  @override
  Future<List<SearchResult>> search({
    required SearchQuery query,
    required WebConfig config,
    required PluginHost host,
  }) async {
    final endpoint = config.search.effectiveEndpoint;
    final days = _days(query.freshness);
    final response = await host.httpRequest(
      method: 'POST',
      url: endpoint,
      headers: {
        'accept': 'application/json',
        'authorization': 'Bearer ${WebSecrets.searchKeyRef}',
        'content-type': 'application/json',
      },
      body: {
        'query': query.text,
        'max_results': query.count,
        'search_depth': 'basic',
        'include_answer': false,
        'include_raw_content': false,
        'topic': 'general',
        if (query.sites.isNotEmpty) 'include_domains': query.sites,
        'days': ?days,
      },
      timeout: config.fetch.timeout,
      followRedirects: false,
      allowLoopback: false,
      allowPrivateNetwork: false,
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
            published: providerString(item['published_date']),
          ),
    ];
  }

  static int? _days(String value) => switch (value) {
    'day' => 1,
    'week' => 7,
    'month' => 30,
    'year' => 365,
    _ => null,
  };

  static bool _isBlank(Map<String, dynamic> item) =>
      providerString(item['url']).isEmpty ||
      providerString(item['title']).isEmpty;
}

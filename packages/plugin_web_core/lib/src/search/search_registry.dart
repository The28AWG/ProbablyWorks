import 'package:plugin_web_core/src/search/brave_provider.dart';
import 'package:plugin_web_core/src/search/search_provider.dart';
import 'package:plugin_web_core/src/search/searxng_provider.dart';
import 'package:plugin_web_core/src/search/tavily_provider.dart';
import 'package:plugin_web_core/src/web_config.dart';

/// Выбирает адаптер по настройкам плагина.
abstract final class SearchRegistry {
  const SearchRegistry._();

  static SearchProvider providerFor(WebSearchProvider provider) =>
      switch (provider) {
        WebSearchProvider.brave => const BraveSearchProvider(),
        WebSearchProvider.tavily => const TavilySearchProvider(),
        WebSearchProvider.searxng => const SearxngSearchProvider(),
      };
}

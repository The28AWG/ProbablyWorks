import 'package:plugin_api/plugin_api.dart';
import 'package:plugin_web_core/src/search/search_result.dart';
import 'package:plugin_web_core/src/web_config.dart';

/// Провайдер поиска. Каждый адаптер приводит ответ API к [SearchResult].
abstract interface class SearchProvider {
  /// Выполняет запрос через [PluginHost], чтобы приложение проверило URL и
  /// подставило секрет.
  Future<List<SearchResult>> search({
    required SearchQuery query,
    required WebConfig config,
    required PluginHost host,
  });
}

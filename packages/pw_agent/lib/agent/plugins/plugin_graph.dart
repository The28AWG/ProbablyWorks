import 'package:plugin_api/plugin_api.dart';

/// Граф зависимостей плагинов. Работает только с id, без UI и локализации.
final class PluginGraph {
  PluginGraph(Iterable<Plugin> plugins)
    : _plugins = {for (final plugin in plugins) plugin.id: plugin};

  final Map<String, Plugin> _plugins;

  /// Все недостающие зависимости [id], включая транзитивные.
  Set<String> missingDependencies(String id, Set<String> enabled) {
    final missing = <String>{};
    final queue = [..._plugins[id]?.dependsOn ?? const <String>{}];
    while (queue.isNotEmpty) {
      final dependency = queue.removeLast();
      if (enabled.contains(dependency) || missing.contains(dependency)) {
        continue;
      }
      final plugin = _plugins[dependency];
      if (plugin == null) continue;
      missing.add(dependency);
      queue.addAll(plugin.dependsOn);
    }
    return missing;
  }

  /// Включённые плагины, которые зависят от [id] прямо или транзитивно.
  Set<String> dependents(String id, Set<String> enabled) {
    final result = <String>{};
    var changed = true;
    while (changed) {
      changed = false;
      for (final plugin in _plugins.values) {
        if (plugin.id == id || result.contains(plugin.id)) continue;
        if (!enabled.contains(plugin.id)) continue;
        if (plugin.dependsOn.contains(id) ||
            plugin.dependsOn.any(result.contains)) {
          result.add(plugin.id);
          changed = true;
        }
      }
    }
    return result;
  }
}

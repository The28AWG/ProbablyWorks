import 'package:plugin_api/plugin_api.dart';

/// Скомпилированные в приложение плагины.
///
/// Агент не знает конкретные плагины: список передаёт клиент или демон.
/// Это позволяет держать `pw_agent` без зависимости от Flutter.
class PluginRegistry {
  const PluginRegistry(this.plugins);

  final List<Plugin> plugins;
}

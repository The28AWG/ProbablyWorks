import 'package:plugin_api/plugin_api.dart';

/// Скомпилированные в приложение плагины, которые добавляют команды в палитру.
///
/// Отдельно от [PluginRegistry]: инструменты и UI-команды — разные расширения.
class CommandPluginRegistry {
  const CommandPluginRegistry(this.plugins);

  final List<CommandPlugin> plugins;
}

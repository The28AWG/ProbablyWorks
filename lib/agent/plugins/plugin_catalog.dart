import 'package:injectable/injectable.dart';
import 'package:plugin_api/plugin_api.dart';
import 'package:plugin_declarative_commands/declarative_commands_plugin.dart';
import 'package:plugin_declarative_http/declarative_http_plugin.dart';

/// Скомпилированные в приложение плагины.
///
/// Список статический: пользователь не устанавливает код, а только включает
/// или выключает уже собранные возможности.
@lazySingleton
class PluginCatalog {
  const PluginCatalog();

  List<Plugin> get plugins => const [
    DeclarativeCommandsPlugin(),
    DeclarativeHttpPlugin(),
  ];
}

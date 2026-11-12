import 'package:flutter/widgets.dart';
import 'package:plugin_api/plugin_api.dart';

/// UI-часть встроенного плагина: локализация и экран настроек.
///
/// Это не плагин и не влияет на включение инструментов: представление
/// привязано к [pluginId] и нужно только для карточки в настройках.
abstract interface class PluginUi {
  /// Идентификатор ядра плагина, к которому относится это представление.
  String get pluginId;

  /// Делегат локализации плагина. Регистрируется на уровне приложения.
  LocalizationsDelegate<dynamic> get localizations;

  /// Локализованные название и описание для карточки в настройках.
  String titleOf(BuildContext context);
  String descriptionOf(BuildContext context);

  /// Экран настроек плагина. Null — у плагина нет собственных настроек.
  Widget? buildSettings(BuildContext context, PluginSettings settings);
}

/// Представления плагинов, скомпилированные в клиент.
class PluginUiRegistry {
  const PluginUiRegistry(this.items);

  final List<PluginUi> items;

  PluginUi? byId(String pluginId) =>
      items.where((ui) => ui.pluginId == pluginId).firstOrNull;
}

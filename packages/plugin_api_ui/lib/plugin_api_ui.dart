import 'package:flutter/widgets.dart';
import 'package:plugin_api/plugin_api.dart';

/// UI-часть встроенного плагина: локализация и экран настроек.
///
/// Отделена от [Plugin], чтобы `pw_agent` и демон не зависели от Flutter.
abstract interface class PluginUi implements Plugin {
  /// Делегат локализации плагина. Регистрируется на уровне приложения.
  LocalizationsDelegate<dynamic> get localizations;

  /// Локализованные название и описание для карточки в настройках.
  String titleOf(BuildContext context);
  String descriptionOf(BuildContext context);

  /// Экран настроек плагина. Null — у плагина нет собственных настроек.
  Widget? buildSettings(BuildContext context, PluginSettings settings);
}

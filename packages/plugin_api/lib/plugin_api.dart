import 'package:flutter/widgets.dart';

/// Встроенный плагин: набор инструментов и необязательного экрана настроек.
///
/// Плагины компилируются в приложение и включаются пользователем. Плагин не
/// загружает код в рантайме; он только добавляет возможности, когда включён.
abstract interface class Plugin {
  /// Стабильный идентификатор. На него завязаны флаги и зависимости.
  String get id;

  /// Плагины, которые должны быть включены вместе с этим.
  Set<String> get dependsOn;

  /// Включён ли плагин по умолчанию.
  bool get defaultEnabled;

  /// Делегат локализации плагина. Регистрируется на уровне приложения.
  LocalizationsDelegate<dynamic> get localizations;

  /// Локализованные название и описание для карточки в настройках.
  String titleOf(BuildContext context);
  String descriptionOf(BuildContext context);

  /// Инструменты для текущих настроек плагина.
  Future<List<PluginTool>> createTools(PluginSettings settings);

  /// Экран настроек плагина. Null — у плагина нет собственных настроек.
  Widget? buildSettings(BuildContext context, PluginSettings settings);
}

/// Инструмент, который плагин отдаёт модели.
final class PluginTool {
  const PluginTool({
    required this.name,
    required this.title,
    required this.description,
    required this.inputSchema,
    required this.run,
    this.mutatesHost = true,
  });

  /// Имя внутри плагина; полное имя добавит приложение.
  final String name;
  final String title;
  final String description;
  final Map<String, Object?> inputSchema;

  /// Выполняет вызов после policy и подтверждения.
  final Future<PluginToolResult> Function(
    Map<String, dynamic> arguments,
    PluginHost host,
  )
  run;

  /// Может ли инструмент менять Host. Если да, ход нельзя откатить.
  final bool mutatesHost;
}

/// Результат инструмента плагина.
final class PluginToolResult {
  const PluginToolResult(this.text, {this.isError = false});

  final String text;
  final bool isError;
}

/// Доступ плагина к Host. Политика уже разрешила вызов инструмента.
abstract interface class PluginHost {
  String get chatId;
  String get cwd;

  /// Запускает команду без shell-интерполяции: [executable] и [args] передаются
  /// как отдельные аргументы. Плагин не может подменить executable аргументом модели.
  Future<PluginCommandResult> runCommand(
    String executable,
    List<String> args, {
    Duration? timeout,
  });

  /// Выполняет HTTP-запрос после проверки URL и подстановки секретов
  /// приложением. Плагин не получает прямой доступ к сети.
  Future<PluginHttpResult> httpRequest({
    required String method,
    required String url,
    Map<String, String> headers = const {},
    Object? body,
    Duration? timeout,
  });
}

/// Ответ HTTP-запроса плагина.
final class PluginHttpResult {
  const PluginHttpResult({
    required this.statusCode,
    required this.body,
    this.headers = const {},
    this.isError = false,
  });

  final int statusCode;
  final String body;
  final Map<String, String> headers;
  final bool isError;
}

/// Итог команды плагина.
final class PluginCommandResult {
  const PluginCommandResult({
    required this.output,
    this.exitCode,
    this.isError = false,
  });

  final String output;
  final int? exitCode;
  final bool isError;
}

/// Настройки плагина. Сохранение сразу пересобирает инструменты.
abstract interface class PluginSettings {
  Future<Map<String, Object?>> read();
  Future<void> save(Map<String, Object?> value);
}

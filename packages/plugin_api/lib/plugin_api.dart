/// Встроенный плагин: набор инструментов, который компилируется в приложение.
///
/// Интерфейс не зависит от Flutter: агент и headless-демон используют только
/// инструменты. Экран настроек и локализация живут в `plugin_api_ui`.
abstract interface class Plugin {
  /// Стабильный идентификатор. На него завязаны флаги и зависимости.
  String get id;

  /// Плагины, которые должны быть включены вместе с этим.
  Set<String> get dependsOn;

  /// Включён ли плагин по умолчанию.
  bool get defaultEnabled;

  /// Инструменты для текущих настроек плагина.
  Future<List<PluginTool>> createTools(PluginSettings settings);
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

/// Команда, которую плагин добавляет в общую палитру приложения.
///
/// [titles] и [keywords] — карты «код языка → текст». Плагин не зависит от
/// Flutter: выполнение получает только [PluginCommandHost].
final class PluginCommand {
  const PluginCommand({
    required this.id,
    required this.titles,
    this.parentId,
    this.keywords = const {},
    this.requiresBackend = true,
    required this.run,
  });

  /// Идентификатор внутри плагина. Приложение добавит namespace плагина.
  final String id;

  /// Родительская команда внутри того же плагина. Null — верхний уровень.
  final String? parentId;
  final Map<String, String> titles;
  final Map<String, String> keywords;

  /// Команда работает без живого сервера агента. По умолчанию false:
  /// плагин должен явно разрешить offline-выполнение.
  final bool requiresBackend;
  final Future<void> Function(PluginCommandHost host) run;
}

/// Ограниченный доступ команды плагина к приложению.
abstract interface class PluginCommandHost {
  Future<void> openChat(String chatId);
  Future<void> newChat();

  /// Открывает настройки. [category] — необязательная группа, например
  /// `safety`, `plugins`, `mcp` или `advanced`.
  Future<void> openSettings({String? category});
  void notify(String message);
}

/// Дополнительный интерфейс плагина: команды палитры.
///
/// Отдельный интерфейс, чтобы существующие [Plugin] с инструментами не
/// ломались при добавлении палитры.
abstract interface class CommandPlugin {
  String get id;

  /// Название группы плагина в дереве команд.
  Map<String, String> get titles;

  Future<List<PluginCommand>> createCommands(PluginSettings settings);
}

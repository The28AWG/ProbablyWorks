import 'dart:typed_data';

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
  ///
  /// [followRedirects] выключают, если плагин сам проверяет каждый редирект.
  /// [allowLoopback] и [allowPrivateNetwork] по умолчанию сохраняют прежнее
  /// поведение; веб-плагин выключает их, чтобы не ходить во внутреннюю сеть.
  /// [maxBytes] ограничивает тело ответа: лишние байты не читаются, а в
  /// результате выставляется [PluginHttpResult.truncated].
  Future<PluginHttpResult> httpRequest({
    required String method,
    required String url,
    Map<String, String> headers = const {},
    Object? body,
    Duration? timeout,
    bool followRedirects = true,
    bool allowLoopback = true,
    bool allowPrivateNetwork = true,
    int? maxBytes,
  });

  /// Открывает файл для чтения кусками. Относительный [path] считается от [cwd].
  ///
  /// Курсор отдаёт содержимое без служебного формата `read_file` — заголовка,
  /// номеров строк и подвала — и умеет дочитывать файл циклом через
  /// [PluginFileReader.next]. Первый кусок уже прочитан к моменту возврата.
  /// Чувствительные пути и чтение вне workspace требуют подтверждения; оно
  /// спрашивается один раз при открытии.
  Future<PluginFileReader> readFile(String path);

  /// Читает файл целиком за один вызов.
  ///
  /// Возвращает исходное содержимое, а не формат `read_file`: содержимое,
  /// прочитанное после [writeFile], совпадает с записанным. Текст проходит
  /// штатное маскирование секретов, как любой вывод инструмента.
  Future<PluginFileResult> readAll(String path);

  /// Записывает файл: плагин передаёт путь и содержимое, а применяет приложение
  /// обычным путём — policy, подтверждение пользователя, changeset для отката.
  ///
  /// Плагин не получает прямого доступа к файловой системе и не может обойти
  /// политику исполнения. Относительный [path] считается от [cwd].
  Future<PluginFileResult> writeFile(String path, String content);
}

/// Курсор чтения файла плагином.
///
/// Собирает исходный текст из кусков вывода `read_file`: убирает заголовок,
/// номера строк и подвал, склеивает разрезанные строки. Конкатенация всех
/// кусков даёт файл целиком — разделители строк курсор добавляет сам.
abstract interface class PluginFileReader {
  /// Содержимое, прочитанное на текущий момент. После [next] дополняется.
  /// При ошибке содержит её причину, а [isError] равен true.
  String get text;

  /// Файл прочитан до конца или чтение прервано ошибкой.
  bool get done;

  /// Чтение завершилось ошибкой (нет файла, бинарный файл, нет прав,
  /// непонятный формат вывода Host).
  bool get isError;

  /// Дочитывает следующий кусок и дополняет [text]. После [done] ничего
  /// не меняет.
  Future<void> next();
}

/// Ответ HTTP-запроса плагина.
final class PluginHttpResult {
  const PluginHttpResult({
    required this.statusCode,
    required this.body,
    this.headers = const {},
    this.isError = false,
    this.bodyBytes,
    this.finalUrl,
    this.contentType,
    this.truncated = false,
  });

  final int statusCode;

  /// Тело, декодированное по charset из `Content-Type`.
  final String body;

  final Map<String, String> headers;
  final bool isError;

  /// Сырые байты: нужны для корректной кодировки страниц без charset.
  final Uint8List? bodyBytes;

  /// URL после редиректов, если клиент их выполнял.
  final String? finalUrl;

  /// Значение `Content-Type` из заголовков.
  final String? contentType;

  /// Тело было обрезано по [PluginHost.httpRequest] `maxBytes`.
  final bool truncated;
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

/// Результат файловой операции плагина: чтения или применённой записи.
final class PluginFileResult {
  const PluginFileResult(this.text, {this.isError = false});

  /// Текст для плагина. У чтения — содержимое файла как есть; у записи —
  /// подтверждение или причина отказа.
  final String text;
  final bool isError;
}

/// Настройки плагина. Сохранение сразу пересобирает инструменты.
///
/// Секреты не входят в JSON настроек: [hasSecret] и [writeSecret] работают с
/// защищённым хранилищем и не позволяют прочитать значение обратно.
abstract interface class PluginSettings {
  Future<Map<String, Object?>> read();
  Future<void> save(Map<String, Object?> value);

  /// Есть ли секрет плагина с именем [name].
  Future<bool> hasSecret(String name);

  /// Записывает секрет или удаляет его, если [value] равен null.
  Future<void> writeSecret(String name, String? value);
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

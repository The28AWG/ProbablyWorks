import 'dart:convert';

/// Транспорт MCP-сервера.
enum McpTransport {
  /// Локальный процесс: команда и аргументы, обмен по stdin/stdout.
  stdio,

  /// Удалённый Streamable HTTP endpoint.
  http,
}

/// Откуда взялась запись MCP-сервера.
enum McpServerSource {
  /// Управляется `mcp.json`; в интерфейсе доступны только действия подключения.
  file,

  /// Добавлен пользователем через настройки.
  user,
}

/// Конфигурация одного MCP-сервера.
///
/// Секреты здесь не хранятся: в [env] и [headers] допускаются ссылки вида
/// `${secret:name}`, значения живут в `SecretStore`.
final class McpServerConfig {
  const McpServerConfig({
    required this.id,
    required this.name,
    required this.transport,
    required this.source,
    required this.createdAt,
    required this.updatedAt,
    this.externalKey,
    this.enabled = true,
    this.command,
    this.args = const [],
    this.env = const {},
    this.cwd,
    this.url,
    this.headers = const {},
  });

  /// Восстанавливает запись из строки БД. Остальные поля — из JSON конфигурации.
  factory McpServerConfig.fromRow({
    required String id,
    required String name,
    required McpTransport transport,
    required McpServerSource source,
    required String configJson,
    required DateTime createdAt,
    required DateTime updatedAt,
    String? externalKey,
    bool enabled = true,
  }) {
    final json = jsonDecode(configJson);
    final config = json is Map ? json : const <String, Object?>{};
    return McpServerConfig(
      id: id,
      name: name,
      transport: transport,
      source: source,
      externalKey: externalKey,
      enabled: enabled,
      command: config['command'] as String?,
      args: _stringList(config['args']),
      env: _stringMap(config['env']),
      cwd: config['cwd'] as String?,
      url: config['url'] as String?,
      headers: _stringMap(config['headers']),
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  final String id;
  final String name;
  final McpTransport transport;
  final McpServerSource source;

  /// Ключ сервера в `mcp.json`. Null для пользовательских записей.
  final String? externalKey;
  final bool enabled;
  final String? command;
  final List<String> args;
  final Map<String, String> env;
  final String? cwd;
  final String? url;
  final Map<String, String> headers;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isFileManaged => source == McpServerSource.file;

  /// JSON транспортной части для колонки `config_json`.
  String get configJson => jsonEncode({
    if (command != null) 'command': command,
    if (args.isNotEmpty) 'args': args,
    if (env.isNotEmpty) 'env': env,
    if (cwd != null) 'cwd': cwd,
    if (url != null) 'url': url,
    if (headers.isNotEmpty) 'headers': headers,
  });

  McpServerConfig copyWith({
    String? id,
    String? name,
    McpTransport? transport,
    McpServerSource? source,
    String? externalKey,
    bool? enabled,
    String? command,
    List<String>? args,
    Map<String, String>? env,
    String? cwd,
    String? url,
    Map<String, String>? headers,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => McpServerConfig(
    id: id ?? this.id,
    name: name ?? this.name,
    transport: transport ?? this.transport,
    source: source ?? this.source,
    externalKey: externalKey ?? this.externalKey,
    enabled: enabled ?? this.enabled,
    command: command ?? this.command,
    args: args ?? this.args,
    env: env ?? this.env,
    cwd: cwd ?? this.cwd,
    url: url ?? this.url,
    headers: headers ?? this.headers,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

List<String> _stringList(Object? value) => value is List
    ? [
        for (final item in value)
          if (item is String) item,
      ]
    : const [];

Map<String, String> _stringMap(Object? value) => value is Map
    ? {
        for (final entry in value.entries)
          if (entry.key is String && entry.value is String)
            '${entry.key}': '${entry.value}',
      }
    : const {};

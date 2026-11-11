import 'dart:convert';

import 'package:probably_works/core/domain/mcp_server.dart';

/// Ошибка чтения `mcp.json`: файл битый или не соответствует схеме.
final class McpConfigException implements Exception {
  const McpConfigException(this.message);

  final String message;

  @override
  String toString() => 'McpConfigException: $message';
}

/// Чтение и запись конфигурации MCP в формате `mcp.json`.
///
/// Формат совместим с популярным `mcpServers`: объект по имени сервера.
/// Дополнительно поддерживаются `enabled`, `transport`, `cwd` и `headers`.
abstract final class McpJsonConfig {
  const McpJsonConfig._();

  static List<McpServerConfig> parse(String raw, {DateTime? now}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (error, stack) {
      Error.throwWithStackTrace(
        McpConfigException('invalid JSON: ${error.message}'),
        stack,
      );
    }
    if (decoded is! Map) {
      throw const McpConfigException('root must be a JSON object');
    }
    final servers = decoded['mcpServers'];
    if (servers is! Map) {
      throw const McpConfigException('mcpServers must be a JSON object');
    }
    final at = now ?? DateTime.now();
    final result = <McpServerConfig>[];
    for (final entry in servers.entries) {
      if (entry.key is! String || entry.value is! Map) {
        throw const McpConfigException('server entries must be objects');
      }
      result.add(_parseServer('${entry.key}', entry.value as Map, at));
    }
    return result;
  }

  static String encode(Iterable<McpServerConfig> servers) =>
      const JsonEncoder.withIndent('  ').convert({
        'mcpServers': {
          for (final server in servers)
            server.externalKey ?? server.name: _encodeServer(server),
        },
      });

  static McpServerConfig _parseServer(String key, Map json, DateTime at) {
    final name = json['name'] is String && (json['name'] as String).isNotEmpty
        ? json['name'] as String
        : key;
    final enabled = json['enabled'] != false;
    final command = json['command'] as String?;
    final url = json['url'] as String?;
    final explicit = json['transport'];
    final transport = switch (explicit) {
      'http' => McpTransport.http,
      'stdio' => McpTransport.stdio,
      _ when command != null && command.isNotEmpty => McpTransport.stdio,
      _ when url != null && url.isNotEmpty => McpTransport.http,
      _ => throw McpConfigException(
        'server "$key" needs command (stdio) or url (http)',
      ),
    };
    return McpServerConfig(
      id: 'file:$key',
      name: name,
      transport: transport,
      source: McpServerSource.file,
      externalKey: key,
      enabled: enabled,
      command: command,
      args: _stringList(json['args']),
      env: _stringMap(json['env']),
      cwd: json['cwd'] as String?,
      url: url,
      headers: _stringMap(json['headers']),
      oauth: json['oauth'] is Map
          ? McpOAuthConfig.fromJson(json['oauth'] as Map)
          : null,
      createdAt: at,
      updatedAt: at,
    );
  }

  static Map<String, Object?> _encodeServer(McpServerConfig server) => {
    'name': server.name,
    'transport': server.transport.name,
    'enabled': server.enabled,
    if (server.command != null) 'command': server.command,
    if (server.args.isNotEmpty) 'args': server.args,
    if (server.env.isNotEmpty) 'env': server.env,
    if (server.cwd != null) 'cwd': server.cwd,
    if (server.url != null) 'url': server.url,
    if (server.headers.isNotEmpty) 'headers': server.headers,
    if (server.oauth != null) 'oauth': server.oauth!.toJson(),
  };

  static List<String> _stringList(Object? value) => value is List
      ? [
          for (final item in value)
            if (item is String) item,
        ]
      : const [];

  static Map<String, String> _stringMap(Object? value) => value is Map
      ? {
          for (final entry in value.entries)
            if (entry.key is String && entry.value is String)
              '${entry.key}': '${entry.value}',
        }
      : const {};
}

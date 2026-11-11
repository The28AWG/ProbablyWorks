import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:injectable/injectable.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:probably_works/agent/mcp/mcp_oauth_provider.dart';
import 'package:probably_works/core/domain/mcp_server.dart';
import 'package:probably_works/core/security/secret_store.dart';
import 'package:probably_works/core/util/redactor.dart';
import 'package:url_launcher/url_launcher.dart';

/// Состояние подключения MCP-сервера.
enum McpConnectionStatus { disconnected, connecting, connected, error }

/// Инструмент, который объявил MCP-сервер.
final class McpToolInfo {
  const McpToolInfo({
    required this.name,
    required this.inputSchema,
    this.title,
    this.description,
  });

  final String name;
  final String? title;
  final String? description;
  final Map<String, dynamic> inputSchema;

  String get displayName => title ?? name;
}

/// Снимок состояния одного сервера для настроек и источника инструментов.
final class McpServerState {
  const McpServerState({
    required this.serverId,
    required this.status,
    this.tools = const [],
    this.error,
  });

  const McpServerState.disconnected(this.serverId)
    : status = McpConnectionStatus.disconnected,
      tools = const [],
      error = null;

  final String serverId;
  final McpConnectionStatus status;
  final List<McpToolInfo> tools;
  final String? error;

  bool get isConnected => status == McpConnectionStatus.connected;
}

/// Итог вызова MCP-инструмента. Текст уже собран из content-блоков.
final class McpToolCallOutput {
  const McpToolCallOutput(this.text, {this.isError = false});

  final String text;
  final bool isError;
}

/// Создаёт транспорт для сервера. Вынесено отдельно для тестов на IOStreamTransport.
typedef McpTransportBuilder = Future<Transport> Function(
  McpServerConfig server,
  Map<String, String> environment,
  Map<String, String> headers,
  OAuthClientProvider? authProvider,
);

final class _Session {
  const _Session({
    required this.server,
    required this.client,
    required this.tools,
  });

  final McpServerConfig server;
  final McpClient client;
  final List<McpToolInfo> tools;
}

/// Подключения к MCP-серверам и их инструменты.
///
/// Один экземпляр на приложение: серверы общие для всех чатов, а вызовы
/// сериализуются транспортом. Состояние только в памяти; настройки — в БД.
@lazySingleton
class McpClientManager {
  McpClientManager(this._secrets)
    : _transportBuilder = _defaultTransport,
      _openUrl = _launchUrl;

  McpClientManager.withTransport(
    this._secrets,
    this._transportBuilder, {
    Future<void> Function(Uri)? openUrl,
  }) : _openUrl = openUrl ?? _launchUrl;

  final SecretStore _secrets;
  final McpTransportBuilder _transportBuilder;
  final Future<void> Function(Uri) _openUrl;
  final _sessions = <String, _Session>{};
  final _states = <String, McpServerState>{};
  final _changes = StreamController<McpServerState>.broadcast();

  /// Поток обновлений статуса и списка инструментов.
  Stream<McpServerState> get changes => _changes.stream;

  McpServerState stateOf(String serverId) =>
      _states[serverId] ?? McpServerState.disconnected(serverId);

  /// Подключается к серверу и обновляет список инструментов.
  ///
  /// Ошибка не бросается наружу: она попадает в состояние, чтобы настройки
  /// могли показать её рядом с сервером.
  Future<McpServerState> connect(
    McpServerConfig server, {
    bool force = false,
  }) async {
    final existing = _sessions[server.id];
    if (!force && existing != null) {
      return stateOf(server.id);
    }
    await disconnect(server.id);
    _emit(
      McpServerState(
        serverId: server.id,
        status: McpConnectionStatus.connecting,
      ),
    );
    final oauth = server.transport == McpTransport.http && server.oauth != null
        ? McpOAuthProvider(server: server, secrets: _secrets, openUrl: _openUrl)
        : null;
    try {
      final session = await _openSession(server, oauth);
      _sessions[server.id] = session;
      final state = McpServerState(
        serverId: server.id,
        status: McpConnectionStatus.connected,
        tools: session.tools,
      );
      _emit(state);
      return state;
    } on Object catch (error) {
      final state = McpServerState(
        serverId: server.id,
        status: McpConnectionStatus.error,
        error: Redactor.redact('$error'),
      );
      _emit(state);
      return state;
    }
  }

  Future<_Session> _openSession(
    McpServerConfig server,
    McpOAuthProvider? oauth, {
    bool allowAuth = true,
  }) async {
    final environment = await _resolveMap(server.env);
    final headers = await _resolveMap(server.headers);
    final transport = await _transportBuilder(
      server,
      environment,
      headers,
      oauth,
    );
    final client = McpClient(
      const Implementation(name: 'probably_works', version: '1.0.0'),
    );
    try {
      await client.connect(transport);
      final tools = await _listTools(client);
      return _Session(server: server, client: client, tools: tools);
    } on UnauthorizedError {
      if (!allowAuth ||
          oauth == null ||
          transport is! StreamableHttpClientTransport) {
        await client.close();
        rethrow;
      }
      try {
        final callback = await oauth.waitForCallback();
        await transport.finishAuthRedirect(
          callback.code,
          state: callback.state,
        );
      } on Object {
        await client.close();
        rethrow;
      }
      await client.close();
      // Токен уже сохранён. Новый транспорт подключится без повторного redirect.
      return _openSession(server, oauth, allowAuth: false);
    } on Object {
      await client.close();
      rethrow;
    }
  }

  /// Закрывает подключение и забывает состояние сервера.
  Future<void> disconnect(String serverId) async {
    final session = _sessions.remove(serverId);
    if (session != null) {
      await session.client.close();
    }
    _states.remove(serverId);
    _emit(McpServerState.disconnected(serverId));
  }

  /// Перезапускает сервер: закрывает старое подключение и создаёт новое.
  Future<McpServerState> restart(McpServerConfig server) =>
      connect(server, force: true);

  /// Перечитывает `tools/list`, не пересоздавая подключение.
  Future<McpServerState> refreshTools(McpServerConfig server) async {
    final session = _sessions[server.id];
    if (session == null) return connect(server);
    try {
      final tools = await _listTools(session.client);
      _sessions[server.id] = _Session(
        server: server,
        client: session.client,
        tools: tools,
      );
      final state = McpServerState(
        serverId: server.id,
        status: McpConnectionStatus.connected,
        tools: tools,
      );
      _emit(state);
      return state;
    } on Object catch (error) {
      final state = McpServerState(
        serverId: server.id,
        status: McpConnectionStatus.error,
        error: Redactor.redact('$error'),
      );
      _emit(state);
      return state;
    }
  }

  /// Вызывает инструмент. При отсутствии подключения сначала подключается.
  Future<McpToolCallOutput> callTool(
    McpServerConfig server,
    String toolName,
    Map<String, dynamic> arguments,
  ) async {
    var session = _sessions[server.id];
    if (session == null) {
      final state = await connect(server);
      if (!state.isConnected) {
        throw StateError(state.error ?? 'MCP server is not connected');
      }
      session = _sessions[server.id]!;
    }
    final result = await session.client.callTool(
      CallToolRequest(name: toolName, arguments: arguments),
      options: const RequestOptions(timeout: Duration(seconds: 60)),
    );
    return McpToolCallOutput(_textOf(result), isError: result.isError);
  }

  /// Закрывает все подключения. Вызывается при завершении приложения.
  Future<void> closeAll() async {
    final ids = [..._sessions.keys];
    for (final id in ids) {
      await disconnect(id);
    }
  }

  Future<List<McpToolInfo>> _listTools(McpClient client) async {
    final tools = <McpToolInfo>[];
    String? cursor;
    do {
      final result = await client.listTools(
        params: cursor == null ? null : ListToolsRequest(cursor: cursor),
      );
      tools.addAll([
        for (final tool in result.tools)
          McpToolInfo(
            name: tool.name,
            title: tool.title,
            description: tool.description,
            inputSchema: tool.inputSchema.toJson(),
          ),
      ]);
      cursor = result.nextCursor;
    } while (cursor != null);
    return tools;
  }

  String _textOf(CallToolResult result) {
    final parts = <String>[];
    for (final content in result.content) {
      if (content is TextContent) {
        parts.add(content.text);
      } else if (content is ImageContent) {
        parts.add(
          '[image ${content.mimeType}, ${content.data.length} base64 chars]',
        );
      } else {
        parts.add(jsonEncode(content.toJson()));
      }
    }
    if (parts.isEmpty && result.structuredContent != null) {
      parts.add(jsonEncode(result.structuredContent));
    }
    return parts.join('\n\n');
  }

  Future<Map<String, String>> _resolveMap(Map<String, String> values) async {
    final resolved = <String, String>{};
    for (final entry in values.entries) {
      resolved[entry.key] = await _resolveSecret(entry.value);
    }
    return resolved;
  }

  Future<String> _resolveSecret(String value) async {
    final match = _secretRef.firstMatch(value);
    if (match == null) return value;
    final key = match.group(1)!;
    final secret = await _secrets.read(key);
    if (secret == null) {
      throw StateError('MCP secret not found: $key');
    }
    return secret;
  }

  static final _secretRef = RegExp(r'^\$\{secret:([^}]+)\}$');

  void _emit(McpServerState state) {
    _states[state.serverId] = state;
    if (!_changes.isClosed) _changes.add(state);
  }

  static Future<Transport> _defaultTransport(
    McpServerConfig server,
    Map<String, String> environment,
    Map<String, String> headers,
    OAuthClientProvider? authProvider,
  ) async {
    switch (server.transport) {
      case McpTransport.stdio:
        final command = server.command;
        if (command == null || command.isEmpty) {
          throw StateError('MCP stdio server has no command');
        }
        return StdioClientTransport(
          StdioServerParameters(
            command: command,
            args: server.args,
            environment: {..._baseEnvironment(), ...environment},
            includeParentEnvironment: false,
            workingDirectory: server.cwd,
            stderrMode: ProcessStartMode.normal,
            restartOnUnexpectedExit: false,
          ),
        );
      case McpTransport.http:
        final url = server.url;
        if (url == null || url.isEmpty) {
          throw StateError('MCP HTTP server has no url');
        }
        return StreamableHttpClientTransport(
          Uri.parse(url),
          opts: StreamableHttpClientTransportOptions(
            authProvider: authProvider,
            requestInit: headers.isEmpty ? null : {'headers': headers},
          ),
        );
    }
  }

  static Future<void> _launchUrl(Uri url) async {
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      throw StateError('cannot open authorization URL');
    }
  }

  /// Минимальное окружение для дочернего процесса: без токенов и чужих секретов.
  static Map<String, String> _baseEnvironment() {
    final parent = Platform.environment;
    final keys = Platform.isWindows
        ? const {
            'PATH',
            'PATHEXT',
            'SystemRoot',
            'SystemDrive',
            'TEMP',
            'TMP',
            'USERPROFILE',
            'COMSPEC',
            'WINDIR',
            'HOMEDRIVE',
            'HOMEPATH',
          }
        : const {
            'PATH',
            'HOME',
            'USER',
            'LOGNAME',
            'SHELL',
            'TMPDIR',
            'LANG',
            'LC_ALL',
            'LC_CTYPE',
            'TERM',
          };
    final environment = <String, String>{};
    for (final key in keys) {
      final value = parent[key];
      if (value != null) environment[key] = value;
    }
    return environment;
  }
}

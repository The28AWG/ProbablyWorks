import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:plugin_api/plugin_api.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/exec/command_executor.dart';
import 'package:pw_agent/agent/plugins/network_guard.dart';
import 'package:pw_agent/agent/plugins/plugin_file_reader.dart';
import 'package:pw_agent/agent/tools/tool_executor.dart';
import 'package:pw_agent/agent/tools/tool_name.dart';
import 'package:pw_agent/agent/tools/tool_source.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/core/util/workspace_path.dart';
import 'package:pw_agent/host/shell_adapter.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:uuid/uuid.dart';

/// Инструменты одного включённого плагина.
final class PluginToolSource extends ToolSource {
  PluginToolSource({
    required this.plugin,
    required this.tools,
    required this.commands,
    required this.files,
    required this.secrets,
  }) {
    final used = <String>{};
    for (final tool in tools) {
      final modelName = _uniqueName(plugin.id, tool.name, used);
      _tools[modelName] = tool;
    }
    specs = List.unmodifiable([
      for (final entry in _tools.entries)
        LlmToolSpec(
          name: entry.key,
          description: entry.value.description,
          parameters: Map<String, dynamic>.from(entry.value.inputSchema),
        ),
    ]);
    mutatesHost = tools.any((tool) => tool.mutatesHost);
  }

  final Plugin plugin;
  final List<PluginTool> tools;
  final CommandExecutor commands;

  /// Общий исполнитель файловых операций: через него плагин читает и
  /// предлагает запись, чтобы policy, подтверждение и changeset оставались
  /// в одном месте, а плагин не обходил их.
  final ToolExecutor files;
  final SecretStore secrets;
  final _tools = <String, PluginTool>{};

  @override
  String get id => 'plugin:${plugin.id}';

  @override
  late final List<LlmToolSpec> specs;

  @override
  late final bool mutatesHost;

  @override
  Future<ToolResult> call(
    LlmToolCall call,
    Map<String, dynamic> arguments,
    ToolContext context,
  ) async {
    final tool = _tools[call.name];
    if (tool == null) {
      return ToolResult('unknown plugin tool: ${call.name}', isError: true);
    }
    final result = await tool.run(
      arguments,
      _PluginHost(context, commands, files, secrets),
    );
    return ToolResult(result.text, isError: result.isError);
  }

  @override
  String summaryFor(LlmToolCall call, Map<String, dynamic> arguments) =>
      _tools[call.name]?.title ?? call.name;

  @override
  String reasonFor(LlmToolCall call) => 'plugin ${plugin.id}';

  static String _uniqueName(
    String pluginId,
    String toolName,
    Set<String> used,
  ) {
    final base = fitToolName('plugin_${_slug(pluginId)}_${_slug(toolName)}');
    var name = base;
    var index = 2;
    while (!used.add(name)) {
      name = '${base}_$index';
      index++;
    }
    return name;
  }

  static String _slug(String value) {
    final buffer = StringBuffer();
    for (final rune in value.runes) {
      final safe =
          (rune >= 0x30 && rune <= 0x39) ||
          (rune >= 0x41 && rune <= 0x5A) ||
          (rune >= 0x61 && rune <= 0x7A);
      buffer.write(safe ? String.fromCharCode(rune) : '_');
    }
    final slug = buffer.toString();
    return slug.isEmpty ? 'x' : slug;
  }
}

final class _PluginHost implements PluginHost {
  _PluginHost(this._context, this.commands, this._files, this._secrets);

  static const _uuid = Uuid();

  final ToolContext _context;
  final CommandExecutor commands;
  final ToolExecutor _files;
  final SecretStore _secrets;

  @override
  String get chatId => _context.chat.id;

  @override
  String get cwd => commandWorkspace(_context.host, _context.chat.workspace);

  @override
  Future<PluginCommandResult> runCommand(
    String executable,
    List<String> args, {
    Duration? timeout,
  }) async {
    final command = ShellAdapter(_context.runtime.os).runArgv(executable, args);
    final handle = await commands.start(
      chatId: chatId,
      hostId: _context.host.id,
      toolCallId: 'plugin-${_uuid.v4()}',
      runtime: _context.runtime,
      command: command,
      displayCommand: [executable, ...args].join(' '),
      limits: _context.limits,
      background: false,
      cwd: cwd,
      timeout: timeout,
    );
    final outcome = await handle.finished;
    return PluginCommandResult(
      output: outcome.outputText,
      exitCode: outcome.exitCode,
      isError: outcome.resultError || outcome.status != ToolRunStatus.done,
    );
  }

  @override
  Future<PluginFileReader> readFile(String path) => ReadFileCursor.open(
    (offset, byteOffset, first) =>
        _readChunk(path, offset, byteOffset, first: first),
  );

  @override
  Future<PluginFileResult> readAll(String path) async {
    final reader = await readFile(path);
    while (!reader.done) {
      await reader.next();
    }
    return PluginFileResult(reader.text, isError: reader.isError);
  }

  Future<({String text, bool isError})> _readChunk(
    String path,
    int offset,
    int byteOffset, {
    required bool first,
  }) async {
    final result = await _files.readFileChunkForPlugin(
      _context,
      path,
      offset: offset,
      byteOffset: byteOffset,
      first: first,
    );
    return (text: result.text, isError: result.isError);
  }

  @override
  Future<PluginFileResult> writeFile(String path, String content) async {
    final result = await _files.writeFileForPlugin(_context, path, content);
    return PluginFileResult(result.text, isError: result.isError);
  }

  @override
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
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      throw ArgumentError.value(url, 'url', 'invalid HTTP URL');
    }
    final loopback =
        uri.host == 'localhost' || uri.host == '127.0.0.1' || uri.host == '::1';
    if (uri.scheme != 'https' && !(uri.scheme == 'http' && loopback)) {
      throw StateError('only HTTPS or loopback HTTP is allowed');
    }
    if (loopback && !allowLoopback) {
      throw StateError('loopback HTTP is not allowed');
    }
    if (!allowPrivateNetwork || !allowLoopback) {
      await ensureNetworkAllowed(
        uri,
        allowLoopback: allowLoopback,
        allowPrivateNetwork: allowPrivateNetwork,
      );
    }
    final resolved = await _resolveMap(headers);
    final client = http.Client();
    try {
      final request = http.Request(method.toUpperCase(), uri);
      request.headers.addAll(resolved);
      request.followRedirects = followRedirects;
      if (body != null) {
        if (body is String) {
          request.body = body;
        } else {
          request.headers.putIfAbsent(
            'content-type',
            () => 'application/json; charset=utf-8',
          );
          request.body = jsonEncode(body);
        }
      }
      final wait = timeout ?? const Duration(seconds: 30);
      final streamed = await client.send(request).timeout(wait);
      final bytes = await _readBytes(streamed, maxBytes).timeout(wait);
      final response = http.Response.bytes(
        bytes.bytes,
        streamed.statusCode,
        headers: streamed.headers,
        isRedirect: streamed.isRedirect,
        persistentConnection: streamed.persistentConnection,
        reasonPhrase: streamed.reasonPhrase,
        request: streamed.request,
      );
      return PluginHttpResult(
        statusCode: response.statusCode,
        body: _decodeBody(bytes.bytes, response.headers),
        headers: response.headers,
        isError: response.statusCode < 200 || response.statusCode >= 300,
        bodyBytes: bytes.bytes,
        finalUrl: response.request?.url.toString(),
        contentType: response.headers['content-type'],
        truncated: bytes.truncated,
      );
    } finally {
      client.close();
    }
  }

  /// Читает тело ответа, не превышая [maxBytes].
  ///
  /// Как только лимит достигнут, поток прекращает читаться, а результат
  /// помечается как обрезанный. Поток закрывается в любом случае.
  static Future<({Uint8List bytes, bool truncated})> _readBytes(
    http.StreamedResponse response,
    int? maxBytes,
  ) async {
    if (maxBytes == null) {
      return (
        bytes: Uint8List.fromList(await response.stream.toBytes()),
        truncated: false,
      );
    }
    if (maxBytes <= 0) throw ArgumentError.value(maxBytes, 'maxBytes');
    final builder = BytesBuilder(copy: false);
    var truncated = false;
    await for (final chunk in response.stream) {
      final left = maxBytes - builder.length;
      if (left <= 0) {
        truncated = true;
        break;
      }
      if (chunk.length <= left) {
        builder.add(chunk);
      } else {
        builder.add(chunk.sublist(0, left));
        truncated = true;
        break;
      }
    }
    return (bytes: builder.takeBytes(), truncated: truncated);
  }

  /// Декодирует тело по charset из `Content-Type`.
  ///
  /// Поведение совпадает с `http.Response.body`: если charset не указан,
  /// используется latin1. Веб-плагин для страниц берёт `bodyBytes` и решает
  /// сам, потому что у HTML кодировка может быть в `<meta charset>`.
  static String _decodeBody(Uint8List bytes, Map<String, String> headers) {
    final contentType = headers['content-type'] ?? '';
    final match = RegExp(
      r'charset\s*=\s*"?([^";]+)"?',
      caseSensitive: false,
    ).firstMatch(contentType);
    final encoding = match == null
        ? latin1
        : (Encoding.getByName(match.group(1)!.trim()) ?? latin1);
    return encoding.decode(bytes);
  }

  static final _secretRef = RegExp(r'\$\{secret:([^}]+)\}');

  Future<Map<String, String>> _resolveMap(Map<String, String> values) async {
    final result = <String, String>{};
    for (final entry in values.entries) {
      result[entry.key] = await _resolveSecrets(entry.value);
    }
    return result;
  }

  Future<String> _resolveSecrets(String value) async {
    final found = <String, String>{};
    for (final match in _secretRef.allMatches(value)) {
      final key = match.group(1)!;
      final secret = await _secrets.read(key);
      if (secret == null) throw StateError('plugin secret not found: $key');
      found[key] = secret;
    }
    return value.replaceAllMapped(
      _secretRef,
      (match) => found[match.group(1)!]!,
    );
  }
}

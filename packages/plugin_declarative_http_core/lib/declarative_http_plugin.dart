import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:json_path/json_path.dart';
import 'package:new_beautiful_soup_dart/new_beautiful_soup_dart.dart';
import 'package:plugin_api/plugin_api.dart';

/// Плагин HTTP-инструментов с фиксированными endpoint'ами и аргументами.
final class DeclarativeHttpPlugin implements Plugin {
  const DeclarativeHttpPlugin();

  @override
  String get id => 'declarative_http';

  @override
  Set<String> get dependsOn => const {};

  @override
  bool get defaultEnabled => false;

  @override
  Future<List<PluginTool>> createTools(PluginSettings settings) async {
    final tools = await _readTools(settings);
    return [
      for (final tool in tools)
        PluginTool(
          name: tool.id,
          title: tool.title,
          description: tool.description,
          inputSchema: tool.inputSchema,
          run: (arguments, host) => _run(tool, arguments, host),
        ),
    ];
  }

  Future<PluginToolResult> _run(
    DeclarativeHttpTool tool,
    Map<String, dynamic> arguments,
    PluginHost host,
  ) async {
    try {
      final url = _substitute(tool.url, arguments, encode: true);
      final headers = {
        for (final entry in tool.headers.entries)
          entry.key: _substitute(entry.value, arguments),
      };
      final result = await host.httpRequest(
        method: tool.method,
        url: url,
        headers: headers,
        body: _substituteBody(tool.body, arguments),
        timeout: Duration(seconds: tool.timeoutSeconds),
      );
      if (result.isError) {
        return PluginToolResult(
          'HTTP ${result.statusCode}\n${result.body}',
          isError: true,
        );
      }
      return PluginToolResult(
        _clip(_formatResponse(tool, result.body), tool.maxResponseChars),
      );
    } on Object catch (error) {
      return PluginToolResult('$error', isError: true);
    }
  }

  static String _formatResponse(DeclarativeHttpTool tool, String body) =>
      switch (tool.responseFormat) {
        HttpResponseFormat.text => body,
        HttpResponseFormat.json => _formatJson(body, tool.jsonPath),
        HttpResponseFormat.html => _formatHtml(body, tool.htmlSelector),
      };

  static String _formatJson(String body, String? path) {
    final decoded = jsonDecode(body);
    if (path == null || path.trim().isEmpty) {
      return const JsonEncoder.withIndent('  ').convert(decoded);
    }
    final matches = JsonPath(path).read(decoded).toList();
    if (matches.isEmpty) return 'no matches for $path';
    if (matches.length == 1) return _jsonValue(matches.single.value);
    return const JsonEncoder.withIndent('  ')
        .convert([for (final match in matches) match.value]);
  }

  static String _formatHtml(String body, String? selector) {
    try {
      final soup = BeautifulSoup(body);
      if (selector == null || selector.trim().isEmpty) return soup.text;
      final elements = soup.findAll('', selector: selector);
      if (elements.isEmpty) return 'no matches for $selector';
      return elements
          .map((element) {
            final text = element.text.trim();
            return text.isEmpty ? element.toString() : text;
          })
          .join('\n---\n');
    } on Object {
      return body;
    }
  }

  static String _jsonValue(Object? value) => value is String
      ? value
      : const JsonEncoder.withIndent('  ').convert(value);

  static String _clip(String value, int maxChars) {
    final chars = value.characters;
    if (chars.length <= maxChars) return value;
    return '${chars.take(maxChars)}…';
  }

  static final _argumentRef = RegExp(r'\{\{([A-Za-z0-9_]+)\}\}');

  static String _substitute(
    String template,
    Map<String, dynamic> arguments, {
    bool encode = false,
  }) => template.replaceAllMapped(_argumentRef, (match) {
    final name = match.group(1)!;
    if (!arguments.containsKey(name)) {
      throw StateError('missing argument: $name');
    }
    final value = '${arguments[name]}';
    return encode ? Uri.encodeComponent(value) : value;
  });

  static Object? _substituteBody(Object? body, Map<String, dynamic> arguments) {
    if (body is String) return _substitute(body, arguments);
    if (body is List) {
      return [for (final item in body) _substituteBody(item, arguments)];
    }
    if (body is Map) {
      return {
        for (final entry in body.entries)
          entry.key: _substituteBody(entry.value, arguments),
      };
    }
    return body;
  }

  static Future<List<DeclarativeHttpTool>> _readTools(
    PluginSettings settings,
  ) async {
    final raw = await settings.read();
    final tools = raw['tools'];
    if (tools is! List) return const [];
    final result = <DeclarativeHttpTool>[];
    for (final item in tools) {
      if (item is! Map) continue;
      final tool = DeclarativeHttpTool.fromJson(item);
      if (tool.id.isEmpty || tool.title.isEmpty || tool.url.isEmpty) continue;
      result.add(tool);
    }
    return result;
  }
}

/// Один HTTP-инструмент плагина.
enum HttpResponseFormat { text, json, html }

final class DeclarativeHttpTool {
  const DeclarativeHttpTool({
    required this.id,
    required this.title,
    required this.description,
    required this.method,
    required this.url,
    required this.headers,
    required this.body,
    required this.inputSchema,
    required this.timeoutSeconds,
    required this.maxResponseChars,
    required this.responseFormat,
    this.jsonPath,
    this.htmlSelector,
  });

  factory DeclarativeHttpTool.fromJson(Map json) => DeclarativeHttpTool(
    id: '${json['id'] ?? ''}',
    title: '${json['title'] ?? ''}',
    description: '${json['description'] ?? ''}',
    method: '${json['method'] ?? 'GET'}',
    url: '${json['url'] ?? ''}',
    headers: _stringMap(json['headers']),
    body: json['body'],
    inputSchema: json['inputSchema'] is Map
        ? Map<String, Object?>.from(json['inputSchema'] as Map)
        : const {'type': 'object', 'properties': <String, Object?>{}},
    timeoutSeconds: json['timeoutSeconds'] is num
        ? (json['timeoutSeconds'] as num).toInt()
        : 30,
    maxResponseChars: json['maxResponseChars'] is num
        ? (json['maxResponseChars'] as num).toInt()
        : 20000,
    responseFormat:
        HttpResponseFormat.values
            .where((format) => format.name == json['responseFormat'])
            .firstOrNull ??
        HttpResponseFormat.text,
    jsonPath: json['jsonPath'] as String?,
    htmlSelector: json['htmlSelector'] as String?,
  );

  final String id;
  final String title;
  final String description;
  final String method;
  final String url;
  final Map<String, String> headers;
  final Object? body;
  final Map<String, Object?> inputSchema;
  final int timeoutSeconds;
  final int maxResponseChars;
  final HttpResponseFormat responseFormat;
  final String? jsonPath;
  final String? htmlSelector;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'description': description,
    'method': method,
    'url': url,
    'headers': headers,
    if (body != null) 'body': body,
    'inputSchema': inputSchema,
    'timeoutSeconds': timeoutSeconds,
    'maxResponseChars': maxResponseChars,
    'responseFormat': responseFormat.name,
    if (jsonPath != null && jsonPath!.isNotEmpty) 'jsonPath': jsonPath,
    if (htmlSelector != null && htmlSelector!.isNotEmpty)
      'htmlSelector': htmlSelector,
  };

  DeclarativeHttpTool copyWith({
    String? id,
    String? title,
    String? description,
    String? method,
    String? url,
    Map<String, String>? headers,
    Object? body,
    Map<String, Object?>? inputSchema,
    int? timeoutSeconds,
    int? maxResponseChars,
    HttpResponseFormat? responseFormat,
    String? jsonPath,
    String? htmlSelector,
  }) => DeclarativeHttpTool(
    id: id ?? this.id,
    title: title ?? this.title,
    description: description ?? this.description,
    method: method ?? this.method,
    url: url ?? this.url,
    headers: headers ?? this.headers,
    body: body ?? this.body,
    inputSchema: inputSchema ?? this.inputSchema,
    timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
    maxResponseChars: maxResponseChars ?? this.maxResponseChars,
    responseFormat: responseFormat ?? this.responseFormat,
    jsonPath: jsonPath ?? this.jsonPath,
    htmlSelector: htmlSelector ?? this.htmlSelector,
  );
}

Map<String, String> _stringMap(Object? value) => value is Map
    ? {
        for (final entry in value.entries)
          if (entry.key is String && entry.value is String)
            '${entry.key}': '${entry.value}',
      }
    : const {};

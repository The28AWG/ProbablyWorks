import 'dart:convert';

import 'package:app_ui/app_ui.dart';
import 'package:json_path/json_path.dart';
import 'package:material_ui/material_ui.dart';
import 'package:new_beautiful_soup_dart/new_beautiful_soup_dart.dart';
import 'package:plugin_api/plugin_api.dart';
import 'package:plugin_declarative_http/l10n/generated/declarative_http_localizations.dart';
import 'package:uuid/uuid.dart';

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
  LocalizationsDelegate<dynamic> get localizations =>
      DeclarativeHttpLocalizations.delegate;

  @override
  String titleOf(BuildContext context) =>
      DeclarativeHttpLocalizations.of(context).pluginTitle;

  @override
  String descriptionOf(BuildContext context) =>
      DeclarativeHttpLocalizations.of(context).pluginDescription;

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

  @override
  Widget? buildSettings(BuildContext context, PluginSettings settings) =>
      DeclarativeHttpSettings(settings: settings);

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

/// Экран настроек HTTP-плагина.
class DeclarativeHttpSettings extends StatefulWidget {
  const DeclarativeHttpSettings({required this.settings, super.key});

  final PluginSettings settings;

  @override
  State<DeclarativeHttpSettings> createState() =>
      _DeclarativeHttpSettingsState();
}

class _DeclarativeHttpSettingsState extends State<DeclarativeHttpSettings> {
  static const _uuid = Uuid();

  var _tools = <DeclarativeHttpTool>[];
  var _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final raw = await widget.settings.read();
      final list = raw['tools'];
      final tools = list is List
          ? [
              for (final item in list)
                if (item is Map) DeclarativeHttpTool.fromJson(item),
            ]
          : <DeclarativeHttpTool>[];
      if (!mounted) return;
      setState(() {
        _tools = tools;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  Future<void> _save(List<DeclarativeHttpTool> tools) async {
    await widget.settings.save({
      'version': 1,
      'tools': [for (final tool in tools) tool.toJson()],
    });
    if (!mounted) return;
    setState(() => _tools = tools);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = DeclarativeHttpLocalizations.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error case final error?) {
      return AppBanner(message: error, tone: AppTone.danger);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.settingsHint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            FilledButton.icon(
              onPressed: () => _edit(context, null),
              icon: const Icon(Icons.add),
              label: Text(l10n.addTool),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          l10n.toolCount(_tools.length),
          style: Theme.of(context).textTheme.labelSmall,
        ),
        const SizedBox(height: AppSpacing.sm),
        if (_tools.isEmpty)
          AppEmptyState(
            icon: Icons.http_outlined,
            title: l10n.emptyTitle,
            message: l10n.emptyMessage,
          )
        else
          for (final tool in _tools)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: AppCard(
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tool.title,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          Text(
                            tool.description.isEmpty
                                ? '${tool.method} ${tool.url}'
                                : tool.description,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          Text(
                            '${tool.method} ${tool.url}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.edit,
                      onPressed: () => _edit(context, tool),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    IconButton(
                      tooltip: l10n.delete,
                      onPressed: () => _delete(context, tool),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }

  Future<void> _edit(BuildContext context, DeclarativeHttpTool? tool) async {
    final result = await showDialog<DeclarativeHttpTool>(
      context: context,
      builder: (_) => _HttpToolDialog(tool: tool, id: tool?.id ?? _uuid.v4()),
    );
    if (result == null || !mounted) return;
    final existing = _tools.indexWhere((item) => item.id == result.id);
    final next = [..._tools];
    if (existing < 0) {
      next.add(result);
    } else {
      next[existing] = result;
    }
    await _save(next);
  }

  Future<void> _delete(BuildContext context, DeclarativeHttpTool tool) async {
    final l10n = DeclarativeHttpLocalizations.of(context);
    final confirmed = await ConfirmDialog.confirm(
      context,
      title: l10n.deleteTitle,
      message: l10n.deleteConfirm(tool.title),
      cancelLabel: l10n.cancel,
      confirmLabel: l10n.delete,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _save([
      for (final item in _tools)
        if (item.id != tool.id) item,
    ]);
  }
}

class _HttpToolDialog extends StatefulWidget {
  const _HttpToolDialog({required this.tool, required this.id});

  final DeclarativeHttpTool? tool;
  final String id;

  @override
  State<_HttpToolDialog> createState() => _HttpToolDialogState();
}

class _HttpToolDialogState extends State<_HttpToolDialog> {
  late final _title = TextEditingController(text: widget.tool?.title ?? '');
  late final _description = TextEditingController(
    text: widget.tool?.description ?? '',
  );
  late final _method = TextEditingController(
    text: widget.tool?.method ?? 'GET',
  );
  late final _url = TextEditingController(text: widget.tool?.url ?? '');
  late final _headers = TextEditingController(
    text: _pairsText(widget.tool?.headers),
  );
  late final _body = TextEditingController(
    text: widget.tool?.body == null
        ? ''
        : widget.tool!.body is String
        ? widget.tool!.body! as String
        : const JsonEncoder.withIndent('  ').convert(widget.tool!.body),
  );
  late final _schema = TextEditingController(
    text: const JsonEncoder.withIndent('  ').convert(
      widget.tool?.inputSchema ??
          const {'type': 'object', 'properties': <String, Object?>{}},
    ),
  );
  late final _jsonPath = TextEditingController(
    text: widget.tool?.jsonPath ?? '',
  );
  late final _selector = TextEditingController(
    text: widget.tool?.htmlSelector ?? '',
  );
  late final _timeout = TextEditingController(
    text: '${widget.tool?.timeoutSeconds ?? 30}',
  );
  late final _maxChars = TextEditingController(
    text: '${widget.tool?.maxResponseChars ?? 20000}',
  );
  late var _format = widget.tool?.responseFormat ?? HttpResponseFormat.text;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _method.dispose();
    _url.dispose();
    _headers.dispose();
    _body.dispose();
    _schema.dispose();
    _jsonPath.dispose();
    _selector.dispose();
    _timeout.dispose();
    _maxChars.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = DeclarativeHttpLocalizations.of(context);
    final editing = widget.tool != null;
    return AlertDialog(
      title: Text(
        editing ? l10n.editTool : l10n.newTool,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: AppLayout.dialogWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppTextField(controller: _title, label: l10n.name),
              const SizedBox(height: AppSpacing.md),
              AppTextField(
                controller: _description,
                label: l10n.description,
                maxLines: 2,
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  SizedBox(
                    width: 110,
                    child: AppTextField(
                      controller: _method,
                      label: l10n.method,
                      mono: true,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: AppTextField(
                      controller: _url,
                      label: l10n.url,
                      mono: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              AppTextField(
                controller: _headers,
                label: l10n.headers,
                hint: l10n.headersHint,
                minLines: 2,
                maxLines: 5,
                mono: true,
              ),
              const SizedBox(height: AppSpacing.md),
              AppTextField(
                controller: _body,
                label: l10n.body,
                hint: l10n.bodyHint,
                minLines: 3,
                maxLines: 7,
                mono: true,
              ),
              const SizedBox(height: AppSpacing.md),
              AppTextField(
                controller: _schema,
                label: l10n.inputSchema,
                hint: l10n.inputSchemaHint,
                minLines: 3,
                maxLines: 8,
                mono: true,
              ),
              const SizedBox(height: AppSpacing.md),
              AppChoiceGroup<HttpResponseFormat>(
                options: [
                  AppChoiceOption(
                    value: HttpResponseFormat.text,
                    title: l10n.responseText,
                    subtitle: '',
                  ),
                  AppChoiceOption(
                    value: HttpResponseFormat.json,
                    title: l10n.responseJson,
                    subtitle: '',
                  ),
                  AppChoiceOption(
                    value: HttpResponseFormat.html,
                    title: l10n.responseHtml,
                    subtitle: '',
                  ),
                ],
                selected: _format,
                onChanged: (value) => setState(() => _format = value),
              ),
              if (_format == HttpResponseFormat.json) ...[
                const SizedBox(height: AppSpacing.md),
                AppTextField(
                  controller: _jsonPath,
                  label: l10n.jsonPath,
                  hint: l10n.jsonPathHint,
                  mono: true,
                ),
              ],
              if (_format == HttpResponseFormat.html) ...[
                const SizedBox(height: AppSpacing.md),
                AppTextField(
                  controller: _selector,
                  label: l10n.htmlSelector,
                  hint: l10n.htmlSelectorHint,
                  mono: true,
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: AppTextField(
                      controller: _timeout,
                      label: l10n.timeout,
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: AppTextField(
                      controller: _maxChars,
                      label: l10n.maxResponseChars,
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              if (_error case final error?) ...[
                const SizedBox(height: AppSpacing.md),
                Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(onPressed: () => _save(l10n), child: Text(l10n.save)),
      ],
    );
  }

  void _save(DeclarativeHttpLocalizations l10n) {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = l10n.invalidName);
      return;
    }
    final method = _method.text.trim().toUpperCase();
    if (!const {'GET', 'POST', 'PUT', 'PATCH', 'DELETE'}.contains(method)) {
      setState(() => _error = l10n.invalidMethod);
      return;
    }
    final url = _url.text.trim();
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !uri.hasScheme ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      setState(() => _error = l10n.invalidUrl);
      return;
    }
    final bodyText = _body.text.trim();
    Object? body;
    if (bodyText.isNotEmpty) {
      if (bodyText.startsWith('{') || bodyText.startsWith('[')) {
        try {
          body = jsonDecode(bodyText);
        } on FormatException {
          setState(() => _error = l10n.invalidBody);
          return;
        }
      } else {
        body = bodyText;
      }
    }
    final Map<String, Object?> schema;
    try {
      final decoded = jsonDecode(_schema.text);
      if (decoded is! Map) throw const FormatException('not an object');
      schema = Map<String, Object?>.from(decoded);
    } on FormatException {
      setState(() => _error = l10n.invalidSchema);
      return;
    }
    final timeout = int.tryParse(_timeout.text.trim());
    if (timeout == null || timeout <= 0) {
      setState(() => _error = l10n.invalidTimeout);
      return;
    }
    final maxChars = int.tryParse(_maxChars.text.trim());
    if (maxChars == null || maxChars <= 0) {
      setState(() => _error = l10n.invalidMaxChars);
      return;
    }
    Navigator.of(context).pop(
      DeclarativeHttpTool(
        id: widget.id,
        title: title,
        description: _description.text.trim(),
        method: method,
        url: url,
        headers: _pairs(_headers.text),
        body: body,
        inputSchema: schema,
        timeoutSeconds: timeout,
        maxResponseChars: maxChars,
        responseFormat: _format,
        jsonPath: _format == HttpResponseFormat.json
            ? _jsonPath.text.trim()
            : null,
        htmlSelector: _format == HttpResponseFormat.html
            ? _selector.text.trim()
            : null,
      ),
    );
  }

  static Map<String, String> _pairs(String text) {
    final result = <String, String>{};
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      final chars = trimmed.characters;
      final separator = chars.toList().indexWhere((char) => char == '=');
      if (separator <= 0) continue;
      result[chars.take(separator).toString().trim()] = chars
          .skip(separator + 1)
          .toString()
          .trim();
    }
    return result;
  }

  static String _pairsText(Map<String, String>? values) => values == null
      ? ''
      : [for (final entry in values.entries) '${entry.key}=${entry.value}']
            .join('\n');
}

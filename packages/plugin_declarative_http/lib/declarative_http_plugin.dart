import 'dart:convert';

import 'package:app_ui/app_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:plugin_api/plugin_api.dart';
import 'package:plugin_api_ui/plugin_api_ui.dart';
import 'package:plugin_declarative_http/l10n/generated/declarative_http_localizations.dart';
import 'package:plugin_declarative_http_core/declarative_http_plugin.dart';
import 'package:uuid/uuid.dart';

/// Представление HTTP-плагина в настройках.
final class DeclarativeHttpPluginUi implements PluginUi {
  const DeclarativeHttpPluginUi();

  @override
  String get pluginId => 'declarative_http';

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
  Widget? buildSettings(BuildContext context, PluginSettings settings) =>
      DeclarativeHttpSettings(settings: settings);
}

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

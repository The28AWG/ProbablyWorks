import 'package:app_ui/app_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:plugin_api/plugin_api.dart';
import 'package:plugin_api_ui/plugin_api_ui.dart';
import 'package:plugin_declarative_commands/l10n/generated/declarative_commands_localizations.dart';
import 'package:uuid/uuid.dart';

/// Плагин фиксированных команд: каждая запись становится инструментом модели.
final class DeclarativeCommandsPlugin implements Plugin, PluginUi {
  const DeclarativeCommandsPlugin();

  @override
  String get id => 'declarative_commands';

  @override
  Set<String> get dependsOn => const {};

  @override
  bool get defaultEnabled => false;

  @override
  LocalizationsDelegate<dynamic> get localizations =>
      DeclarativeCommandsLocalizations.delegate;

  @override
  String titleOf(BuildContext context) =>
      DeclarativeCommandsLocalizations.of(context).pluginTitle;

  @override
  String descriptionOf(BuildContext context) =>
      DeclarativeCommandsLocalizations.of(context).pluginDescription;

  @override
  Future<List<PluginTool>> createTools(PluginSettings settings) async {
    final commands = await _readCommands(settings);
    return [
      for (final command in commands)
        PluginTool(
          name: command.id,
          title: command.title,
          description: command.description,
          inputSchema: const {
            'type': 'object',
            'properties': <String, Object?>{},
            'additionalProperties': false,
          },
          run: (arguments, host) => _run(command, host),
        ),
    ];
  }

  @override
  Widget? buildSettings(BuildContext context, PluginSettings settings) =>
      DeclarativeCommandsSettings(settings: settings);

  Future<PluginToolResult> _run(
    DeclarativeCommand command,
    PluginHost host,
  ) async {
    final result = await host.runCommand(
      command.executable,
      command.args,
      timeout: Duration(seconds: command.timeoutSeconds),
    );
    final text = result.output.trim();
    if (text.isNotEmpty) {
      return PluginToolResult(text, isError: result.isError);
    }
    return PluginToolResult(
      result.isError
          ? 'command failed with exit code ${result.exitCode ?? 'unknown'}'
          : 'ok',
      isError: result.isError,
    );
  }

  static Future<List<DeclarativeCommand>> _readCommands(
    PluginSettings settings,
  ) async {
    final raw = await settings.read();
    final commands = raw['commands'];
    if (commands is! List) return const [];
    final result = <DeclarativeCommand>[];
    for (final item in commands) {
      if (item is! Map) continue;
      final command = DeclarativeCommand.fromJson(item);
      if (command.id.isEmpty ||
          command.title.isEmpty ||
          command.executable.isEmpty) {
        continue;
      }
      result.add(command);
    }
    return result;
  }
}

/// Одна фиксированная команда плагина.
final class DeclarativeCommand {
  const DeclarativeCommand({
    required this.id,
    required this.title,
    required this.description,
    required this.executable,
    required this.args,
    required this.timeoutSeconds,
  });

  factory DeclarativeCommand.fromJson(Map json) => DeclarativeCommand(
    id: '${json['id'] ?? ''}',
    title: '${json['title'] ?? ''}',
    description: '${json['description'] ?? ''}',
    executable: '${json['executable'] ?? ''}',
    args: json['args'] is List
        ? [
            for (final arg in json['args'] as List)
              if (arg is String) arg,
          ]
        : const [],
    timeoutSeconds: json['timeoutSeconds'] is num
        ? (json['timeoutSeconds'] as num).toInt()
        : 30,
  );

  final String id;
  final String title;
  final String description;
  final String executable;
  final List<String> args;
  final int timeoutSeconds;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'description': description,
    'executable': executable,
    'args': args,
    'timeoutSeconds': timeoutSeconds,
  };

  DeclarativeCommand copyWith({
    String? id,
    String? title,
    String? description,
    String? executable,
    List<String>? args,
    int? timeoutSeconds,
  }) => DeclarativeCommand(
    id: id ?? this.id,
    title: title ?? this.title,
    description: description ?? this.description,
    executable: executable ?? this.executable,
    args: args ?? this.args,
    timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
  );
}

/// Экран настроек плагина. Живёт в пакете, поэтому использует app_ui и свою локализацию.
class DeclarativeCommandsSettings extends StatefulWidget {
  const DeclarativeCommandsSettings({required this.settings, super.key});

  final PluginSettings settings;

  @override
  State<DeclarativeCommandsSettings> createState() =>
      _DeclarativeCommandsSettingsState();
}

class _DeclarativeCommandsSettingsState
    extends State<DeclarativeCommandsSettings> {
  static const _uuid = Uuid();

  var _commands = <DeclarativeCommand>[];
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
      final list = raw['commands'];
      final commands = list is List
          ? [
              for (final item in list)
                if (item is Map) DeclarativeCommand.fromJson(item),
            ]
          : <DeclarativeCommand>[];
      if (!mounted) return;
      setState(() {
        _commands = commands;
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

  Future<void> _save(List<DeclarativeCommand> commands) async {
    await widget.settings.save({
      'version': 1,
      'commands': [for (final command in commands) command.toJson()],
    });
    if (!mounted) return;
    setState(() => _commands = commands);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = DeclarativeCommandsLocalizations.of(context);
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
              label: Text(l10n.addCommand),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          l10n.commandCount(_commands.length),
          style: Theme.of(context).textTheme.labelSmall,
        ),
        const SizedBox(height: AppSpacing.sm),
        if (_commands.isEmpty)
          AppEmptyState(
            icon: Icons.terminal_outlined,
            title: l10n.emptyTitle,
            message: l10n.emptyMessage,
          )
        else
          for (final command in _commands)
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
                            command.title,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          Text(
                            command.description.isEmpty
                                ? command.executable
                                : command.description,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          Text(
                            [command.executable, ...command.args].join(' '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.edit,
                      onPressed: () => _edit(context, command),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    IconButton(
                      tooltip: l10n.delete,
                      onPressed: () => _delete(context, command),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }

  Future<void> _edit(BuildContext context, DeclarativeCommand? command) async {
    final result = await showDialog<DeclarativeCommand>(
      context: context,
      builder: (_) =>
          _CommandDialog(command: command, id: command?.id ?? _uuid.v4()),
    );
    if (result == null || !mounted) return;
    final existing = _commands.indexWhere((item) => item.id == result.id);
    final next = [..._commands];
    if (existing < 0) {
      next.add(result);
    } else {
      next[existing] = result;
    }
    await _save(next);
  }

  Future<void> _delete(BuildContext context, DeclarativeCommand command) async {
    final l10n = DeclarativeCommandsLocalizations.of(context);
    final confirmed = await ConfirmDialog.confirm(
      context,
      title: l10n.deleteTitle,
      message: l10n.deleteConfirm(command.title),
      cancelLabel: l10n.cancel,
      confirmLabel: l10n.delete,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _save([
      for (final item in _commands)
        if (item.id != command.id) item,
    ]);
  }
}

class _CommandDialog extends StatefulWidget {
  const _CommandDialog({required this.command, required this.id});

  final DeclarativeCommand? command;
  final String id;

  @override
  State<_CommandDialog> createState() => _CommandDialogState();
}

class _CommandDialogState extends State<_CommandDialog> {
  late final _title = TextEditingController(text: widget.command?.title ?? '');
  late final _description = TextEditingController(
    text: widget.command?.description ?? '',
  );
  late final _executable = TextEditingController(
    text: widget.command?.executable ?? '',
  );
  late final _args = TextEditingController(
    text: widget.command?.args.join('\n') ?? '',
  );
  late final _timeout = TextEditingController(
    text: '${widget.command?.timeoutSeconds ?? 30}',
  );
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _executable.dispose();
    _args.dispose();
    _timeout.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = DeclarativeCommandsLocalizations.of(context);
    final editing = widget.command != null;
    return AlertDialog(
      title: Text(
        editing ? l10n.editCommand : l10n.newCommand,
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
              AppTextField(
                controller: _executable,
                label: l10n.executable,
                mono: true,
              ),
              const SizedBox(height: AppSpacing.md),
              AppTextField(
                controller: _args,
                label: l10n.arguments,
                hint: l10n.argumentsHint,
                minLines: 3,
                maxLines: 6,
                mono: true,
              ),
              const SizedBox(height: AppSpacing.md),
              AppTextField(
                controller: _timeout,
                label: l10n.timeout,
                keyboardType: TextInputType.number,
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

  void _save(DeclarativeCommandsLocalizations l10n) {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = l10n.invalidName);
      return;
    }
    final executable = _executable.text.trim();
    if (executable.isEmpty) {
      setState(() => _error = l10n.invalidExecutable);
      return;
    }
    final timeout = int.tryParse(_timeout.text.trim());
    if (timeout == null || timeout <= 0) {
      setState(() => _error = l10n.invalidTimeout);
      return;
    }
    Navigator.of(context).pop(
      DeclarativeCommand(
        id: widget.id,
        title: title,
        description: _description.text.trim(),
        executable: executable,
        args: [
          for (final line in _args.text.split('\n'))
            if (line.trim().isNotEmpty) line.trim(),
        ],
        timeoutSeconds: timeout,
      ),
    );
  }
}

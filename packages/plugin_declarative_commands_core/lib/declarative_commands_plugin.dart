import 'package:plugin_api/plugin_api.dart';

/// Плагин фиксированных команд: каждая запись становится инструментом модели.
final class DeclarativeCommandsPlugin implements Plugin {
  const DeclarativeCommandsPlugin();

  @override
  String get id => 'declarative_commands';

  @override
  Set<String> get dependsOn => const {};

  @override
  bool get defaultEnabled => false;

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

import 'package:plugin_api/plugin_api.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/exec/command_executor.dart';
import 'package:probably_works/agent/tools/tool_source.dart';
import 'package:probably_works/agent/tools/tool_types.dart';
import 'package:probably_works/core/util/workspace_path.dart';
import 'package:probably_works/host/shell_adapter.dart';
import 'package:probably_works/providers/ai/llm_port.dart';
import 'package:uuid/uuid.dart';

/// Инструменты одного включённого плагина.
final class PluginToolSource extends ToolSource {
  PluginToolSource({
    required this.plugin,
    required this.tools,
    required this.commands,
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
    final result = await tool.run(arguments, _PluginHost(context, commands));
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
    final base = 'plugin_${_slug(pluginId)}_${_slug(toolName)}';
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
  _PluginHost(this._context, this.commands);

  static const _uuid = Uuid();

  final ToolContext _context;
  final CommandExecutor commands;

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
      isError: outcome.status != ToolRunStatus.done,
    );
  }
}

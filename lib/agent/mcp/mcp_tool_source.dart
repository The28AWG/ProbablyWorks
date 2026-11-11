import 'package:probably_works/agent/mcp/mcp_client_manager.dart';
import 'package:probably_works/agent/tools/tool_name.dart';
import 'package:probably_works/agent/tools/tool_source.dart';
import 'package:probably_works/agent/tools/tool_types.dart';
import 'package:probably_works/core/domain/mcp_server.dart';
import 'package:probably_works/providers/ai/llm_port.dart';

/// Инструменты одного MCP-сервера для модели.
///
/// Имена всегда неймспейсятся: `mcp_<server>_<tool>`. Так два сервера могут
/// объявить одинаковый инструмент, а политика и журнал видят точное имя.
final class McpToolSource extends ToolSource {
  McpToolSource({
    required this.server,
    required this.manager,
    required List<McpToolInfo> tools,
  }) {
    final used = <String>{};
    for (final tool in tools) {
      final modelName = _uniqueName(server, tool.name, used);
      _tools[modelName] = tool;
    }
    specs = List.unmodifiable([
      for (final entry in _tools.entries)
        LlmToolSpec(
          name: entry.key,
          description:
              '[${server.name}] '
              '${entry.value.description ?? entry.value.displayName}',
          parameters: entry.value.inputSchema,
        ),
    ]);
  }

  final McpServerConfig server;
  final McpClientManager manager;
  final _tools = <String, McpToolInfo>{};

  @override
  late final List<LlmToolSpec> specs;

  @override
  String get id => 'mcp:${server.id}';

  @override
  bool get mutatesHost => true;

  @override
  Future<ToolResult> call(
    LlmToolCall call,
    Map<String, dynamic> arguments,
    ToolContext context,
  ) async {
    final tool = _tools[call.name];
    if (tool == null) {
      return ToolResult('unknown MCP tool: ${call.name}', isError: true);
    }
    final output = await manager.callTool(server, tool.name, arguments);
    return ToolResult(output.text, isError: output.isError);
  }

  @override
  String summaryFor(LlmToolCall call, Map<String, dynamic> arguments) {
    final tool = _tools[call.name];
    return '${server.name}: ${tool?.displayName ?? call.name}';
  }

  @override
  String reasonFor(LlmToolCall call) => 'MCP tool from ${server.name}';

  static String _uniqueName(
    McpServerConfig server,
    String toolName,
    Set<String> used,
  ) {
    final base = fitToolName('mcp_${_slug(server.id)}_${_slug(toolName)}');
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
      final char = String.fromCharCode(rune);
      final safe =
          (rune >= 0x30 && rune <= 0x39) ||
          (rune >= 0x41 && rune <= 0x5A) ||
          (rune >= 0x61 && rune <= 0x7A);
      buffer.write(safe ? char : '_');
    }
    final slug = buffer.toString();
    return slug.isEmpty ? 'x' : slug;
  }
}

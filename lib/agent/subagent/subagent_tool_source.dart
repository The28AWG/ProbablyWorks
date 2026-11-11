import 'package:characters/characters.dart';
import 'package:probably_works/agent/subagent/subagent_manager.dart';
import 'package:probably_works/agent/tools/tool_catalog.dart';
import 'package:probably_works/agent/tools/tool_source.dart';
import 'package:probably_works/agent/tools/tool_types.dart';
import 'package:probably_works/providers/ai/llm_port.dart';

/// Запускает фонового субагента. Вызов возвращается сразу с id запуска.
final class DelegateTaskToolSource extends ToolSource {
  DelegateTaskToolSource(this._manager);

  final SubagentManager _manager;

  @override
  String get id => 'subagent_delegate';

  @override
  bool get mutatesHost => true;

  @override
  List<LlmToolSpec> get specs => const [
    LlmToolSpec(
      name: ToolNames.delegateTask,
      description:
          'Start a background subagent with its own context. The call returns immediately with a run id; '
          'a short completion event is delivered later. Use wait_subagent to wait explicitly and '
          'read_subagent_report to read a long report in chunks. The task is a full self-contained brief: '
          'goal, constraints, context, acceptance criteria and output format; it may be very long. '
          'model may be "parent" or "default"; an arbitrary model id is not allowed.',
      parameters: {
        'type': 'object',
        'properties': {
          'title': {
            'type': 'string',
            'description': 'Short one-line title for the card and reports.',
          },
          'task': {
            'type': 'string',
            'description':
                'Full self-contained brief: goal, constraints, steps, acceptance criteria and output format. '
                'The subagent does not see the parent chat history, so include everything it needs. Long text is allowed.',
          },
          'context': {
            'type': 'string',
            'description': 'Optional additional context: facts, excerpts, file paths or prior findings.',
          },
          'model': {
            'type': 'string',
            'enum': ['parent', 'default'],
            'description':
                'parent uses the parent chat model; default uses the configured subagent model, '
                'or the parent model when no subagent model is set.',
          },
        },
        'required': ['title', 'task'],
      },
    ),
  ];

  @override
  Future<ToolResult> call(
    LlmToolCall call,
    Map<String, dynamic> arguments,
    ToolContext context,
  ) async {
    final title = arguments['title'];
    final task = arguments['task'];
    if (title is! String || title.trim().isEmpty) {
      return const ToolResult('title is required', isError: true);
    }
    if (task is! String || task.trim().isEmpty) {
      return const ToolResult('task is required', isError: true);
    }
    final model = arguments['model'];
    final extra = arguments['context'];
    final run = await _manager.start(
      parent: context.chat,
      title: title,
      task: task,
      context: extra is String ? extra : null,
      modelStrategy: model is String ? model : null,
    );
    return ToolResult(
      'subagent started: ${run.id}\n'
      'title: ${run.title}\n'
      'model: ${run.model}\n'
      'Use wait_subagent to wait and read_subagent_report to read the final report.',
    );
  }

  @override
  String summaryFor(LlmToolCall call, Map<String, dynamic> arguments) =>
      'delegate: ${arguments['title'] ?? ''}';

  @override
  String reasonFor(LlmToolCall call) => 'start a background subagent';
}

/// Ждёт завершения субагента и возвращает его результат.
final class WaitSubagentToolSource extends ToolSource {
  WaitSubagentToolSource(this._manager);

  final SubagentManager _manager;

  @override
  String get id => 'subagent_wait';

  @override
  bool get mutatesHost => false;

  @override
  List<LlmToolSpec> get specs => const [
    LlmToolSpec(
      name: ToolNames.waitSubagent,
      description:
          'Wait for a background subagent to finish and return its final result. '
          'If it is already finished, returns the result immediately.',
      parameters: {
        'type': 'object',
        'properties': {
          'runId': {
            'type': 'string',
            'description': 'The id returned by delegate_task.',
          },
        },
        'required': ['runId'],
      },
    ),
    LlmToolSpec(
      name: ToolNames.readSubagentReport,
      description:
          'Read the final report of a subagent. Long reports are returned in chunks; '
          'if the footer says there is more, call again with the returned offset.',
      parameters: {
        'type': 'object',
        'properties': {
          'runId': {'type': 'string'},
          'offset': {
            'type': 'integer',
            'description': 'Character offset to start from (default 0)',
          },
          'limit': {
            'type': 'integer',
            'description': 'Max characters (default 20000, max 60000)',
          },
        },
        'required': ['runId'],
      },
    ),
  ];

  @override
  Future<ToolResult> call(
    LlmToolCall call,
    Map<String, dynamic> arguments,
    ToolContext context,
  ) async {
    final runId = arguments['runId'];
    if (runId is! String || runId.isEmpty) {
      return const ToolResult('runId is required', isError: true);
    }
    if (call.name == ToolNames.readSubagentReport) {
      final offset = arguments['offset'] is num
          ? (arguments['offset'] as num).toInt()
          : 0;
      final limit = arguments['limit'] is num
          ? (arguments['limit'] as num).toInt().clamp(1, 60000)
          : 20000;
      return ToolResult(
        _manager.readReport(runId, offset: offset, limit: limit),
      );
    }
    final result = await _manager.wait(runId);
    return ToolResult(
      'subagent ${result.status.name}\n'
      'report_chars: ${result.text.characters.length}\n'
      'Use read_subagent_report with runId to read it.',
      isError: result.isError,
    );
  }

  @override
  String summaryFor(LlmToolCall call, Map<String, dynamic> arguments) =>
      '${call.name} ${arguments['runId'] ?? ''}';

  @override
  String reasonFor(LlmToolCall call) => 'wait for a background subagent';
}

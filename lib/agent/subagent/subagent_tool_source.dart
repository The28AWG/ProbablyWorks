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
          'the final result is delivered as an event. Use wait_subagent to wait for it explicitly. '
          'model may be "parent" or "default"; an arbitrary model id is not allowed.',
      parameters: {
        'type': 'object',
        'properties': {
          'task': {
            'type': 'string',
            'description': 'Complete task for the subagent.',
          },
          'model': {
            'type': 'string',
            'enum': ['parent', 'default'],
            'description':
                'parent uses the parent chat model; default uses the configured subagent model, '
                'or the parent model when no subagent model is set.',
          },
        },
        'required': ['task'],
      },
    ),
  ];

  @override
  Future<ToolResult> call(
    LlmToolCall call,
    Map<String, dynamic> arguments,
    ToolContext context,
  ) async {
    final task = arguments['task'];
    if (task is! String || task.trim().isEmpty) {
      return const ToolResult('task is required', isError: true);
    }
    final model = arguments['model'];
    final run = await _manager.start(
      parent: context.chat,
      task: task,
      modelStrategy: model is String ? model : null,
    );
    return ToolResult(
      'subagent started: ${run.id}\n'
      'model: ${run.model}\n'
      'Use wait_subagent with this id to wait for the result.',
    );
  }

  @override
  String summaryFor(LlmToolCall call, Map<String, dynamic> arguments) =>
      'delegate: ${arguments['task'] ?? ''}';

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
    final result = await _manager.wait(runId);
    return ToolResult(
      'subagent ${result.status.name}\n${result.text}',
      isError: result.isError,
    );
  }

  @override
  String summaryFor(LlmToolCall call, Map<String, dynamic> arguments) =>
      'wait for subagent ${arguments['runId'] ?? ''}';

  @override
  String reasonFor(LlmToolCall call) => 'wait for a background subagent';
}

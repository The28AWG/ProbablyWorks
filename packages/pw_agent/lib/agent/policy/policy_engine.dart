import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/policy/command_classifier.dart';
import 'package:pw_agent/agent/tools/tool_catalog.dart';

enum PolicyDecision { allow, ask, deny }

/// Решение Policy для вызова инструмента. Стоит между ToolHandler и HostRuntime.
/// AGENTS.md и skills не могут его переопределить.
class PolicyEngine {
  const PolicyEngine({required this.classifier, required this.mode});

  final CommandClassifier classifier;
  final PolicyMode mode;

  /// Инструменты, которые читают или меняют только состояние приложения.
  static const _safeTools = {
    'host_info',
    'list_dir',
    'read_file',
    'grep',
    'which',
    'stat_path',
    'glob',
    'list_skills',
    'load_skill',
    'set_goal',
    'update_plan',
    'pin_fact',
    'unpin_fact',
    'finish',
    'list_state_revisions',
    'get_state_revision',
    'chat_history_search',
    'list_runs',
    'read_run_output',
    'ask_user',
    ToolNames.waitSubagent,
    ToolNames.readSubagentReport,
    // Self-инструменты только читают приложение или проверяют подключение.
    ToolNames.hostList,
    ToolNames.settingsRead,
    ToolNames.hostTest,
    ToolNames.hostDiagnose,
  };

  /// Self-записи: как write_file, спрашивают в Ask и выполняются в YOLO.
  static const _selfWriteTools = {
    ToolNames.hostAdd,
    ToolNames.hostUpdate,
    ToolNames.settingsUpdate,
  };

  /// Общая память проекта: меняется только с подтверждением, даже в YOLO.
  static const _alwaysAskTools = {
    ToolNames.pinProjectFact,
    ToolNames.unpinProjectFact,
  };

  PolicyDecision decide(String toolName, Map<String, dynamic> args) {
    if (_alwaysAskTools.contains(toolName)) return PolicyDecision.ask;
    if (_safeTools.contains(toolName)) return PolicyDecision.allow;
    if (toolName == 'run_command') {
      final command = args['command'] as String? ?? '';
      return _fromRisk(classifier.classify(command).risk);
    }
    if (toolName == 'write_file' ||
        toolName == 'edit_file' ||
        toolName == 'apply_patch' ||
        toolName == 'delete_file' ||
        toolName == 'move_path' ||
        toolName == 'copy_path' ||
        toolName == 'make_dir' ||
        toolName == 'stop_run' ||
        _selfWriteTools.contains(toolName)) {
      return mode == PolicyMode.yolo
          ? PolicyDecision.allow
          : PolicyDecision.ask;
    }
    return PolicyDecision.ask;
  }

  /// Причина для карточки approve и для модели.
  String reasonFor(String toolName, Map<String, dynamic> args) {
    if (_alwaysAskTools.contains(toolName)) {
      return 'project facts are shared with every chat in this project';
    }
    if (toolName == 'run_command') {
      return classifier.classify(args['command'] as String? ?? '').reason;
    }
    if (_selfWriteTools.contains(toolName)) return 'app settings change';
    if (toolName == 'stop_run') return 'process control';
    return 'write operation';
  }

  PolicyDecision _fromRisk(CommandRisk risk) => switch (risk) {
    CommandRisk.auto => PolicyDecision.allow,
    CommandRisk.ask =>
      mode == PolicyMode.yolo ? PolicyDecision.allow : PolicyDecision.ask,
    CommandRisk.deny => PolicyDecision.deny,
  };
}

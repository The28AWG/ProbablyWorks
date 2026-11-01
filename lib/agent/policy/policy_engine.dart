import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/policy/command_classifier.dart';

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
    'ask_user',
  };

  PolicyDecision decide(String toolName, Map<String, dynamic> args) {
    if (_safeTools.contains(toolName)) return PolicyDecision.allow;
    if (toolName == 'run_command') {
      final command = args['command'] as String? ?? '';
      return _fromRisk(classifier.classify(command).risk);
    }
    if (toolName == 'write_file' || toolName == 'edit_file') {
      return mode == PolicyMode.yolo
          ? PolicyDecision.allow
          : PolicyDecision.ask;
    }
    return PolicyDecision.ask;
  }

  /// Причина для карточки approve и для модели.
  String reasonFor(String toolName, Map<String, dynamic> args) {
    if (toolName == 'run_command') {
      return classifier.classify(args['command'] as String? ?? '').reason;
    }
    return 'write operation';
  }

  PolicyDecision _fromRisk(CommandRisk risk) => switch (risk) {
    CommandRisk.auto => PolicyDecision.allow,
    CommandRisk.ask =>
      mode == PolicyMode.yolo ? PolicyDecision.allow : PolicyDecision.ask,
    CommandRisk.deny => PolicyDecision.deny,
  };
}

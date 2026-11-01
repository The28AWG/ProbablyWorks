import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/policy/command_classifier.dart';
import 'package:probably_works/agent/policy/policy_engine.dart';
import 'package:probably_works/core/data/settings_repository.dart';

void main() {
  final classifier = CommandClassifier(
    denylist: SettingsRepository.defaultDenylist,
  );

  PolicyEngine engine(PolicyMode mode) =>
      PolicyEngine(classifier: classifier, mode: mode);

  group('CommandClassifier', () {
    test('read-only commands are auto', () {
      expect(classifier.classify('ls -la /tmp').risk, CommandRisk.auto);
      expect(classifier.classify('git status').risk, CommandRisk.auto);
      expect(classifier.classify('/bin/cat README.md').risk, CommandRisk.auto);
    });

    test('unknown and write commands are ask', () {
      expect(classifier.classify('mkdir build').risk, CommandRisk.ask);
      expect(classifier.classify('git commit -m x').risk, CommandRisk.ask);
    });

    test('pipes, redirects and substitutions require approval', () {
      expect(classifier.classify('ls | wc -l').risk, CommandRisk.ask);
      expect(classifier.classify('cat a > b').risk, CommandRisk.ask);
      expect(classifier.classify('echo \$(id)').risk, CommandRisk.ask);
    });

    test('privilege escalation is always deny', () {
      expect(classifier.classify('sudo ls').risk, CommandRisk.deny);
      expect(classifier.classify('su -c id').risk, CommandRisk.deny);
      expect(classifier.classify('ls && pkexec id').risk, CommandRisk.deny);
    });

    test('denylist patterns are deny', () {
      expect(classifier.classify('rm -rf /').risk, CommandRisk.deny);
    });

    test('empty command is deny', () {
      expect(classifier.classify('   ').risk, CommandRisk.deny);
    });
  });

  group('PolicyEngine', () {
    test('ask mode asks for write and unknown commands', () {
      expect(
        engine(PolicyMode.ask).decide('run_command', {'command': 'mkdir x'}),
        PolicyDecision.ask,
      );
      expect(
        engine(PolicyMode.ask).decide('write_file', {'path': 'a'}),
        PolicyDecision.ask,
      );
    });

    test('read-only tools never ask', () {
      expect(
        engine(PolicyMode.ask).decide('read_file', {'path': 'a'}),
        PolicyDecision.allow,
      );
      expect(
        engine(PolicyMode.ask).decide('run_command', {'command': 'ls'}),
        PolicyDecision.allow,
      );
    });

    test('yolo allows ask-level actions but never deny', () {
      expect(
        engine(PolicyMode.yolo).decide('run_command', {'command': 'mkdir x'}),
        PolicyDecision.allow,
      );
      expect(
        engine(PolicyMode.yolo).decide('write_file', {'path': 'a'}),
        PolicyDecision.allow,
      );
      expect(
        engine(PolicyMode.yolo).decide('run_command', {'command': 'sudo ls'}),
        PolicyDecision.deny,
      );
      expect(
        engine(PolicyMode.yolo).decide('run_command', {'command': 'rm -rf /'}),
        PolicyDecision.deny,
      );
    });
  });
}

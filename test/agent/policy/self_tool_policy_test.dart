import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/policy/command_classifier.dart';
import 'package:pw_agent/agent/policy/policy_engine.dart';
import 'package:pw_agent/agent/tools/tool_catalog.dart';
import 'package:pw_agent/core/data/settings_repository.dart';

void main() {
  final classifier = CommandClassifier(
    denylist: SettingsRepository.defaultDenylist,
  );

  PolicyEngine engine(PolicyMode mode) =>
      PolicyEngine(classifier: classifier, mode: mode);

  test('self read tools never ask', () {
    for (final name in [
      ToolNames.hostList,
      ToolNames.settingsRead,
      ToolNames.hostTest,
      ToolNames.hostDiagnose,
    ]) {
      expect(
        engine(PolicyMode.ask).decide(name, {}),
        PolicyDecision.allow,
        reason: name,
      );
    }
  });

  test('self write tools ask in Ask mode and run in YOLO', () {
    for (final name in [
      ToolNames.hostAdd,
      ToolNames.hostUpdate,
      ToolNames.settingsUpdate,
    ]) {
      expect(
        engine(PolicyMode.ask).decide(name, {}),
        PolicyDecision.ask,
        reason: name,
      );
      expect(
        engine(PolicyMode.yolo).decide(name, {}),
        PolicyDecision.allow,
        reason: name,
      );
    }
  });

  test('self write reason names the app settings change', () {
    expect(
      engine(PolicyMode.ask).reasonFor(ToolNames.settingsUpdate, {}),
      'app settings change',
    );
  });
}

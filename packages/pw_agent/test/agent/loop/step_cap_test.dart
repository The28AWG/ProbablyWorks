import 'package:pw_agent/agent/loop/step_cap.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/providers/ai/llm_provider_meta.dart';
import 'package:test/test.dart';

const _standard = LlmProviderDescriptor(id: 'cloud', label: 'Cloud');
const _economical = LlmProviderDescriptor(
  id: 'local',
  label: 'Local',
  stepPolicy: ProviderStepPolicy.economical,
);

void main() {
  group('effectiveStepCap', () {
    test('standard provider has no ceiling when the global cap is off', () {
      final limits = AppLimits.defaults.copyWith(maxAgentSteps: 0);
      expect(effectiveStepCap(limits: limits, provider: _standard), isNull);
    });

    test('standard provider uses the global emergency ceiling', () {
      final limits = AppLimits.defaults.copyWith(maxAgentSteps: 120);
      expect(effectiveStepCap(limits: limits, provider: _standard), 120);
    });

    test('economical provider is always finite', () {
      final limits = AppLimits.defaults.copyWith(
        maxAgentSteps: 0,
        economicalMaxAgentSteps: 30,
      );
      expect(effectiveStepCap(limits: limits, provider: _economical), 30);
    });

    test('the stricter ceiling wins for an economical provider', () {
      final limits = AppLimits.defaults.copyWith(
        maxAgentSteps: 12,
        economicalMaxAgentSteps: 30,
      );
      expect(effectiveStepCap(limits: limits, provider: _economical), 12);
    });

    test('unknown provider follows the standard policy', () {
      final limits = AppLimits.defaults.copyWith(maxAgentSteps: 0);
      expect(effectiveStepCap(limits: limits, provider: null), isNull);
    });
  });
}

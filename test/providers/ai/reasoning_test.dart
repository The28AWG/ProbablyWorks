import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/providers/ai/reasoning.dart';

void main() {
  test('auto and inherit do not send an effort', () {
    expect(
      resolveReasoning(
        capability: const LlmReasoningCapability(supported: true),
        preference: ReasoningPreference.auto,
      ),
      isNull,
    );
    expect(
      resolveReasoning(
        capability: const LlmReasoningCapability(supported: true),
        preference: ReasoningPreference.inherit,
      ),
      isNull,
    );
  });

  test('an unknown capability sends the explicit effort', () {
    expect(
      resolveReasoning(capability: null, preference: ReasoningPreference.high),
      ReasoningEffort.high,
    );
    expect(
      resolveReasoning(
        capability: const LlmReasoningCapability(),
        preference: ReasoningPreference.high,
      ),
      ReasoningEffort.high,
    );
  });

  test('a model without reasoning omits the effort', () {
    expect(
      resolveReasoning(
        capability: const LlmReasoningCapability(supported: false),
        preference: ReasoningPreference.high,
      ),
      isNull,
    );
  });

  test('mandatory reasoning replaces none with the model default', () {
    expect(
      resolveReasoning(
        capability: const LlmReasoningCapability(
          supported: true,
          mandatory: true,
          defaultEffort: ReasoningEffort.medium,
        ),
        preference: ReasoningPreference.none,
      ),
      ReasoningEffort.medium,
    );
  });

  test('an unsupported effort is lowered to the nearest supported', () {
    expect(
      resolveReasoning(
        capability: const LlmReasoningCapability(
          supported: true,
          efforts: [
            ReasoningEffort.minimal,
            ReasoningEffort.low,
            ReasoningEffort.medium,
          ],
        ),
        preference: ReasoningPreference.high,
      ),
      ReasoningEffort.medium,
    );
  });

  test('when nothing lower is supported the lowest is used', () {
    expect(
      resolveReasoning(
        capability: const LlmReasoningCapability(
          supported: true,
          efforts: [ReasoningEffort.high, ReasoningEffort.max],
        ),
        preference: ReasoningPreference.low,
      ),
      ReasoningEffort.high,
    );
  });

  test('utility reasoning is off when allowed and default when mandatory', () {
    expect(
      resolveUtilityReasoning(const LlmReasoningCapability(supported: true)),
      ReasoningEffort.none,
    );
    expect(
      resolveUtilityReasoning(
        const LlmReasoningCapability(
          supported: true,
          mandatory: true,
          defaultEffort: ReasoningEffort.low,
        ),
      ),
      ReasoningEffort.low,
    );
    expect(
      resolveUtilityReasoning(const LlmReasoningCapability(supported: false)),
      isNull,
    );
  });

  test('preference parsing falls back to auto', () {
    expect(ReasoningPreference.parse('high'), ReasoningPreference.high);
    expect(ReasoningPreference.parse('unknown'), ReasoningPreference.auto);
    expect(ReasoningPreference.parse(null), ReasoningPreference.auto);
    expect(
      ReasoningPreference.parse(
        'missing',
        fallback: ReasoningPreference.inherit,
      ),
      ReasoningPreference.inherit,
    );
  });

  test('capability JSON round trip keeps the known fields', () {
    const capability = LlmReasoningCapability(
      supported: true,
      efforts: [ReasoningEffort.low, ReasoningEffort.high],
      defaultEffort: ReasoningEffort.low,
      mandatory: true,
      supportsMaxTokens: true,
    );
    final decoded = LlmReasoningCapability.fromJson(capability.toJson());
    expect(decoded, capability);
  });

  test('broken capability JSON is read as unknown', () {
    expect(LlmReasoningCapability.fromJson(null), isNull);
    expect(LlmReasoningCapability.fromJson('bad'), isNull);
    expect(
      LlmReasoningCapability.fromJson({
        'supported': 'yes',
        'efforts': ['low', 'bogus'],
      }),
      const LlmReasoningCapability(efforts: [ReasoningEffort.low]),
    );
  });
}

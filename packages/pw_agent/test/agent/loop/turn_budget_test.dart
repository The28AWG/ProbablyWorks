import 'package:pw_agent/agent/loop/turn_budget.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:test/test.dart';

void main() {
  final startedAt = DateTime.utc(2026, 1, 1, 12);

  group('TurnBudget', () {
    test('disabled budgets never stop the turn', () {
      final budget = TurnBudget(
        limits: AppLimits.defaults,
        startedAt: startedAt,
      )..add(promptTokens: 1000000, completionTokens: 1000000);

      expect(budget.exceededAt(startedAt), isNull);
    });

    test('token budget counts prompt and completion together', () {
      final budget = TurnBudget(
        limits: AppLimits.defaults.copyWith(maxTurnTokens: 100),
        startedAt: startedAt,
      )..add(promptTokens: 60, completionTokens: 40);

      expect(budget.tokens, 100);
      expect(budget.exceededAt(startedAt), contains('token budget'));
    });

    test('cost budget uses the accumulated estimate', () {
      final budget = TurnBudget(
        limits: AppLimits.defaults.copyWith(maxTurnCostUsd: 0.01),
        startedAt: startedAt,
      )..add(promptTokens: 1, completionTokens: 1, costUsd: 0.02);

      expect(budget.exceededAt(startedAt), contains('cost budget'));
    });

    test('unknown price does not spend the cost budget', () {
      final budget = TurnBudget(
        limits: AppLimits.defaults.copyWith(maxTurnCostUsd: 0.01),
        startedAt: startedAt,
      )..add(promptTokens: 1, completionTokens: 1);

      expect(budget.costUsd, 0);
      expect(budget.exceededAt(startedAt), isNull);
    });

    test('wall clock budget is checked against the turn start', () {
      final budget = TurnBudget(
        limits: AppLimits.defaults.copyWith(
          turnMaxWallClock: const Duration(minutes: 1),
        ),
        startedAt: startedAt,
      );

      expect(
        budget.exceededAt(startedAt.add(const Duration(seconds: 59))),
        isNull,
      );
      expect(
        budget.exceededAt(startedAt.add(const Duration(minutes: 1))),
        contains('time budget'),
      );
    });
  });
}

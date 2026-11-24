import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/agent/loop/prompt_queue.dart';
import 'package:pw_agent/core/config/app_limits.dart';

void main() {
  group('PromptQueue', () {
    test('soft drain keeps order and empties the queue', () {
      final queue = PromptQueue()
        ..enqueue(const QueuedPrompt.user('first'))
        ..enqueue(const QueuedPrompt.event('background done'));

      final drained = queue.drain();

      expect([for (final p in drained) p.text], ['first', 'background done']);
      expect(drained.last.isEvent, isTrue);
      expect(queue.isEmpty, isTrue);
    });

    test('send now goes first and keeps the rest queued', () {
      final queue = PromptQueue()
        ..enqueue(const QueuedPrompt.user('later'))
        ..enqueueFirst(const QueuedPrompt.user('now'));

      expect([for (final p in queue.items) p.text], ['now', 'later']);
    });

    test('every queued element gets a stable unique id', () {
      final queue = PromptQueue()
        ..enqueue(const QueuedPrompt.user('a'))
        ..enqueue(const QueuedPrompt.user('a'))
        ..enqueue(const QueuedPrompt.event('background done'));

      final ids = [for (final item in queue.items) item.id];
      expect(ids, everyElement(isNotEmpty));
      expect(ids.toSet(), hasLength(3));
    });

    test('takeById removes exactly the addressed item and keeps the order', () {
      final queue = PromptQueue()
        ..enqueue(const QueuedPrompt.user('a'))
        ..enqueue(const QueuedPrompt.user('b'))
        ..enqueue(const QueuedPrompt.user('c'));
      final middle = queue.items[1].id;

      expect(queue.takeById(middle)?.text, 'b');
      expect([for (final p in queue.items) p.text], ['a', 'c']);
      expect(queue.takeById(middle), isNull);
    });

    test('promoteById moves the same item and ignores a missing id', () {
      final queue = PromptQueue()
        ..enqueue(const QueuedPrompt.user('a'))
        ..enqueue(const QueuedPrompt.user('b'))
        ..enqueue(const QueuedPrompt.user('c'));
      final last = queue.items.last;

      expect(queue.promoteById(last.id), isTrue);
      expect(queue.items.first.id, last.id);
      expect([for (final p in queue.items) p.text], ['c', 'a', 'b']);
      expect(queue.promoteById('missing'), isFalse);
      expect(queue.items.first.text, 'c');
      expect(queue.items.last.text, 'b');
    });
  });

  group('AppLimits', () {
    test('defaults serialize and parse back to the same values', () {
      final parsed = AppLimits.parse(AppLimits.defaults.toJson());
      expect(
        parsed.foregroundExecTimeout,
        AppLimits.defaults.foregroundExecTimeout,
      );
      expect(parsed.maxAgentSteps, AppLimits.defaults.maxAgentSteps);
      expect(
        parsed.economicalMaxAgentSteps,
        AppLimits.defaults.economicalMaxAgentSteps,
      );
      expect(parsed.maxTurnTokens, AppLimits.defaults.maxTurnTokens);
      expect(parsed.maxTurnCostUsd, AppLimits.defaults.maxTurnCostUsd);
      expect(parsed.turnMaxWallClock, AppLimits.defaults.turnMaxWallClock);
      expect(
        parsed.progressRepeatLimit,
        AppLimits.defaults.progressRepeatLimit,
      );
      expect(parsed.logOutputDbBytes, AppLimits.defaults.logOutputDbBytes);
      expect(
        parsed.toolOutputKeepSteps,
        AppLimits.defaults.toolOutputKeepSteps,
      );
      expect(
        parsed.toolOutputPreviewChars,
        AppLimits.defaults.toolOutputPreviewChars,
      );
    });

    test('tool output masking limits survive JSON and reject negatives', () {
      final parsed = AppLimits.parse(
        '{"toolOutputKeepSteps": 2, "toolOutputPreviewChars": 0}',
      );
      expect(parsed.toolOutputKeepSteps, 2);
      // Ноль допустим: он оставляет только маркер без начала вывода.
      expect(parsed.toolOutputPreviewChars, 0);
      expect(
        () => AppLimits.parse('{"toolOutputKeepSteps": -1}'),
        throwsFormatException,
      );
      expect(
        () => AppLimits.parse('{"toolOutputPreviewChars": -1}'),
        throwsFormatException,
      );
    });

    test('overrides apply and unknown keys are ignored', () {
      final parsed = AppLimits.parse(
        '{"maxAgentSteps": 40, "foregroundExecTimeoutSeconds": 90, "unknown": true}',
      );
      expect(parsed.maxAgentSteps, 40);
      expect(parsed.foregroundExecTimeout, const Duration(seconds: 90));
    });

    test('zero disables the step ceiling but not the economical one', () {
      final parsed = AppLimits.parse(
        '{"maxAgentSteps": 0, "economicalMaxAgentSteps": 12}',
      );
      expect(parsed.maxAgentSteps, 0);
      expect(parsed.economicalMaxAgentSteps, 12);
      expect(
        () => AppLimits.parse('{"economicalMaxAgentSteps": 0}'),
        throwsFormatException,
      );
    });

    test('turn budgets survive JSON and zero means disabled', () {
      final parsed = AppLimits.parse(
        '{"maxTurnTokens": 1200, "maxTurnCostUsd": 1.5, '
        '"turnMaxWallClockSeconds": 900}',
      );
      expect(parsed.maxTurnTokens, 1200);
      expect(parsed.maxTurnCostUsd, 1.5);
      expect(parsed.turnMaxWallClock, const Duration(minutes: 15));
      expect(
        AppLimits.parse(parsed.toJson()).turnMaxWallClock,
        parsed.turnMaxWallClock,
      );

      final disabled = AppLimits.parse(
        '{"maxTurnTokens": 0, "maxTurnCostUsd": 0, '
        '"turnMaxWallClockSeconds": 0}',
      );
      expect(disabled.maxTurnTokens, 0);
      expect(disabled.maxTurnCostUsd, 0);
      expect(disabled.turnMaxWallClock, Duration.zero);
    });

    test('negative budgets are rejected', () {
      expect(
        () => AppLimits.parse('{"maxTurnTokens": -1}'),
        throwsFormatException,
      );
      expect(
        () => AppLimits.parse('{"maxTurnCostUsd": -0.1}'),
        throwsFormatException,
      );
      expect(
        () => AppLimits.parse('{"turnMaxWallClockSeconds": -1}'),
        throwsFormatException,
      );
      expect(
        () => AppLimits.parse('{"progressRepeatLimit": 0}'),
        throwsFormatException,
      );
    });

    test('context ratios and reserve survive JSON', () {
      final parsed = AppLimits.parse(
        '{"softContextRatio": 0.5, "hardContextRatio": 0.8, '
        '"contextReserveTokens": 12000}',
      );
      expect(parsed.softContextRatio, 0.5);
      expect(parsed.hardContextRatio, 0.8);
      expect(parsed.contextReserveTokens, 12000);
      expect(
        AppLimits.parse(parsed.toJson()).contextReserveTokens,
        parsed.contextReserveTokens,
      );
      expect(
        AppLimits.parse('{"contextReserveTokens": 0}').contextReserveTokens,
        0,
      );
    });

    test('invalid context ratios are rejected', () {
      expect(
        () => AppLimits.parse('{"softContextRatio": 1.2}'),
        throwsFormatException,
      );
      expect(
        () => AppLimits.parse(
          '{"softContextRatio": 0.9, "hardContextRatio": 0.5}',
        ),
        throwsFormatException,
      );
    });

    test('invalid values are rejected by parse', () {
      expect(
        () => AppLimits.parse('{"maxAgentSteps": -1}'),
        throwsFormatException,
      );
      expect(() => AppLimits.parse('[1,2]'), throwsFormatException);
      expect(() => AppLimits.parse('not json'), throwsFormatException);
    });

    test('fromJson falls back to defaults for broken stored values', () {
      expect(
        AppLimits.fromJson('{broken').maxAgentSteps,
        AppLimits.defaults.maxAgentSteps,
      );
    });
  });
}

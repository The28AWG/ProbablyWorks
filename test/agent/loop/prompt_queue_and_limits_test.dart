import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/agent/loop/prompt_queue.dart';
import 'package:probably_works/core/config/app_limits.dart';

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

    test('takeAt returns the item and keeps the order of the rest (edit and remove from queue)', () {
      final queue = PromptQueue()
        ..enqueue(const QueuedPrompt.user('a'))
        ..enqueue(const QueuedPrompt.user('b'))
        ..enqueue(const QueuedPrompt.user('c'));

      expect(queue.takeAt(1)?.text, 'b');
      expect([for (final p in queue.items) p.text], ['a', 'c']);
      expect(queue.takeAt(9), isNull);
    });

    test('remove ignores out-of-range indexes', () {
      final queue = PromptQueue()
        ..enqueue(const QueuedPrompt.user('a'))
        ..remove(5)
        ..remove(0);
      expect(queue.isEmpty, isTrue);
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
      expect(parsed.logOutputDbBytes, AppLimits.defaults.logOutputDbBytes);
    });

    test('overrides apply and unknown keys are ignored', () {
      final parsed = AppLimits.parse(
        '{"maxAgentSteps": 40, "foregroundExecTimeoutSeconds": 90, "unknown": true}',
      );
      expect(parsed.maxAgentSteps, 40);
      expect(parsed.foregroundExecTimeout, const Duration(seconds: 90));
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

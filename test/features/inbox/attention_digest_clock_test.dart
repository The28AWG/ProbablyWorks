import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/settings/client_settings.dart';
import 'package:probably_works/features/inbox/presentation/bloc/attention_digest_clock.dart';

void main() {
  final now = DateTime.utc(2026, 11, 27, 12);

  test('does not show a digest without a previous activity mark', () async {
    final settings = MemoryClientSettings();
    final clock = AttentionDigestClock(
      settings,
      profileId: 'local',
      now: () => now,
    );

    expect(await clock.shouldShow(), isFalse);
    await clock.rememberActive();
    expect(
      settings
          .values['${ClientSettingsKeys.attentionDigestLastActiveAt}.local'],
      now.toIso8601String(),
    );
  });

  test('shows a digest only after the away threshold', () async {
    final settings = MemoryClientSettings();
    var current = now;
    final clock = AttentionDigestClock(
      settings,
      profileId: 'local',
      now: () => current,
    );
    await clock.rememberActive();

    current = now.add(const Duration(minutes: 14));
    expect(await clock.shouldShow(), isFalse);

    current = now.add(attentionDigestAwayThreshold);
    expect(await clock.shouldShow(), isTrue);
  });

  test('a clock moved backwards is not a long absence', () async {
    final settings = MemoryClientSettings();
    var current = now;
    final clock = AttentionDigestClock(
      settings,
      profileId: 'local',
      now: () => current,
    );
    await clock.rememberActive();

    current = now.subtract(const Duration(hours: 2));
    expect(await clock.shouldShow(), isFalse);
  });

  test('keeps the activity mark of each profile separate', () async {
    final settings = MemoryClientSettings();
    var current = now;
    final first = AttentionDigestClock(
      settings,
      profileId: 'first',
      now: () => current,
    );
    final second = AttentionDigestClock(
      settings,
      profileId: 'second',
      now: () => current,
    );
    await first.rememberActive();

    current = now.add(const Duration(hours: 1));
    expect(await first.shouldShow(), isTrue);
    expect(await second.shouldShow(), isFalse);
  });
}

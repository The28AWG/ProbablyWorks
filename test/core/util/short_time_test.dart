import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/util/short_time.dart';

void main() {
  final now = DateTime(2026, 11, 10, 15, 30);

  group('dayBucket', () {
    test('same calendar day is today', () {
      expect(
        dayBucket(DateTime(2026, 11, 10, 0, 1), now: now),
        DayBucket.today,
      );
    });

    test('previous calendar day is yesterday', () {
      expect(
        dayBucket(DateTime(2026, 11, 9, 23, 59), now: now),
        DayBucket.yesterday,
      );
    });

    test('older dates are earlier', () {
      expect(dayBucket(DateTime(2026, 11, 8), now: now), DayBucket.earlier);
    });

    test('future timestamps count as today', () {
      expect(dayBucket(DateTime(2026, 11, 11), now: now), DayBucket.today);
    });
  });

  group('formatShortTime', () {
    test('shows HH:mm for today', () {
      expect(formatShortTime(DateTime(2026, 11, 10, 9, 5), now: now), '09:05');
    });

    test('shows dd.MM for older dates', () {
      expect(formatShortTime(DateTime(2026, 3, 7, 9, 5), now: now), '07.03');
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/core/util/elapsed_format.dart';

void main() {
  test('zero is 0s', () {
    expect(formatElapsed(Duration.zero), '0s');
    expect(formatElapsed(const Duration(seconds: -5)), '0s');
  });

  test('seconds only', () {
    expect(formatElapsed(const Duration(seconds: 5)), '5s');
    expect(formatElapsed(const Duration(seconds: 59)), '59s');
  });

  test('minutes and seconds', () {
    expect(formatElapsed(const Duration(minutes: 3, seconds: 40)), '3m 40s');
    expect(formatElapsed(const Duration(minutes: 1)), '1m');
  });

  test('zero places in the middle are not shown', () {
    expect(formatElapsed(const Duration(hours: 1)), '1h');
    expect(formatElapsed(const Duration(hours: 1, seconds: 5)), '1h 5s');
    expect(
      formatElapsed(const Duration(hours: 2, minutes: 3, seconds: 4)),
      '2h 3m 4s',
    );
  });

  test('days are shown with the smaller places', () {
    expect(formatElapsed(const Duration(days: 1)), '1d');
    expect(formatElapsed(const Duration(days: 2, hours: 3)), '2d 3h');
    expect(
      formatElapsed(const Duration(days: 3, hours: 12, minutes: 5, seconds: 9)),
      '3d 12h 5m 9s',
    );
  });

  test('fractional seconds are truncated', () {
    expect(formatElapsed(const Duration(milliseconds: 2999)), '2s');
  });
}

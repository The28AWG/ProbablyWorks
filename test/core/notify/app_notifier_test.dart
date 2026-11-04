import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/notify/app_notifier.dart';

void main() {
  group('shouldShowNotification', () {
    test('suppressed while the app is in focus', () {
      expect(shouldShowNotification(AppLifecycleState.resumed), isFalse);
    });

    test('shown when the app lost focus or is hidden', () {
      expect(shouldShowNotification(AppLifecycleState.inactive), isTrue);
      expect(shouldShowNotification(AppLifecycleState.hidden), isTrue);
      expect(shouldShowNotification(AppLifecycleState.paused), isTrue);
      expect(shouldShowNotification(AppLifecycleState.detached), isTrue);
    });

    test('shown when the lifecycle state is not known yet', () {
      expect(shouldShowNotification(null), isTrue);
    });
  });
}

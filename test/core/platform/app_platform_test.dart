import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/app/ui/local_host_presentation.dart';
import 'package:probably_works/core/platform/app_platform.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

void main() {
  group('AppPlatform', () {
    test('iOS has no local host, no PTY and no directory picker', () {
      const ios = AppPlatform(TargetPlatform.iOS);
      expect(ios.hasLocalHost, isFalse);
      expect(ios.hasPty, isFalse);
      expect(ios.supportsDirectoryPicker, isFalse);
      expect(ios.supportsFileDrop, isFalse);
      expect(ios.canOpenExternalKeys, isFalse);
      expect(ios.isMobile, isTrue);
      expect(ios.focusesInputOnOpen, isFalse);
    });

    test(
      'Android keeps the sandbox local host and PTY, without desktop pickers',
      () {
        const android = AppPlatform(TargetPlatform.android);
        expect(android.hasLocalHost, isTrue);
        expect(android.hasPty, isTrue);
        expect(android.supportsDirectoryPicker, isFalse);
        expect(android.supportsFileDrop, isFalse);
        expect(android.canOpenExternalKeys, isFalse);
        expect(android.isAndroid, isTrue);
        expect(android.focusesInputOnOpen, isFalse);
      },
    );

    test('desktop platforms have the full local host and pickers', () {
      for (final target in [
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      ]) {
        final platform = AppPlatform(target);
        expect(platform.hasLocalHost, isTrue, reason: '$target');
        expect(platform.hasPty, isTrue, reason: '$target');
        expect(platform.supportsDirectoryPicker, isTrue, reason: '$target');
        expect(platform.supportsFileDrop, isTrue, reason: '$target');
        expect(platform.canOpenExternalKeys, isTrue, reason: '$target');
        expect(platform.isMobile, isFalse, reason: '$target');
        expect(platform.focusesInputOnOpen, isTrue, reason: '$target');
      }
    });
  });

  group('local host presentation', () {
    final ru = lookupAppLocalizations(const Locale('ru'));
    final en = lookupAppLocalizations(const Locale('en'));

    test('desktop shows the computer label and icon', () {
      const desktop = AppPlatform(TargetPlatform.linux);
      expect(localHostTitle(ru, platform: desktop), 'Этот компьютер');
      expect(localHostTitle(en, platform: desktop), 'This computer');
      expect(localHostIcon(platform: desktop), Icons.computer_outlined);
    });

    test('Android shows the phone label and icon', () {
      const android = AppPlatform(TargetPlatform.android);
      expect(localHostTitle(ru, platform: android), 'Этот телефон');
      expect(localHostTitle(en, platform: android), 'This phone');
      expect(localHostIcon(platform: android), Icons.smartphone_outlined);
    });
  });
}

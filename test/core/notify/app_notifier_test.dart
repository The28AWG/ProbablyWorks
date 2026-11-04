import 'dart:ui' show AppLifecycleState;

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/notify/app_notifier.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

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

  group('composeAgentNotice', () {
    final en = lookupAppLocalizations(const Locale('en'));
    final ru = lookupAppLocalizations(const Locale('ru'));

    test('title is "action · chat title", body says what to do', () {
      final notice = composeAgentNotice(
        ru,
        kind: AgentNoticeKind.approvalNeeded,
        chatTitle: 'Починить логин',
      );
      expect(notice.title, 'Нужно подтверждение · Починить логин');
      expect(notice.body, ru.notifyApprovalBody);
    });

    test('empty chat title leaves only the action, without a separator', () {
      final notice = composeAgentNotice(
        en,
        kind: AgentNoticeKind.turnFinished,
        chatTitle: '   ',
      );
      expect(notice.title, en.notifyFinishedTitle);
      expect(notice.body, en.notifyFinishedBody);
    });

    test('every kind has its own action and body', () {
      final titles = <String>{};
      final bodies = <String>{};
      for (final kind in AgentNoticeKind.values) {
        final notice = composeAgentNotice(
          en,
          kind: kind,
          chatTitle: '',
          detail: 'done',
        );
        titles.add(notice.title);
        bodies.add(notice.body);
      }
      expect(titles, hasLength(AgentNoticeKind.values.length));
      expect(bodies, hasLength(AgentNoticeKind.values.length));
    });

    test('background notice carries the technical status', () {
      final notice = composeAgentNotice(
        en,
        kind: AgentNoticeKind.backgroundFinished,
        chatTitle: 'Деплой',
        detail: 'failed',
      );
      expect(notice.title, 'Background command finished · Деплой');
      expect(notice.body, contains('failed'));
    });
  });
}

import 'dart:ui' show AppLifecycleState;

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/notify/app_notifier_plugin.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/core/notify/app_notifier.dart';

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

  group('agentNoticeId', () {
    test('card notice is stable and uses the card id', () {
      final first = agentNoticeId(
        kind: AgentNoticeKind.approvalNeeded,
        scope: 'p1',
        chatId: 'c1',
        approvalId: 'a1',
      );
      final second = agentNoticeId(
        kind: AgentNoticeKind.approvalNeeded,
        scope: 'p1',
        chatId: 'c1',
        approvalId: 'a1',
      );

      expect(first, second);
      expect(first, 'p1:approvalNeeded:a1');
    });

    test('approval and question with the same id stay separate', () {
      final approval = agentNoticeId(
        kind: AgentNoticeKind.approvalNeeded,
        approvalId: '1',
      );
      final question = agentNoticeId(
        kind: AgentNoticeKind.questionAsked,
        questionId: '1',
      );

      expect(approval, isNot(question));
    });

    test('profiles do not share notification ids', () {
      final first = agentNoticeId(
        kind: AgentNoticeKind.approvalNeeded,
        scope: 'p1',
        approvalId: 'a1',
      );
      final second = agentNoticeId(
        kind: AgentNoticeKind.approvalNeeded,
        scope: 'p2',
        approvalId: 'a1',
      );

      expect(first, isNot(second));
    });

    test('turn notices are replaced per chat and kind', () {
      final finished = agentNoticeId(
        kind: AgentNoticeKind.turnFinished,
        scope: 'p1',
        chatId: 'c1',
      );
      final failed = agentNoticeId(
        kind: AgentNoticeKind.turnFailed,
        scope: 'p1',
        chatId: 'c1',
      );

      expect(finished, 'p1:turnFinished:c1');
      expect(failed, 'p1:turnFailed:c1');
    });

    test('distinct events in one chat keep separate ids', () {
      final first = agentNoticeId(
        kind: AgentNoticeKind.backgroundFinished,
        eventId: 'run-1',
      );
      final second = agentNoticeId(
        kind: AgentNoticeKind.backgroundFinished,
        eventId: 'run-2',
      );

      expect(first, isNot(second));
      expect(
        agentNoticeId(
          kind: AgentNoticeKind.backgroundFinished,
          eventId: 'run-1',
        ),
        first,
      );
    });
  });

  group('notificationPluginId', () {
    test('is stable for the same key and differs for another', () {
      expect(
        notificationPluginId('p1:approvalNeeded:a1'),
        notificationPluginId('p1:approvalNeeded:a1'),
      );
      expect(
        notificationPluginId('p1:approvalNeeded:a1'),
        isNot(notificationPluginId('p1:approvalNeeded:a2')),
      );
    });

    test('stays in the platform signed 32-bit range', () {
      for (final key in ['', 'local', 'p1:turnFinished:c1']) {
        expect(notificationPluginId(key), greaterThan(0));
        expect(notificationPluginId(key), lessThan(0x80000000));
      }
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

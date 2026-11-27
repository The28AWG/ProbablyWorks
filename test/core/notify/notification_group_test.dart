import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/notify/notification_group.dart';
import 'package:pw_agent/core/notify/app_notifier.dart';

void main() {
  group('agentNoticeGroupKey', () {
    test('groups cards of one chat and kind together', () {
      final first = agentNoticeGroupKey(
        kind: AgentNoticeKind.approvalNeeded,
        scope: 'p1',
        chatId: 'c1',
      );
      final second = agentNoticeGroupKey(
        kind: AgentNoticeKind.approvalNeeded,
        scope: 'p1',
        chatId: 'c1',
      );

      expect(first, second);
      expect(first, 'p1:approvalNeeded:c1');
    });

    test('approvals and questions in one chat are different groups', () {
      final approval = agentNoticeGroupKey(
        kind: AgentNoticeKind.approvalNeeded,
        chatId: 'c1',
      );
      final question = agentNoticeGroupKey(
        kind: AgentNoticeKind.questionAsked,
        chatId: 'c1',
      );

      expect(approval, isNot(question));
    });

    test('profiles do not share a group', () {
      final first = agentNoticeGroupKey(
        kind: AgentNoticeKind.approvalNeeded,
        scope: 'p1',
        chatId: 'c1',
      );
      final second = agentNoticeGroupKey(
        kind: AgentNoticeKind.approvalNeeded,
        scope: 'p2',
        chatId: 'c1',
      );

      expect(first, isNot(second));
    });

    test('events without a chat are not grouped', () {
      expect(
        agentNoticeGroupKey(kind: AgentNoticeKind.attentionDigest, scope: 'p1'),
        isNull,
      );
      expect(
        agentNoticeGroupKey(kind: AgentNoticeKind.attentionDigest, chatId: ''),
        isNull,
      );
    });
  });

  group('agentNoticeAnswerId', () {
    test('is stable for one question', () {
      expect(agentNoticeAnswerId('q1'), agentNoticeAnswerId('q1'));
      expect(agentNoticeAnswerId('q1'), isNot(agentNoticeAnswerId('q2')));
    });
  });

  group('NoticeGroupTracker', () {
    GroupedNotice notice(String id, {String group = 'g1'}) => GroupedNotice(
      noticeId: id,
      groupKey: group,
      title: 'Approve · Chat',
      body: 'Choose whether to approve.',
      chatTitle: 'Chat',
      chatId: 'c1',
      profileId: 'p1',
    );

    test('summary counts cards in insertion order', () {
      final tracker = NoticeGroupTracker()
        ..show(notice('n1'))
        ..show(notice('n2'))
        ..show(notice('n3'));

      final summary = tracker.summary('g1');
      expect(summary, isNotNull);
      expect(summary!.count, 3);
      expect(summary.notices.map((item) => item.noticeId), ['n1', 'n2', 'n3']);
      expect(summary.chatId, 'c1');
      expect(summary.profileId, 'p1');
      expect(summary.chatTitle, 'Chat');
    });

    test('updating a card does not duplicate or reorder it', () {
      final tracker = NoticeGroupTracker()
        ..show(notice('n1'))
        ..show(notice('n2'))
        ..show(notice('n1'));

      expect(tracker.summary('g1')!.notices.map((item) => item.noticeId), [
        'n1',
        'n2',
      ]);
    });

    test('removing a card shrinks the group and the last removal is empty', () {
      final tracker = NoticeGroupTracker()
        ..show(notice('n1'))
        ..show(notice('n2'));

      expect(tracker.remove('n1')!.noticeId, 'n1');
      expect(tracker.summary('g1')!.count, 1);

      expect(tracker.remove('n2')!.noticeId, 'n2');
      expect(tracker.summary('g1'), isNull);
      expect(tracker.remove('n2'), isNull);
    });

    test('groups are independent', () {
      final tracker = NoticeGroupTracker()
        ..show(notice('n1'))
        ..show(notice('n2', group: 'g2'));

      expect(tracker.summary('g1')!.count, 1);
      expect(tracker.summary('g2')!.count, 1);
    });

    test('clearing a group forgets only its cards', () {
      final tracker = NoticeGroupTracker()
        ..show(notice('n1'))
        ..show(notice('n2'))
        ..show(notice('n3', group: 'g2'))
        ..clearGroup('g1');

      expect(tracker.summary('g1'), isNull);
      expect(tracker.summary('g2')!.count, 1);
      expect(tracker.remove('n1'), isNull);
    });
  });
}

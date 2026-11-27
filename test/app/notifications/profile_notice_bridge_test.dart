import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/app/notifications/profile_notice_bridge.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/attention_api.dart';
import 'package:pw_agent/agent/api/attention_snooze_api.dart';
import 'package:pw_agent/agent/api/chat_api.dart';
import 'package:pw_agent/agent/domain/chat_attention.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/chat_snooze.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/core/notify/app_notifier.dart';

void main() {
  late _FakeAgentApi api;
  late _RecordingNotifier notifier;

  setUp(() {
    api = _FakeAgentApi();
    notifier = _RecordingNotifier();
  });

  tearDown(() async {
    await api.close();
  });

  test(
    'suppresses a notice when another screen already shows the chat',
    () async {
      final bridge = ProfileNoticeBridge(
        api: api,
        notifier: notifier,
        profileId: 'p1',
        isVisible: (chatId) async => chatId == 'visible',
      );
      final subscriptions = bridge.listen();
      addTearDown(() async {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
      });

      api.addApproval(
        const ApprovalRequest(
          id: 'a-visible',
          chatId: 'visible',
          toolName: 'run_command',
          summary: 'ls',
          reason: 'ask',
        ),
      );
      await pumpEventQueue();

      expect(notifier.notices, isEmpty);

      api.addApproval(
        const ApprovalRequest(
          id: 'a-hidden',
          chatId: 'hidden',
          toolName: 'run_command',
          summary: 'ls',
          reason: 'ask',
        ),
      );
      await pumpEventQueue();

      expect(notifier.notices, hasLength(1));
      expect(notifier.notices.single.chatId, 'hidden');
      expect(notifier.notices.single.noticeId, 'p1:approvalNeeded:a-hidden');
    },
  );

  test('cancels approval and question notices on resolution', () async {
    final bridge = ProfileNoticeBridge(
      api: api,
      notifier: notifier,
      profileId: 'p1',
    );
    final subscriptions = bridge.listen();
    addTearDown(() async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    });

    api
      ..addApproval(
        const ApprovalRequest(
          id: 'a1',
          chatId: 'c1',
          toolName: 'run_command',
          summary: 'ls',
          reason: 'ask',
        ),
      )
      ..addQuestion(
        const UserQuestion(id: 'q1', chatId: 'c1', text: 'continue?'),
      );
    await pumpEventQueue();

    expect(notifier.notices.map((notice) => notice.noticeId), [
      'p1:approvalNeeded:a1',
      'p1:questionAsked:q1',
    ]);

    api
      ..addResolution(const ApprovalResolved(chatId: 'c1', requestId: 'a1'))
      ..addResolution(const QuestionResolved(chatId: 'c1', questionId: 'q1'));
    await pumpEventQueue();

    expect(notifier.cancelled, ['p1:approvalNeeded:a1', 'p1:questionAsked:q1']);
  });

  test('a card resolved before the show is not shown afterwards', () async {
    final visible = Completer<bool>();
    final bridge = ProfileNoticeBridge(
      api: api,
      notifier: notifier,
      profileId: 'p1',
      isVisible: (_) => visible.future,
    );
    final subscriptions = bridge.listen();
    addTearDown(() async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    });

    api.addApproval(
      const ApprovalRequest(
        id: 'a1',
        chatId: 'c1',
        toolName: 'run_command',
        summary: 'ls',
        reason: 'ask',
      ),
    );
    await pumpEventQueue();

    api.addResolution(const ApprovalResolved(chatId: 'c1', requestId: 'a1'));
    await pumpEventQueue();
    visible.complete(false);
    await pumpEventQueue();

    expect(notifier.notices, isEmpty);
    expect(notifier.cancelled, ['p1:approvalNeeded:a1']);
  });

  test('turn notices in one chat reuse the same stable id', () async {
    final bridge = ProfileNoticeBridge(
      api: api,
      notifier: notifier,
      profileId: 'p1',
    );
    final subscriptions = bridge.listen();
    addTearDown(() async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    });

    api
      ..addEvent(const AgentTurnFinished('c1', TurnEnd.completed))
      ..addEvent(const AgentTurnFinished('c1', TurnEnd.completed));
    await pumpEventQueue();

    expect(notifier.notices, hasLength(2));
    expect(
      notifier.notices.map((notice) => notice.noticeId),
      everyElement('p1:turnFinished:c1'),
    );
  });

  test(
    'cancels a card that the server no longer reports after reconnect',
    () async {
      final bridge = ProfileNoticeBridge(
        api: api,
        notifier: notifier,
        profileId: 'p1',
      );
      _listen(bridge);

      api.addApproval(
        const ApprovalRequest(
          id: 'a1',
          chatId: 'c1',
          toolName: 'run_command',
          summary: 'ls',
          reason: 'ask',
        ),
      );
      await pumpEventQueue();
      expect(notifier.notices, hasLength(1));

      // Решение приняли в другом клиенте, пока SSE не работал: событие закрытия
      // потерялось, и в списке сервера карточки уже нет.
      api.reconnect();
      await pumpEventQueue();

      expect(notifier.cancelled, ['p1:approvalNeeded:a1']);
    },
  );

  test('keeps a card that is still pending after reconnect', () async {
    final bridge = ProfileNoticeBridge(
      api: api,
      notifier: notifier,
      profileId: 'p1',
    );
    _listen(bridge);

    const question = UserQuestion(id: 'q1', chatId: 'c1', text: 'continue?');
    api.addQuestion(question);
    await pumpEventQueue();
    expect(notifier.notices, hasLength(1));

    api
      ..pendingQuestionsResult = [question]
      ..reconnect();
    await pumpEventQueue();

    expect(notifier.cancelled, isEmpty);
  });

  test('cancels card notices when the chat is deleted', () async {
    final bridge = ProfileNoticeBridge(
      api: api,
      notifier: notifier,
      profileId: 'p1',
    );
    _listen(bridge);

    api.addApproval(
      const ApprovalRequest(
        id: 'a1',
        chatId: 'c1',
        toolName: 'run_command',
        summary: 'ls',
        reason: 'ask',
      ),
    );
    await pumpEventQueue();
    expect(notifier.notices, hasLength(1));

    api.addEvent(const AgentChatDeleted('c1'));
    await pumpEventQueue();

    // Вместе с чатом снимается и напоминание о наступившем сроке, если оно
    // ещё висело в трее.
    expect(notifier.cancelled, ['p1:approvalNeeded:a1', 'p1:snoozeDue:c1']);
  });

  test(
    'cancels the notice again when the card closes during the show',
    () async {
      final gate = Completer<void>();
      notifier.gate = gate;
      final bridge = ProfileNoticeBridge(
        api: api,
        notifier: notifier,
        profileId: 'p1',
      );
      _listen(bridge);

      api.addApproval(
        const ApprovalRequest(
          id: 'a1',
          chatId: 'c1',
          toolName: 'run_command',
          summary: 'ls',
          reason: 'ask',
        ),
      );
      await pumpEventQueue();

      // Отмена приходит, пока платформенный показ ещё не завершился.
      api.addResolution(const ApprovalResolved(chatId: 'c1', requestId: 'a1'));
      await pumpEventQueue();
      gate.complete();
      await pumpEventQueue();

      expect(
        notifier.events.where(
          (event) => event == 'cancel:p1:approvalNeeded:a1',
        ),
        hasLength(2),
      );
      expect(notifier.events.last, 'cancel:p1:approvalNeeded:a1');
    },
  );

  test('cancels card notices when the chat becomes snoozed', () async {
    final bridge = ProfileNoticeBridge(
      api: api,
      notifier: notifier,
      profileId: 'p1',
    );
    _listen(bridge);

    api.addApproval(
      const ApprovalRequest(
        id: 'a1',
        chatId: 'c1',
        toolName: 'run_command',
        summary: 'ls',
        reason: 'ask',
      ),
    );
    await pumpEventQueue();
    expect(notifier.notices, hasLength(1));

    api.addAttention(_snoozedSnapshot('c1', revision: 2));
    await pumpEventQueue();

    expect(notifier.cancelled, contains('p1:approvalNeeded:a1'));
  });

  test('suppresses notices for a chat snoozed on the server', () async {
    final bridge = ProfileNoticeBridge(
      api: api,
      notifier: notifier,
      profileId: 'p1',
      isSnoozed: (chatId) async => chatId == 'c1',
    );
    _listen(bridge);

    api.addEvent(const AgentTurnFinished('c1', TurnEnd.completed));
    await pumpEventQueue();
    expect(notifier.notices, isEmpty);

    api.addEvent(const AgentTurnFinished('c2', TurnEnd.completed));
    await pumpEventQueue();
    expect(notifier.notices, hasLength(1));
    expect(notifier.notices.single.chatId, 'c2');
  });

  test('cancels the due reminder when the chat is snoozed again', () async {
    final bridge = ProfileNoticeBridge(
      api: api,
      notifier: notifier,
      profileId: 'p1',
    );
    _listen(bridge);

    api.addDue('c1');
    await pumpEventQueue();
    expect(notifier.notices.single.kind, AgentNoticeKind.snoozeDue);
    expect(notifier.notices.single.noticeId, 'p1:snoozeDue:c1');

    // Пользователь снова отложил чат: старое напоминание не должно висеть.
    api.addAttention(_snoozedSnapshot('c1', revision: 3));
    await pumpEventQueue();

    expect(notifier.cancelled, contains('p1:snoozeDue:c1'));
  });
}

/// Снимок входящих с одним отложенным чатом.
AttentionSnapshot _snoozedSnapshot(String chatId, {required int revision}) =>
    AttentionSnapshot(
      revision: revision,
      items: const [],
      snoozed: [
        ChatSnooze(chatId: chatId, until: DateTime.utc(2030), revision: 1),
      ],
    );

/// Подписывает мост и снимает подписки после теста.
void _listen(ProfileNoticeBridge bridge) {
  final subscriptions = bridge.listen();
  addTearDown(() async {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  });
}

final class _FakeAgentApi
    implements
        AgentApi,
        InteractionEventsApi,
        ChatReconnectApi,
        AttentionApi,
        AttentionSnoozeApi {
  final _events = StreamController<AgentEvent>.broadcast();
  final _approvals = StreamController<ApprovalRequest>.broadcast();
  final _questions = StreamController<UserQuestion>.broadcast();
  final _resolutions = StreamController<InteractionResolution>.broadcast();
  final _reconnects = StreamController<void>.broadcast();
  final _attention = StreamController<AttentionSnapshot>.broadcast();
  final _attentionDue = StreamController<String>.broadcast();

  /// Что сервер вернёт при сверке карточек после обрыва связи.
  var pendingApprovalsResult = <ApprovalRequest>[];
  var pendingQuestionsResult = <UserQuestion>[];

  @override
  Stream<AgentEvent> get events => _events.stream;

  @override
  Stream<ApprovalRequest> get approvals => _approvals.stream;

  @override
  Stream<UserQuestion> get questions => _questions.stream;

  @override
  Stream<InteractionResolution> get resolutions => _resolutions.stream;

  @override
  Stream<void> get reconnects => _reconnects.stream;

  @override
  Future<Chat?> chat(String id) async => null;

  @override
  Future<List<ApprovalRequest>> pendingApprovals(String chatId) async => [
    for (final request in pendingApprovalsResult)
      if (request.chatId == chatId) request,
  ];

  @override
  Future<List<UserQuestion>> pendingQuestions(String chatId) async => [
    for (final question in pendingQuestionsResult)
      if (question.chatId == chatId) question,
  ];

  void addEvent(AgentEvent event) => _events.add(event);

  void addApproval(ApprovalRequest request) => _approvals.add(request);

  void addQuestion(UserQuestion question) => _questions.add(question);

  void addResolution(InteractionResolution resolution) =>
      _resolutions.add(resolution);

  void addAttention(AttentionSnapshot snapshot) => _attention.add(snapshot);

  void addDue(String chatId) => _attentionDue.add(chatId);

  void reconnect() => _reconnects.add(null);

  @override
  Stream<AttentionSnapshot> get attentionChanges => _attention.stream;

  @override
  Future<AttentionSnapshot> attention() async => AttentionSnapshot.empty;

  @override
  Future<void> dismissAttention(String chatId) => Future<void>.value();

  @override
  Future<void> snoozeAttention(String chatId, DateTime until) =>
      Future<void>.value();

  @override
  Future<void> unsnoozeAttention(String chatId) => Future<void>.value();

  @override
  bool get supportsSnooze => true;

  @override
  Stream<String> get attentionDue => _attentionDue.stream;

  Future<void> close() async {
    await _events.close();
    await _approvals.close();
    await _questions.close();
    await _resolutions.close();
    await _reconnects.close();
    await _attention.close();
    await _attentionDue.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('not used in notice bridge tests');
}

final class _RecordingNotifier implements AppNotifier {
  final notices = <({AgentNoticeKind kind, String chatId, String? noticeId})>[];
  final cancelled = <String>[];
  final events = <String>[];

  /// Если задан, `notify` ждёт его: так проверяется закрытие карточки во время
  /// платформенного показа.
  Completer<void>? gate;

  @override
  Future<void> notify({
    required AgentNoticeKind kind,
    required String chatTitle,
    String? detail,
    String? profileId,
    String? chatId,
    String? approvalId,
    String? noticeId,
  }) async {
    final pending = gate;
    if (pending != null) await pending.future;
    notices.add((kind: kind, chatId: chatId ?? '', noticeId: noticeId));
    events.add('notify:${noticeId ?? ''}');
  }

  @override
  Future<void> cancel(String noticeId) async {
    cancelled.add(noticeId);
    events.add('cancel:$noticeId');
  }
}

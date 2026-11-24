import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/app/notifications/profile_notice_bridge.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/chat_api.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
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

    expect(notifier.cancelled, ['p1:approvalNeeded:a1']);
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
}

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
    implements AgentApi, InteractionEventsApi, ChatReconnectApi {
  final _events = StreamController<AgentEvent>.broadcast();
  final _approvals = StreamController<ApprovalRequest>.broadcast();
  final _questions = StreamController<UserQuestion>.broadcast();
  final _resolutions = StreamController<InteractionResolution>.broadcast();
  final _reconnects = StreamController<void>.broadcast();

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

  void reconnect() => _reconnects.add(null);

  Future<void> close() async {
    await _events.close();
    await _approvals.close();
    await _questions.close();
    await _resolutions.close();
    await _reconnects.close();
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

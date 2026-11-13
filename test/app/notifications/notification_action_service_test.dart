import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/app/notifications/notification_action_service.dart';
import 'package:probably_works/app/profiles/agent_profile.dart';
import 'package:probably_works/app/profiles/local_agent_apis.dart';
import 'package:probably_works/app/profiles/profile_service.dart';
import 'package:probably_works/core/notify/notification_action.dart';
import 'package:probably_works/core/platform/client_info.dart';
import 'package:probably_works/core/settings/client_settings.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/core/notify/app_notifier.dart';
import 'package:pw_agent/core/security/secret_store.dart';

void main() {
  test('approve resolves the card once and keeps the current screen', () async {
    final api = _RecordingAgent();
    String? opened;
    final service = NotificationActionService(
      profiles: _FakeProfiles(api),
      openChat: (profileId, chatId) async => opened = chatId,
    );

    await service.handle(
      const NotificationActionRequest(
        action: NotificationActionKind.approve,
        chatId: 'c1',
        approvalId: 'a1',
      ),
    );

    expect(api.approvalId, 'a1');
    expect(api.action, ApprovalAction.allowOnce);
    expect(opened, isNull);
  });

  test('deny resolves the card and does not open the chat', () async {
    final api = _RecordingAgent();
    String? opened;
    final service = NotificationActionService(
      profiles: _FakeProfiles(api),
      openChat: (profileId, chatId) async => opened = chatId,
    );

    await service.handle(
      const NotificationActionRequest(
        action: NotificationActionKind.deny,
        chatId: 'c1',
        approvalId: 'a1',
      ),
    );

    expect(api.action, ApprovalAction.deny);
    expect(opened, isNull);
  });

  test('open action navigates to the chat', () async {
    final api = _RecordingAgent();
    (String, String)? opened;
    final service = NotificationActionService(
      profiles: _FakeProfiles(api),
      openChat: (profileId, chatId) async => opened = (profileId, chatId),
    );

    await service.handle(
      const NotificationActionRequest(
        action: NotificationActionKind.open,
        profileId: 'p1',
        chatId: 'c1',
      ),
    );

    expect(api.action, isNull);
    expect(opened, ('p1', 'c1'));
  });

  test('failed approval falls back to opening the chat', () async {
    final api = _RecordingAgent(fail: true);
    String? opened;
    final service = NotificationActionService(
      profiles: _FakeProfiles(api),
      openChat: (profileId, chatId) async => opened = chatId,
    );

    await service.handle(
      const NotificationActionRequest(
        action: NotificationActionKind.approve,
        chatId: 'c1',
        approvalId: 'gone',
      ),
    );

    expect(opened, 'c1');
  });
}

final class _RecordingAgent implements AgentApi {
  _RecordingAgent({this.fail = false});

  final bool fail;
  String? approvalId;
  ApprovalAction? action;

  @override
  Future<void> resolveApproval(
    String id,
    ApprovalAction action, {
    String? reason,
  }) async {
    if (fail) throw StateError('approval is gone');
    approvalId = id;
    this.action = action;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('AgentApi is not used in notification tests');
}

final class _FakeProfiles extends ProfileService {
  _FakeProfiles(this.api)
    : super(
        MemoryClientSettings(),
        MemorySecretStore(),
        LocalAgentApisProvider(),
        const ClientInfo.fallback(),
        const _NoopNotifier(),
      );

  final AgentApi api;

  @override
  Future<void> load() => Future<void>.value();

  @override
  AgentProfile get localProfile => AgentProfile.local('p1');

  @override
  AgentProfile? byId(String id) => id == 'p1' ? localProfile : null;

  @override
  AgentApi agentApiFor(AgentProfile profile) => api;
}

final class _NoopNotifier implements AppNotifier {
  const _NoopNotifier();

  @override
  Future<void> notify({
    required AgentNoticeKind kind,
    required String chatTitle,
    String? detail,
    String? profileId,
    String? chatId,
    String? approvalId,
  }) => Future<void>.value();
}

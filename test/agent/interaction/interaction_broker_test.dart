import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/agent/interaction/interaction_broker.dart';

ApprovalRequest _request({
  required String id,
  String chatId = 'c1',
  String? turnId,
  String key = 'run_command\u0000ls',
}) => ApprovalRequest(
  id: id,
  chatId: chatId,
  toolName: 'run_command',
  summary: 'ls',
  reason: 'read?',
  turnId: turnId,
  permissionKey: key,
);

void main() {
  test('allow once does not create a grant', () async {
    final broker = InteractionBroker();
    final pending = broker.requestApproval(_request(id: 'a', turnId: 't1'));

    broker.resolveApproval('a', const ApprovalDecision.allowOnce());

    expect((await pending).action, ApprovalAction.allowOnce);
    expect(
      broker.hasGrant(chatId: 'c1', turnId: 't1', key: 'run_command\u0000ls'),
      isFalse,
    );
  });

  test('allow turn is scoped to the exact turn and key', () async {
    final broker = InteractionBroker();
    final pending = broker.requestApproval(_request(id: 'a', turnId: 't1'));

    broker.resolveApproval('a', const ApprovalDecision.allowTurn());

    expect((await pending).allowed, isTrue);
    expect(
      broker.hasGrant(chatId: 'c1', turnId: 't1', key: 'run_command\u0000ls'),
      isTrue,
    );
    expect(
      broker.hasGrant(chatId: 'c1', turnId: 't2', key: 'run_command\u0000ls'),
      isFalse,
    );
    expect(
      broker.hasGrant(chatId: 'c1', turnId: 't1', key: 'run_command\u0000pwd'),
      isFalse,
    );
  });

  test('allow chat survives turns but not other chats', () async {
    final broker = InteractionBroker();
    final pending = broker.requestApproval(_request(id: 'a', turnId: 't1'));

    broker.resolveApproval('a', const ApprovalDecision.allowChat());

    expect((await pending).allowed, isTrue);
    expect(
      broker.hasGrant(chatId: 'c1', turnId: 't2', key: 'run_command\u0000ls'),
      isTrue,
    );
    expect(
      broker.hasGrant(chatId: 'c2', turnId: 't2', key: 'run_command\u0000ls'),
      isFalse,
    );
  });
}

import 'dart:async';

import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:test/test.dart';

void main() {
  late InteractionBroker broker;

  setUp(() => broker = InteractionBroker());

  ApprovalRequest approval(String id) => ApprovalRequest(
    id: id,
    chatId: 'chat',
    toolName: 'run_command',
    summary: 'ls',
    reason: 'ask',
  );

  test('publishes a resolved approval once', () async {
    final resolutions = <InteractionResolution>[];
    final sub = broker.resolutions.listen(resolutions.add);
    addTearDown(sub.cancel);

    final pending = broker.requestApproval(approval('a1'));
    broker.resolveApproval('a1', const ApprovalDecision.allowOnce());
    await pending;
    await Future<void>.delayed(Duration.zero);

    expect(resolutions, hasLength(1));
    expect(resolutions.single, isA<ApprovalResolved>());
    expect((resolutions.single as ApprovalResolved).requestId, 'a1');

    broker.resolveApproval('a1', const ApprovalDecision.allowOnce());
    await Future<void>.delayed(Duration.zero);
    expect(resolutions.length, 1);
  });

  test('publishes a resolved question and edit choice', () async {
    final resolutions = <InteractionResolution>[];
    final sub = broker.resolutions.listen(resolutions.add);
    addTearDown(sub.cancel);

    final question = broker.askUser('chat', 'q1', 'continue?');
    broker.answer('q1', 'yes');
    await question;
    await Future<void>.delayed(Duration.zero);

    final request = EditFileChangesRequest(
      id: 'e1',
      chatId: 'chat',
      files: const [],
      shellMayHaveChangedFiles: false,
    );
    final edit = broker.requestEditFileChanges(request);
    broker.resolveEditFileChanges('e1', EditFileChangesChoice.cancel);
    await edit;
    await Future<void>.delayed(Duration.zero);

    expect(resolutions, hasLength(2));
    expect(resolutions.first, isA<QuestionResolved>());
    expect(resolutions[1], isA<EditFileChangesResolved>());
  });

  test('cancelChat emits a resolution for every pending card', () async {
    final resolutions = <InteractionResolution>[];
    final sub = broker.resolutions.listen(resolutions.add);
    addTearDown(sub.cancel);

    final a = broker.requestApproval(approval('a1'));
    final q = broker.askUser('chat', 'q1', 'continue?');
    broker.cancelChat('chat');
    await Future.wait([a, q]);
    await Future<void>.delayed(Duration.zero);

    expect(resolutions, hasLength(2));
    expect(broker.waitingChatIds, isEmpty);
  });
}

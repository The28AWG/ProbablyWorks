import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/agent/turn/turn_changeset_service.dart';
import 'package:probably_works/agent/turn/turn_changeset_store.dart';
import 'package:probably_works/agent/turn/turn_file_kind.dart';

void main() {
  late Directory root;
  late TurnChangesetStore store;
  late TurnChangesetService service;

  setUp(() {
    root = Directory.systemTemp.createTempSync('pw_delete_changeset_');
    store = TurnChangesetStore(root);
    service = TurnChangesetService(store);
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('delete keeps text for rollback', () async {
    final change = await service.recordSuccessfulDelete(
      chatId: 'c1',
      turnId: 't1',
      path: '/ws/a.txt',
      beforeText: 'old text',
    );

    final file = change.files['/ws/a.txt']!;
    expect(file.kind, TurnFileKind.deleted);
    final bytes = await store.readBackup('c1', 't1', file.backupName!);
    expect(utf8.decode(bytes!), 'old text');
  });

  test('move and mkdir can mark a turn as non-recoverable', () async {
    final change = await service.recordUnrecoverable(
      chatId: 'c1',
      turnId: 't1',
      toolRunId: 'run',
    );

    expect(change.nonRecoverable, isTrue);
    expect(change.shellMutationToolRunIds, contains('run'));
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/turn/turn_changeset.dart';
import 'package:probably_works/agent/turn/turn_changeset_logic.dart';
import 'package:probably_works/agent/turn/turn_file_kind.dart';

TurnChangeset _empty() =>
    TurnChangeset(chatId: 'c', turnId: 't', updatedAt: DateTime(2020));

void main() {
  test('create then edit stays created for rollback', () {
    var cs = _empty();
    cs = turnChangesetRecordBeforeWrite(
      changeset: cs,
      path: '/a.txt',
      fileExisted: false,
      backupName: 'b1',
    );
    expect(cs.files['/a.txt']!.kind, TurnFileKind.created);
    cs = turnChangesetRecordBeforeWrite(
      changeset: cs,
      path: '/a.txt',
      fileExisted: true,
      backupName: 'b2',
    );
    expect(cs.files['/a.txt']!.backupName, isNull);
    expect(cs.files.length, 1);
    final plan = turnChangesetRollbackPlan(cs);
    expect(plan, hasLength(1));
    expect(plan.single, isA<RollbackRemove>());
  });

  test('edit then delete restores from backup', () {
    var cs = _empty();
    cs = turnChangesetRecordBeforeWrite(
      changeset: cs,
      path: '/b.txt',
      fileExisted: true,
      backupName: 'snap',
    );
    cs = turnChangesetRecordDelete(changeset: cs, path: '/b.txt');
    expect(cs.files['/b.txt']!.kind, TurnFileKind.deleted);
    final action = turnChangesetActionFor(cs.files['/b.txt']!);
    expect(action, isA<RollbackRestore>());
    expect((action as RollbackRestore).backupName, 'snap');
  });

  test('rollback of created file removes path', () {
    var cs = _empty();
    cs = turnChangesetRecordBeforeWrite(
      changeset: cs,
      path: '/new.txt',
      fileExisted: false,
      backupName: 'unused',
    );
    final action = turnChangesetActionFor(cs.files['/new.txt']!);
    expect(action, isA<RollbackRemove>());
    expect((action as RollbackRemove).path, '/new.txt');
  });

  test('pending file changes for rewind includes later user messages', () {
    final messages = [
      ChatMessage(
        id: 'u1',
        chatId: 'c',
        seq: 1,
        role: MessageRole.user,
        createdAt: DateTime(2020),
        text: 'a',
      ),
      ChatMessage(
        id: 'u2',
        chatId: 'c',
        seq: 3,
        role: MessageRole.user,
        createdAt: DateTime(2020),
        text: 'b',
      ),
    ];
    final first = _empty().copyWith(
      turnId: 'u1',
      files: {
        '/f.txt': TurnFileChange(path: '/f.txt', kind: TurnFileKind.created),
      },
    );
    final second = _empty().copyWith(
      turnId: 'u2',
      files: {
        '/f.txt': TurnFileChange(
          path: '/f.txt',
          kind: TurnFileKind.modified,
          backupName: 'b',
        ),
      },
    );
    final ids = turnIdsWithPendingFileChanges(
      messages: messages,
      allTurns: {'u1': first, 'u2': second},
      anchorSeq: 1,
      afterOnly: false,
    );
    expect(ids, ['u1', 'u2']);
    final sorted = turnIdsNewestFirst(messages: messages, turnIds: ids);
    expect(sorted, ['u2', 'u1']);
  });

  test('aggregate shows created when chain started with create', () {
    final created = _empty().copyWith(
      turnId: 't1',
      files: {
        '/f.txt': TurnFileChange(path: '/f.txt', kind: TurnFileKind.created),
      },
    );
    final modified = _empty().copyWith(
      turnId: 't2',
      files: {
        '/f.txt': TurnFileChange(
          path: '/f.txt',
          kind: TurnFileKind.modified,
          backupName: 'b',
        ),
      },
    );
    final entries = aggregateEditFileChanges(
      allTurns: {'t1': created, 't2': modified},
      turnIdsOldestFirst: ['t1', 't2'],
    );
    expect(entries.single.kind, TurnFileKind.created);
  });

  test('aggregate shows deleted when chain ends with delete', () {
    final modified = _empty().copyWith(
      turnId: 't1',
      files: {
        '/f.txt': TurnFileChange(
          path: '/f.txt',
          kind: TurnFileKind.modified,
          backupName: 'b',
        ),
      },
    );
    final deleted = _empty().copyWith(
      turnId: 't2',
      files: {
        '/f.txt': TurnFileChange(
          path: '/f.txt',
          kind: TurnFileKind.deleted,
          backupName: 'b',
        ),
      },
    );
    final entries = aggregateEditFileChanges(
      allTurns: {'t1': modified, 't2': deleted},
      turnIdsOldestFirst: ['t1', 't2'],
    );
    expect(entries.single.kind, TurnFileKind.deleted);
  });

  test('aggregate shows modified when file was deleted then created again', () {
    final deleted = _empty().copyWith(
      turnId: 't1',
      files: {
        '/f.txt': TurnFileChange(
          path: '/f.txt',
          kind: TurnFileKind.deleted,
          backupName: 'b',
        ),
      },
    );
    final created = _empty().copyWith(
      turnId: 't2',
      files: {
        '/f.txt': TurnFileChange(path: '/f.txt', kind: TurnFileKind.created),
      },
    );
    final entries = aggregateEditFileChanges(
      allTurns: {'t1': deleted, 't2': created},
      turnIdsOldestFirst: ['t1', 't2'],
    );
    expect(entries.single.kind, TurnFileKind.modified);
  });

  test('shell mutation marks non-recoverable', () {
    var cs = _empty();
    cs = turnChangesetMarkShellMutation(changeset: cs, toolRunId: 'run1');
    expect(cs.nonRecoverable, isTrue);
    expect(cs.shellMutationToolRunIds, ['run1']);
  });
}

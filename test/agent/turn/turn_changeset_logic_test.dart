import 'package:flutter_test/flutter_test.dart';
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

  test('rollback blocked when a newer turn touched the same path', () {
    final older = _empty().copyWith(
      turnId: 'user-old',
      files: {
        '/f.txt': TurnFileChange(path: '/f.txt', kind: TurnFileKind.created),
      },
    );
    final newer = _empty().copyWith(
      turnId: 'user-new',
      files: {
        '/f.txt': TurnFileChange(
          path: '/f.txt',
          kind: TurnFileKind.modified,
          backupName: 'b',
        ),
      },
    );
    final blocked = turnChangesetRollbackBlocked(
      changeset: older,
      turnUserSeq: 1,
      allTurns: {'user-old': older, 'user-new': newer},
      userSeqByMessageId: const {'user-old': 1, 'user-new': 3},
    );
    expect(blocked, '/f.txt');
  });

  test('shell mutation marks non-recoverable', () {
    var cs = _empty();
    cs = turnChangesetMarkShellMutation(changeset: cs, toolRunId: 'run1');
    expect(cs.nonRecoverable, isTrue);
    expect(cs.shellMutationToolRunIds, ['run1']);
  });
}

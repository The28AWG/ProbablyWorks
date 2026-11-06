import 'package:test/test.dart';

import 'support/git_parity.dart';

void main() {
  test('локальные команды совпадают с git по выводу и дереву', () async {
    final session = GitParitySession();
    await session.start();
    addTearDown(session.close);

    await session.both(['init', '-b', 'main']);
    await session.write('a.txt', 'a\n');
    await session.write('.gitignore', 'ignored.txt\n');
    await session.write('ignored.txt', 'nope\n');
    await session.both(['add', 'a.txt']);
    await session.both(['commit', '-m', 'first']);
    await session.both(['rev-parse', 'HEAD']);
    await session.both(['reflog']);
    await session.both(['check-ignore', '-v', 'ignored.txt']);
    await session.both(['branch', 'topic']);
    await session.both(['branch', '-m', 'topic', 'renamed']);
    await session.both(['branch', '-a']);
    await session.both(['branch', '-a', 'nope']);
    await session.both(['show-ref', '--heads']);
    await session.both(['commit', '--amend', '-m', 'amended']);
    await session.write('b.txt', 'b\n');
    await session.both(['add', 'b.txt']);
    await session.both(['commit', '-m', 'second']);
    await session.both(['merge-base', '--is-ancestor', 'HEAD~1', 'HEAD']);
    await session.both(['merge-base', 'HEAD~1', 'HEAD']);
    await session.both(['ls-tree', 'HEAD']);
    await session.both(['cat-file', '-t', 'HEAD']);
    await session.both(['config', 'user.name', 'Ada']);
    await session.both(['config', '--get', 'user.name']);
    await session.both(['rm', 'b.txt']);
    await session.write('c.txt', 'c\n');
    await session.both(['add', 'c.txt']);
    await session.both(['mv', 'c.txt', 'd.txt']);
    await session.both(['status', '--porcelain=v1']);
    await session.expectSameTree();
    expect(session.realRoot.existsSync(), isTrue);
  });

  test('clone, remote -v, branch -a и log совпадают с git', () async {
    final session = GitParitySession();
    await session.start();
    addTearDown(session.close);

    await session.both(['init', '-b', 'main']);
    await session.write('a.txt', 'a\n');
    await session.both(['add', 'a.txt']);
    await session.both(['commit', '-m', 'first']);
    await session.both(['branch', 'topic']);
    await session.both(['clone', '{root}', 'dst']);
    await session.both(['-C', 'dst', 'remote', '-v']);
    await session.both(['-C', 'dst', 'branch', '-a']);
    await session.both(['-C', 'dst', 'log', '--oneline', '-10']);
    await session.both(['-C', 'dst', 'show-ref']);
    expect(session.realRoot.existsSync(), isTrue);
  });

  test('backfill и maintenance run совпадают с git по коду и выводу', () async {
    final session = GitParitySession();
    await session.start();
    addTearDown(session.close);

    await session.both(['init', '-b', 'main']);
    await session.write('a.txt', 'a\n');
    await session.both(['add', 'a.txt']);
    await session.both(['commit', '-m', 'first']);
    // Нет promisor-частичного клона: обе стороны завершаются без вывода.
    await session.both(['backfill']);
    await session.both(['backfill', '--min-batch-size=1']);
    // Как у git: `--sparse` имеет смысл после `sparse-checkout init`.
    await session.both(['sparse-checkout', 'init']);
    await session.both(['backfill', '--sparse']);
    // Только no-op или локальная работа без планировщика ОС (см. docs/command_notes.md).
    await session.both([
      'maintenance',
      'run',
      '--task=gc',
      '--auto',
      '--quiet',
    ]);
    expect(session.realRoot.existsSync(), isTrue);
  });
}

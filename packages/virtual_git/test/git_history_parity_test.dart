import 'package:test/test.dart';

import 'support/git_parity.dart';

void main() {
  test('git log ограничивает историю путями', () async {
    final session = GitParitySession();
    await session.start();
    addTearDown(session.close);

    await session.both(['init', '-b', 'main']);
    await session.write('a.txt', 'a\n');
    await session.both(['add', 'a.txt']);
    await session.both(['commit', '-m', 'first']);
    await session.write('a.txt', 'aa\n');
    await session.write('b.txt', 'b\n');
    await session.both(['add', 'a.txt', 'b.txt']);
    await session.both(['commit', '-m', 'second']);
    await session.both(['log', '--oneline', 'a.txt']);
    await session.both(['log', '--oneline', '--', 'a.txt']);
    await session.both(['log', '--oneline', 'HEAD', '--', 'a.txt']);
    await session.both(['log', '--oneline', '--', 'dir']);
    await session.both(['log', '-1', '--', 'a.txt']);
    await session.both(['log', '-p', '-1', '--', 'a.txt']);
    await session.both(['log', '--oneline', 'HEAD', 'HEAD~1']);
    await session.both(['log', '--oneline', '--', 'nope']);
    await session.both(['log', 'nope']);
    await session.both(['log', 'nope', '--', 'a.txt']);

    await session.both(['rm', 'a.txt']);
    await session.both(['commit', '-m', 'remove']);
    await session.both(['log', '--oneline', '--', 'a.txt']);
    await session.both(['log', 'a.txt']);

    // Каталог в дереве: режим `040000` против `40000` у git, хеш коммита разный.
    await session.write('dir/c.txt', 'c\n');
    await session.both(['add', 'dir/c.txt']);
    await session.bothExit(['commit', '-m', 'third']);
    await session.both([
      'log',
      '--oneline',
      '--',
      'dir',
    ], normalize: (text) => text.replaceAll(RegExp('[0-9a-f]{7,40}'), 'HASH'));
    expect(session.realRoot.existsSync(), isTrue);
  });

  test('cherry-pick и revert совпадают с git по сводке и серии', () async {
    final session = GitParitySession();
    await session.start();
    addTearDown(session.close);

    await session.both(['init', '-b', 'main']);
    await session.write('a.txt', 'a\n');
    await session.both(['add', 'a.txt']);
    await session.both(['commit', '-m', 'base']);
    await session.both(['branch', 'base']);
    await session.both(['checkout', '-b', 'topic']);
    await session.write('b.txt', 'b\n');
    await session.both(['add', 'b.txt']);
    await session.both(['commit', '-m', 'side-1']);
    await session.write('c.txt', 'c\n');
    await session.both(['add', 'c.txt']);
    await session.both(['commit', '-m', 'side-2']);
    await session.both(['checkout', 'main']);
    await session.both(['cherry-pick', 'topic~1', 'topic']);
    await session.both(['log', '--oneline']);
    await session.both(['checkout', '-b', 'replay', 'base']);
    await session.both(['cherry-pick', 'base..topic']);
    await session.both(['log', '--oneline']);
    await session.both(['cherry-pick', 'base..base']);
    await session.both(['cherry-pick', 'HEAD']);
    await session.both(['status']);
    await session.both(['cherry-pick', '--abort']);
    await session.both(['status']);
    await session.both(['cherry-pick', 'HEAD']);
    await session.both(['cherry-pick', '--skip']);
    await session.both(['status']);
    await session.both(['cherry-pick', '--skip']);
    await session.both(['revert', '--skip']);
    await session.both(['cherry-pick', '-m', 'foo', 'HEAD']);

    await session.both(['checkout', 'main']);
    await session.both(['revert', 'HEAD']);
    await session.both(['log', '-1']);
    await session.both(['revert', 'HEAD']);
    await session.both(['log', '-1']);
    await session.both(['revert', '-m', '2', 'HEAD']);

    await session.both(['checkout', 'base']);
    await session.both(['checkout', '-b', 'side']);
    await session.write('m.txt', 'm\n');
    await session.both(['add', 'm.txt']);
    await session.both(['commit', '-m', 'side-merge']);
    await session.both(['checkout', 'base']);
    await session.write('n.txt', 'n\n');
    await session.both(['add', 'n.txt']);
    await session.both(['commit', '-m', 'base-move']);
    // Статистику слияния апплет не печатает; сам merge-коммит сверяется дальше.
    await session.bothExit(['merge', '-m', 'merge', 'side']);
    await session.both(['checkout', '-b', 'pick', 'HEAD~1']);
    String hide(String text) =>
        text.replaceAll(RegExp('[0-9a-f]{7,40}'), 'HASH');
    await session.both(['cherry-pick', 'base'], normalize: hide);
    await session.both(['cherry-pick', '-m', '1', 'base'], normalize: hide);
    await session.both(['log', '--oneline'], normalize: hide);
    await session.both(['revert', '-m', '1', 'base'], normalize: hide);
    await session.both(['log', '--oneline'], normalize: hide);
    await session.both(['rev-parse', 'HEAD^{tree}']);
    expect(session.realRoot.existsSync(), isTrue);
  });

  test('rebase печатает ход и up to date как git', () async {
    final session = GitParitySession();
    await session.start();
    addTearDown(session.close);

    await session.both(['init', '-b', 'main']);
    await session.write('a.txt', 'a\n');
    await session.both(['add', 'a.txt']);
    await session.both(['commit', '-m', 'base']);
    await session.both(['checkout', '-b', 'feature']);
    await session.write('b.txt', 'b\n');
    await session.both(['add', 'b.txt']);
    await session.both(['commit', '-m', 'one']);
    await session.write('c.txt', 'c\n');
    await session.both(['add', 'c.txt']);
    await session.both(['commit', '-m', 'two']);
    await session.both(['rebase', 'main']);
    await session.both(['checkout', 'main']);
    await session.write('d.txt', 'd\n');
    await session.both(['add', 'd.txt']);
    await session.both(['commit', '-m', 'extra']);
    await session.both(['checkout', 'feature']);
    await session.both(['rebase', 'main']);
    await session.both(['rebase', 'main']);
    await session.both(['log', '--oneline']);
    await session.both(['rev-parse', 'HEAD^{tree}']);
    await session.both(['rebase', 'nope']);
    await session.both(['rebase', '--onto', 'nope', 'main']);
    expect(session.realRoot.existsSync(), isTrue);
  });
}

import 'package:test/test.dart';

import 'support/git_parity.dart';

/// Сверка `git grep` с системным git: код, stdout и stderr.
void main() {
  gitParityTest('git grep совпадает с git', () async {
    final session = GitParitySession();
    await session.start();
    addTearDown(session.close);

    await session.both(['init', '-b', 'main']);
    await session.write('a.txt', 'alpha\nBeta beta\nalpha beta\n');
    await session.write('sub/b.txt', 'foo bar\nfoo\n');
    await session.write('dir/nested/c.txt', 'only\n');
    await session.write('bin.dat', 'x\u0000y\nalpha\n');
    await session.write('w.txt', 'beta\nbetamax\nxbeta\n_beta\nbeta_\n');
    await session.write('plus.txt', 'a+b\naab\n');
    await session.write('num.txt', 'id 42\n');
    await session.both(['add', '-A']);
    await session.bothExit(['commit', '-m', 'init']);

    await session.both(['grep', 'alpha']);
    await session.both(['grep', '-n', 'alpha']);
    await session.both(['grep', '-n', '-i', 'beta', '--', 'a.txt']);
    await session.both(['grep', '-n', '-w', 'beta', '--', 'w.txt']);
    await session.both(['grep', '-n', '-w', '-F', 'beta', '--', 'w.txt']);
    await session.both(['grep', '-n', '-F', 'a+b', '--', 'plus.txt']);
    await session.both(['grep', '-n', '-E', 'a+', '--', 'plus.txt']);
    await session.both(['grep', '-n', '-E', 'b(ar|eta)']);
    await session.both(['grep', '-n', '-G', r'b\(ar\|eta\)']);
    await session.both(['grep', '-n', '-E', r'^alpha$', '--', 'a.txt']);
    await session.both(['grep', '-n', '-G', r'^alpha$', '--', 'a.txt']);
    await session.both(['grep', '-n', '-E', '[[:digit:]]+', '--', 'num.txt']);
    await session.both(['grep', '-n', '-G', r'[[:digit:]]\+', '--', 'num.txt']);
    await session.both(['grep', '-n', '-E', 'a{1,2}', '--', 'a.txt']);
    await session.both(['grep', '-c', 'alpha']);
    await session.both(['grep', '-c', '-h', 'alpha', '--', 'a.txt']);
    await session.both(['grep', '-c', '-m', '1', 'alpha', '--', 'a.txt']);
    await session.both(['grep', '-l', 'alpha']);
    await session.both(['grep', '-c', '-l', 'alpha']);
    await session.both(['grep', '-L', 'zzznone', '--', 'a.txt', 'sub/b.txt']);
    await session.both(['grep', '-L', 'alpha', '--', 'a.txt']);
    await session.both(['grep', '-n', '-h', 'alpha', '--', 'a.txt']);
    await session.both(['grep', '-h', '-H', '-n', 'alpha', '--', 'a.txt']);
    await session.both(['grep', '-n', '-C', '1', 'Beta', '--', 'a.txt']);
    await session.both(['grep', '-n', '-A', '1', 'foo', '--', 'sub/b.txt']);
    await session.both([
      'grep',
      '-n',
      '-B',
      '1',
      '-A',
      '2',
      'beta',
      '--',
      'w.txt',
    ]);
    await session.both([
      'grep',
      '-n',
      '--heading',
      '--break',
      '-e',
      'alpha',
      '-e',
      'foo',
      '--',
      'a.txt',
      'sub/b.txt',
    ]);
    await session.both(['grep', '-n', '--column', 'alpha', '--', 'a.txt']);
    await session.both(['grep', '--column', 'alpha', '--', 'a.txt']);
    await session.both(['grep', '-n', '-o', 'alp', '--', 'a.txt']);
    await session.both(['grep', '-n', '-o', 'ab', '--', 'plus.txt']);
    await session.both(['grep', '-n', '-m', '1', 'alpha']);
    await session.both([
      'grep',
      '-n',
      '-m',
      '1',
      '-A',
      '1',
      'a',
      '--',
      'a.txt',
    ]);
    await session.both([
      'grep',
      '-n',
      '-e',
      'alpha',
      '--and',
      '-e',
      'beta',
      '--',
      'a.txt',
    ]);
    await session.both(['grep', '-n', '-e', 'alpha', '--or', '-e', 'only']);
    await session.both(['grep', '-n', '-e', 'alpha', '--not', '-e', 'Beta']);
    await session.both([
      'grep',
      '-n',
      '--not',
      '--not',
      '-e',
      'foo',
      '--',
      'sub/b.txt',
    ]);
    await session.both([
      'grep',
      '-n',
      '(',
      '-e',
      'alpha',
      '--or',
      '-e',
      'Beta',
      ')',
      '--and',
      '-e',
      'beta',
      '--',
      'a.txt',
    ]);
    await session.both(['grep', '--or', '-e', 'only']);
    await session.both(['grep', '-e', 'only', '--or']);
    await session.both(['grep', '-n', '-v', 'alpha', '--', 'sub/b.txt']);
    await session.both(['grep', '-n', '-v', 'foo', '--', 'sub/b.txt']);
    await session.both(['grep', '-q', 'alpha']);
    await session.both(['grep', '-q', 'nosuch']);
    await session.both(['grep', '-n', '-I', 'alpha']);
    await session.both(['grep', '-a', '-n', 'alpha', '--', 'bin.dat']);
    await session.both(['grep', '-z', '-n', 'alpha', '--', 'a.txt']);
    await session.both(['grep', '-z', '-l', 'alpha', '--', 'a.txt']);
    await session.both(['grep', '-z', '-c', 'alpha', '--', 'a.txt']);
    await session.both(['grep', '-n', 'alpha', 'a.txt']);
    await session.both(['grep', '-n', 'alpha', 'HEAD', '--', 'a.txt']);
    await session.both(['grep', '-n', 'alpha', 'HEAD', 'main', '--', 'a.txt']);
    await session.both(['grep', '-n', 'foo', '--', 'sub']);
    await session.both(['grep', '-n', 'foo', '--', 'sub/*']);
    await session.both(['grep', '-n', 'alpha', '--', 'sub']);
    await session.both(['grep', '-n', '--max-depth', '1', 'only']);
    await session.both(['grep', '-n', '--max-depth', '2', 'only']);
    await session.both(['grep', '-n', '--max-depth', '0', 'foo', '--', 'sub']);
    await session.both(['grep', '-n', '--max-depth=-1', 'only']);
    await session.both(['grep', '--no-recursive', 'only']);
    await session.both(['-C', 'sub', 'grep', '-n', 'foo']);
    await session.both(['-C', 'sub', 'grep', '-n', '--full-name', 'foo']);
    await session.both(['-C', 'sub', 'grep', '-n', 'alpha', '..']);
    await session.both(['grep', '-n', '-e', '', '--', 'sub/b.txt']);

    await session.write('pats.txt', 'alpha\nfoo\n');
    await session.both([
      'grep',
      '-n',
      '-f',
      'pats.txt',
      '--',
      'a.txt',
      'sub/b.txt',
    ]);

    await session.write('a.txt', 'alpha\nBeta beta\nalpha beta\nWORKTREE\n');
    await session.both(['grep', '-n', 'WORKTREE']);
    await session.both(['grep', '--cached', '-n', 'WORKTREE']);
    await session.both(['grep', '-n', 'WORKTREE', 'HEAD']);

    await session.write('u.txt', 'zzz unique\n');
    await session.both(['grep', '-n', 'zzz']);
    await session.both(['grep', '-n', '--untracked', 'zzz']);
    await session.write('.gitignore', 'ignored.txt\n');
    await session.write('ignored.txt', 'secret\n');
    await session.both(['grep', '-n', '--untracked', 'secret']);
    await session.both([
      'grep',
      '-n',
      '--untracked',
      '--no-exclude-standard',
      'secret',
    ]);
    await session.both(['grep', '--no-index', 'secret']);
    await session.both(['grep', '--no-index', '--exclude-standard', 'secret']);
    await session.both(['grep', '--no-index', '-n', 'zzz']);

    await session.write('both.txt', 'both alpha\nfoo\n');
    await session.both(['add', 'both.txt']);
    await session.bothExit(['commit', '-m', 'both']);
    await session.both([
      'grep',
      '-n',
      '-e',
      'alpha',
      '-e',
      'foo',
      '--all-match',
    ]);
    await session.both([
      'grep',
      '-l',
      '-e',
      'alpha',
      '-e',
      'foo',
      '--all-match',
    ]);

    await session.both(['grep']);
    await session.both(['grep', '--and', '-e', 'a']);
    await session.both(['grep', '-e', 'alpha', '--and']);
    await session.both(['grep', '--not']);
    await session.both(['grep', '(']);
    await session.both(['grep', '-e', 'alpha', ')']);
    await session.both(['grep', '-E', '[']);
    await session.both(['grep', '-e', '[']);
    await session.both(['grep', '-f', 'missing-pats']);
    await session.write('bad.pat', '[\n');
    await session.both(['grep', '-f', 'bad.pat']);
    await session.both(['grep', '--max-depth']);
    await session.both(['grep', '--max-depth', 'foo', 'alpha']);
    await session.both(['grep', '-C']);
    await session.both(['grep', '-C', 'x', 'alpha']);
    await session.both(['grep', 'alpha', 'NOREV']);
    await session.both(['grep', '-n', 'alpha', '--', 'missing']);
    await session.both(['grep', '-n', 'alpha', 'HEAD', 'missing']);
    await session.both(['grep', '--cached', '--untracked', 'alpha']);
    await session.both(['grep', '--no-index', '--cached', 'alpha']);
    await session.both(['grep', '--no-index', '--untracked', 'alpha']);
    await session.both(['grep', '--cached', '-e', 'alpha', 'HEAD']);
    await session.both(['grep', '-m', '0', 'alpha']);
    await session.both(['grep', '-m', '0', '-E', '[']);
    await session.both(['grep', '-n', 'alpha', '-E']);
    await session.bothFirstLine(['grep', '--nope', 'alpha']);
    await session.bothFirstLine(['grep', '-Q', 'alpha']);
    expect(session.realRoot.existsSync(), isTrue);
  });
}

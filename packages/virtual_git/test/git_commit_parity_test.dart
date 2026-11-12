import 'package:test/test.dart';

import 'support/git_parity.dart';

/// Сверка `git commit` с системным git: код, stdout, stderr и объект коммита.
void main() {
  gitParityTest('сообщение, подпись и дата совпадают с git', () async {
    final session = GitParitySession();
    await session.start();
    addTearDown(session.close);

    await session.both(['init', '-b', 'main']);
    await session.write('a.txt', 'one\n');
    await session.both(['add', 'a.txt']);
    await session.both(['commit', '-m', '  spaced  ', '-m', '  second  ']);
    await session.both(['cat-file', '-p', 'HEAD']);
    await session.both(['rev-parse', 'HEAD']);

    await session.write('a.txt', 'two\n');
    await session.both(['add', 'a.txt']);
    await session.both(['commit', '-s', '-m', 'signed']);
    await session.both(['cat-file', '-p', 'HEAD']);

    await session.write('a.txt', 'three\n');
    await session.both(['add', 'a.txt']);
    await session.both([
      'commit',
      '-s',
      '-s',
      '-m',
      'signed again',
      '--trailer',
      'Reviewed-by: Bea <bea@ex.test>',
      '--trailer',
      'Acked-by:Cara',
      '--trailer',
      'nocolon',
    ]);
    await session.both(['cat-file', '-p', 'HEAD']);

    await session.write('note.txt', '# comment\nkeep\n\n\ntrail  \n');
    await session.both(['add', 'note.txt']);
    await session.both(['commit', '-F', 'note.txt', '--cleanup=strip']);
    await session.both(['cat-file', '-p', 'HEAD']);

    await session.write('note.txt', 'verbatim  \n# keep\n\n');
    await session.both(['add', 'note.txt']);
    await session.both(['commit', '-F', 'note.txt', '--cleanup=verbatim']);
    await session.both(['cat-file', '-p', 'HEAD']);

    await session.write('a.txt', 'four\n');
    await session.both(['add', 'a.txt']);
    await session.both([
      'commit',
      '-m',
      'dated',
      '--date',
      '2020-01-02 03:04:05 +0300',
    ]);
    await session.both(['cat-file', '-p', 'HEAD']);

    await session.write('a.txt', 'five\n');
    await session.both(['add', 'a.txt']);
    await session.both([
      'commit',
      '-m',
      'raw date',
      '--date',
      '1600000000 -0500',
      '--author',
      'Grace <grace@ex.test>',
    ]);
    await session.both(['cat-file', '-p', 'HEAD']);

    await session.both(['commit', '--allow-empty', '-m', 'empty tree']);
    await session.both(['cat-file', '-p', 'HEAD']);
    await session.both(['commit', '--allow-empty-message', '-m', '   ', '-q']);
    await session.both(['cat-file', '-p', 'HEAD']);
    await session.both(['rev-parse', 'HEAD']);

    await session.both(['commit', '-m', '']);
    await session.both(['commit', '--cleanup=nope', '-m', 'x']);
    await session.both(['commit', '--date', 'not-a-date', '-m', 'x']);
    await session.both(['commit', '--author', 'nope', '-m', 'x']);
    expect(session.realRoot.existsSync(), isTrue);
  });

  gitParityTest('сухой прогон печатает статус и не коммитит', () async {
    final session = GitParitySession();
    await session.start();
    addTearDown(session.close);

    await session.both(['init', '-b', 'main']);
    await session.both(['commit', '--dry-run']);
    await session.write('a.txt', 'one\n');
    await session.write('u.txt', 'new\n');
    await session.both(['add', 'a.txt']);
    await session.write('b.txt', 'tracked\n');
    await session.both(['add', 'b.txt']);
    await session.both(['commit', '-m', 'base']);
    await session.write('a.txt', 'staged\n');
    await session.write('b.txt', 'unstaged\n');
    await session.both(['add', 'a.txt']);

    await session.both(['commit', '--dry-run']);
    await session.both(['commit', '--short']);
    await session.both(['commit', '--porcelain']);
    await session.both(['commit', '--short', '--branch']);
    await session.both(['commit', '--porcelain', '-z']);
    await session.both(['commit', '--dry-run', '-uno']);
    await session.both(['commit', '-a', '--dry-run']);
    await session.both(['status', '--porcelain']);
    await session.both([
      'commit',
      '--dry-run',
      '--no-ahead-behind',
      '--short',
      '--branch',
    ]);
    expect(session.realRoot.existsSync(), isTrue);
  });

  gitParityTest('частичный коммит и pathspec совпадают с git', () async {
    final session = GitParitySession();
    await session.start();
    addTearDown(session.close);

    await session.both(['init', '-b', 'main']);
    await session.write('a.txt', 'a\n');
    await session.write('b.txt', 'b\n');
    await session.both(['add', 'a.txt', 'b.txt']);
    await session.both(['commit', '-m', 'base']);

    await session.write('a.txt', 'a2\n');
    await session.write('b.txt', 'b2\n');
    await session.both(['add', 'a.txt', 'b.txt']);
    await session.both(['commit', '-m', 'only a', '--', 'a.txt']);
    await session.both(['cat-file', '-p', 'HEAD']);
    await session.both(['status', '--porcelain']);
    await session.both(['ls-files', '-s']);

    await session.write('a.txt', 'a3\n');
    await session.both(['commit', '-i', '-m', 'include a', '--', 'a.txt']);
    await session.both(['status', '--porcelain']);
    await session.both(['cat-file', '-p', 'HEAD']);

    await session.write('paths.txt', 'b.txt\n');
    await session.write('b.txt', 'b3\n');
    await session.both([
      'commit',
      '-m',
      'from file',
      '--pathspec-from-file',
      'paths.txt',
    ]);
    await session.both(['status', '--porcelain']);

    await session.both(['commit', '-a', '-m', 'nope', '--', 'a.txt']);
    await session.both(['commit', '--only', '-m', 'nope']);
    await session.both(['commit', '--include', '-m', 'nope']);
    await session.both(['commit', '-m', 'missing', '--', 'missing']);
    await session.both(['commit', '--pathspec-file-nul', '-m', 'nope']);
    expect(session.realRoot.existsSync(), isTrue);
  });

  gitParityTest('amend, fixup и повтор сообщения совпадают с git', () async {
    final session = GitParitySession();
    await session.start();
    addTearDown(session.close);

    await session.both(['init', '-b', 'main']);
    await session.both(['commit', '--amend', '-m', 'none']);
    await session.write('a.txt', 'one\n');
    await session.both(['add', 'a.txt']);
    await session.both(['commit', '-m', 'first\n\nbody']);
    await session.both(['commit', '--amend', '-m', 'amended']);
    await session.both(['cat-file', '-p', 'HEAD']);

    await session.write('a.txt', 'two\n');
    await session.both(['add', 'a.txt']);
    await session.both(['commit', '--amend', '--reset-author', '-m', 'reset']);
    await session.both(['cat-file', '-p', 'HEAD']);

    await session.write('a.txt', 'three\n');
    await session.both(['add', 'a.txt']);
    await session.both(['commit', '-C', 'HEAD', '--reset-author']);
    await session.both(['cat-file', '-p', 'HEAD']);

    await session.write('a.txt', 'four\n');
    await session.both(['add', 'a.txt']);
    await session.both(['commit', '--fixup', 'HEAD']);
    await session.both(['cat-file', '-p', 'HEAD']);

    await session.write('a.txt', 'five\n');
    await session.both(['add', 'a.txt']);
    await session.both(['commit', '--fixup', 'HEAD', '-m', 'extra body']);
    await session.both(['cat-file', '-p', 'HEAD']);

    await session.write('a.txt', 'six\n');
    await session.both(['add', 'a.txt']);
    await session.both(['commit', '--squash', 'HEAD', '-m', 'squashed body']);
    await session.both(['cat-file', '-p', 'HEAD']);

    await session.both(['commit', '--fixup', 'no-such', '-m', 'x']);
    await session.both(['commit', '--fixup=foo:bar', '-m', 'x']);
    await session.both(['commit', '--reset-author', '-m', 'x']);
    await session.both(['commit', '-m', 'x', '-F', 'a.txt']);
    await session.both(['commit', '-U5', '-m', 'x']);
    await session.both(['commit']);
    await session.both(['commit', '--edit', '-m', 'edited']);
    await session.both(['commit', '--fixup=amend:HEAD']);
    expect(session.realRoot.existsSync(), isTrue);
  });

  gitParityTest('неподдерживаемые флаги commit дают fatal', () async {
    final session = GitParitySession();
    await session.start();
    addTearDown(session.close);
    await session.both(['init', '-b', 'main']);
    await session.write('a.txt', 'one\n');
    await session.both(['add', 'a.txt']);
    await session.both(['commit', '-m', 'base']);

    for (final args in [
      ['commit', '--gpg-sign', '-m', 'x'],
      ['commit', '-S', '-m', 'x'],
      ['commit', '--interactive'],
      ['commit', '--patch'],
      ['commit', '--no-verify', '-m', 'x'],
      ['commit', '--verify', '-m', 'x'],
      ['commit', '--no-post-rewrite', '-m', 'x'],
      ['commit', '--post-rewrite', '-m', 'x'],
    ]) {
      final result = await session.virtual(args);
      expect(result.code, 128, reason: args.join(' '));
      expect(result.err, contains('fatal:'), reason: args.join(' '));
      expect(result.out, isEmpty, reason: args.join(' '));
    }
    await session.both(['rev-parse', 'HEAD']);
  });
}

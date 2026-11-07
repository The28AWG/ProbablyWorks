import 'package:test/test.dart';

import 'support/git_parity.dart';

/// Сверка `git format-patch` с системным git: код, stdout и stderr.
///
/// Подпись по умолчанию у апплета — `0.1.0`, у git — его версия, поэтому
/// байтовое сравнение идёт с `--no-signature` или `--signature=Sig`.
/// `Message-ID` содержит `time(NULL)`, его цифры нормализуются.
void main() {
  String clock(String text) =>
      text.replaceAll(RegExp(r'\.\d+\.git\.'), '.TIME.git.');

  test('format-patch: серия, заголовки и файлы совпадают с git', () async {
    final session = GitParitySession();
    await session.start();
    addTearDown(session.close);

    await session.both(['init', '-b', 'main']);
    await session.both(['format-patch', '--no-signature']);
    await session.both(['format-patch', '-1', '--no-signature']);

    await session.write('a.txt', 'one\n');
    await session.both(['add', 'a.txt']);
    await session.bothExit(['commit', '-m', 'first']);
    await session.write('b.txt', 'two\n');
    await session.both(['add', 'b.txt']);
    await session.bothExit(['commit', '-m', 'second']);
    await session.write('a.txt', 'one\nchanged\n');
    await session.both(['add', 'a.txt']);
    await session.bothExit(['commit', '-m', 'third']);

    await session.both(['format-patch', '-1', '--stdout', '--no-signature']);
    await session.both(['format-patch', '-2', '--stdout', '--no-signature']);
    await session.both([
      'format-patch',
      '-1',
      '--stdout',
      '--numbered',
      '--no-signature',
    ]);
    await session.both([
      'format-patch',
      '-2',
      '--stdout',
      '--no-numbered',
      '--no-signature',
    ]);
    await session.both([
      'format-patch',
      '-1',
      '--stdout',
      '--signoff',
      '--no-signature',
    ]);
    await session.both([
      'format-patch',
      '-1',
      '--stdout',
      '--keep-subject',
      '--no-signature',
    ]);
    await session.both([
      'format-patch',
      '-1',
      '--stdout',
      '--no-stat',
      '--no-signature',
    ]);
    await session.both([
      'format-patch',
      '-1',
      '--stdout',
      '--zero-commit',
      '--no-signature',
    ]);
    await session.both([
      'format-patch',
      '-1',
      '--stdout',
      '--subject-prefix=WIP',
      '--rfc',
      '--no-signature',
    ]);
    await session.both([
      'format-patch',
      '-1',
      '--stdout',
      '--rfc=DRAFT',
      '--no-signature',
    ]);
    await session.both([
      'format-patch',
      '-1',
      '--stdout',
      '--to=Ann <ann@ex.test>',
      '--cc=Bob <bob@ex.test>',
      '--add-header=X-Track: 7',
      '--no-signature',
    ]);
    await session.both([
      'format-patch',
      '-1',
      '--stdout',
      '--from=Commit Bot <bot@ex.test>',
      '--no-signature',
    ]);
    await session.both([
      'format-patch',
      '-1',
      '--stdout',
      '--force-in-body-from',
      '--no-signature',
    ]);
    await session.both(['format-patch', '-1', '--stdout', '--signature=Sig']);
    await session.both([
      'format-patch',
      '-1',
      'HEAD~2',
      '--stdout',
      '--no-signature',
    ]);
    await session.both([
      'format-patch',
      'HEAD~2..HEAD',
      '--stdout',
      '--no-signature',
    ]);
    await session.both([
      'format-patch',
      '-1',
      '--stdout',
      '--start-number=3',
      '--no-signature',
    ]);
    await session.both([
      'format-patch',
      '-2',
      '--stdout',
      '-v2',
      '--no-signature',
    ]);
    await session.both([
      'format-patch',
      '-1',
      '--stdout',
      '--base=HEAD~1',
      '--no-signature',
    ]);
    await session.both([
      'format-patch',
      '-1',
      '--stdout',
      '--quiet',
      '--no-signature',
    ]);

    await session.both(['format-patch', '-2', '-o', 'out', '--no-signature']);
    await session.both([
      'format-patch',
      '-1',
      '-o',
      'named',
      '--numbered-files',
      '--no-signature',
    ]);
    await session.both([
      'format-patch',
      '-1',
      '-o',
      'suf',
      '--suffix=.mbox',
      '--no-signature',
    ]);
    await session.both(['hash-object', 'out/0001-second.patch']);
    await session.both(['hash-object', 'out/0002-third.patch']);
    await session.both(['hash-object', 'named/1']);
    await session.both(['hash-object', 'suf/0001-third.mbox']);
    expect(session.realRoot.existsSync(), isTrue);
  });

  test('format-patch: обложка, thread, range-diff и ошибки', () async {
    final session = GitParitySession();
    await session.start();
    addTearDown(session.close);

    await session.both(['init', '-b', 'main']);
    await session.write('a.txt', 'one\n');
    await session.both(['add', 'a.txt']);
    await session.bothExit(['commit', '-m', 'first']);
    await session.write('b.txt', 'two\n');
    await session.both(['add', 'b.txt']);
    await session.bothExit(['commit', '-m', 'Hello, World! (v2)/part']);
    await session.write('notes.txt', 'hello\n');
    await session.both(['add', 'notes.txt']);
    await session.bothExit([
      'commit',
      '-m',
      'third line is long enough to wrap the subject when the prefix grows',
    ]);

    await session.both(['format-patch', '-1', '-o', 'slug', '--no-signature']);
    await session.both([
      'format-patch',
      '-1',
      '-o',
      'short',
      '--filename-max-length=10',
      '--no-signature',
    ]);
    await session.write('cover.txt', 'Cover subject\n\nBlurb line.\n');
    await session.both([
      'format-patch',
      '-2',
      '--stdout',
      '--cover-letter',
      '--description-file=cover.txt',
      '--cover-from-description=subject',
      '--no-signature',
    ]);
    await session.both([
      'format-patch',
      '-2',
      '--stdout',
      '--cover-letter',
      '--description-file=cover.txt',
      '--cover-from-description=message',
      '--no-signature',
    ]);
    await session.both([
      'format-patch',
      '-2',
      '--stdout',
      '--thread',
      '--no-signature',
    ], normalize: clock);
    await session.both([
      'format-patch',
      '-2',
      '--stdout',
      '--thread=deep',
      '--no-signature',
    ], normalize: clock);
    await session.both([
      'format-patch',
      '-1',
      '--stdout',
      '--thread',
      '--in-reply-to=<root@ex.test>',
      '--no-signature',
    ], normalize: clock);
    await session.both([
      'format-patch',
      '-2',
      '--stdout',
      '--interdiff=HEAD~2',
      '--no-signature',
    ]);
    await session.both([
      'format-patch',
      '-1',
      '--stdout',
      '--range-diff=HEAD~2...HEAD~1',
      '--no-signature',
    ]);
    await session.both([
      'format-patch',
      '-2',
      '--stdout',
      '--range-diff=HEAD~2',
      '--no-signature',
    ]);
    await session.both([
      'format-patch',
      '-2',
      '--stdout',
      '--no-cover-letter',
      '--range-diff=HEAD~2',
      '--no-signature',
    ]);
    await session.both([
      'format-patch',
      '-1',
      '--stdout',
      '--attach=BOUND',
      '--no-signature',
    ]);
    await session.write('sig.txt', 'Line one\nLine two\n');
    await session.both([
      'format-patch',
      '-1',
      '--stdout',
      '--signature-file=sig.txt',
    ]);

    await session.bothExit(['format-patch', '--not-a-format-patch-flag']);
    await session.bothFirstLine(['format-patch', '--not-a-format-patch-flag']);
    await session.both([
      'format-patch',
      '--cover-from-description=zzz',
      '--no-signature',
    ]);
    await session.both([
      'format-patch',
      '--creation-factor=80',
      '--no-signature',
    ]);
    await session.both(['format-patch', '--thread=nope', '--no-signature']);
    await session.both([
      'format-patch',
      '--signature-file=nope',
      '-1',
      '--stdout',
    ]);
    await session.both([
      'format-patch',
      '--from=notanemail',
      '-1',
      '--stdout',
      '--no-signature',
    ]);
    await session.both([
      'format-patch',
      '--base=no-such',
      '-1',
      '--stdout',
      '--no-signature',
    ]);
    await session.both([
      'format-patch',
      '--base=auto',
      '-1',
      '--stdout',
      '--no-signature',
    ]);
    await session.both([
      'format-patch',
      '-1',
      '--creation-factor=80',
      '--no-signature',
    ]);
    await session.both(['hash-object', 'short/0001.patch']);
    expect(session.realRoot.existsSync(), isTrue);
  });

  test('format-patch: upstream, пути и двоичный файл', () async {
    final session = GitParitySession();
    await session.start();
    addTearDown(session.close);

    await session.both(['init', '-b', 'main']);
    await session.write('root.txt', 'root\n');
    await session.both(['add', 'root.txt']);
    await session.bothExit(['commit', '-m', 'root']);
    await session.both(['branch', 'up']);
    await session.write('shared.txt', 'same\n');
    await session.both(['add', 'shared.txt']);
    await session.bothExit(['commit', '-m', 'shared on up']);
    await session.both(['checkout', 'main']);
    await session.write('shared.txt', 'same\n');
    await session.both(['add', 'shared.txt']);
    await session.bothExit(['commit', '-m', 'shared on main']);
    await session.write('only.txt', 'only\n');
    await session.both(['add', 'only.txt']);
    await session.bothExit(['commit', '-m', 'only on main']);

    await session.both([
      'format-patch',
      'up',
      '--ignore-if-in-upstream',
      '--stdout',
      '--no-signature',
    ]);
    await session.both([
      'format-patch',
      '-2',
      '--stdout',
      '--no-signature',
      '--',
      'only.txt',
    ]);
    await session.write('bin.dat', 'a\u0000b');
    await session.both(['add', 'bin.dat']);
    await session.bothExit(['commit', '-m', 'binary']);
    await session.both([
      'format-patch',
      '-1',
      '--stdout',
      '--no-binary',
      '--no-signature',
    ]);
    await session.both([
      'format-patch',
      '--ignore-if-in-upstream',
      '--no-signature',
    ]);
    expect(session.realRoot.existsSync(), isTrue);
  });
}

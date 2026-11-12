// ignore_for_file: missing-test-assertion
// Причина: сверка кода и текста спрятана в GitParitySession.both.
import 'package:test/test.dart';

import 'support/git_parity.dart';

/// Сверка `git branch` с системным git: код, stdout и stderr.
void main() {
  gitParityTest('список, upstream, формат и ошибки совпадают с git', () async {
    final session = GitParitySession();
    await session.start();
    addTearDown(session.close);

    await session.both(['init', '-b', 'main']);
    await session.write('a.txt', 'a\n');
    await session.both(['add', 'a.txt']);
    await session.both(['commit', '-m', 'first subject']);
    await session.write('a.txt', 'b\n');
    await session.both(['commit', '-am', 'second subject']);
    await session.both(['branch', 'topic']);
    await session.both(['branch', 'feature/One']);
    await session.both(['branch']);
    await session.both(['branch', '--show-current']);
    await session.both(['branch', 'topic*']);
    await session.both(['config', 'advice.refSyntax', 'false']);
    await session.both(['branch', 'topic*']);
    await session.both(['config', 'advice.refSyntax', 'true']);

    await session.both(['switch', '--detach', 'topic']);
    await session.both(['branch']);
    await session.both(['branch', '--show-current']);
    await session.both(['branch', '-m', 'new']);
    await session.both(['branch', '--edit-description']);
    await session.both(['switch', 'main']);

    await session.both(['branch', 'side']);
    await session.both(['switch', 'side']);
    await session.write('a.txt', 'side\n');
    await session.both(['commit', '-am', 'side only']);
    await session.both(['switch', 'main']);
    await session.both(['branch', 'remote-tip']);
    await session.both(['switch', 'remote-tip']);
    await session.write('a.txt', 'remote\n');
    await session.both(['commit', '-am', 'remote tip']);
    await session.both(['switch', 'main']);

    await session.both(['update-ref', 'refs/remotes/origin/main', 'HEAD']);
    await session.both([
      'symbolic-ref',
      'refs/remotes/origin/HEAD',
      'refs/remotes/origin/main',
    ]);
    await session.both(['branch', '-a']);
    await session.both(['branch', '-r']);
    await session.both(['branch', '--color=always']);
    await session.both(['branch', '-a', '--color=always']);
    await session.both(['branch', '-v']);
    await session.both(['branch', '-u', 'origin/main']);
    await session.both(['remote', 'add', 'origin', '/tmp/origin.git']);
    await session.both(['branch', '-u', 'origin/main']);
    await session.both(['branch', '-vv']);
    await session.both(['branch', '-v', '--color=always']);
    await session.both(['branch', '--track', 'tracked', 'origin/main']);
    await session.both(['branch', '--no-track', 'plain', 'origin/main']);
    await session.both(['branch', '--track=inherit', 'inh', 'tracked']);
    await session.both(['branch', '--track=inherit', 'badinh', 'topic']);
    await session.both(['config', '--get', 'branch.tracked.remote']);
    await session.both(['config', '--get', 'branch.tracked.merge']);
    await session.both(['config', '--get', 'branch.plain.remote']);
    await session.both(['branch', '--unset-upstream', 'topic']);
    await session.both(['branch', '--unset-upstream', 'topic']);

    await session.both(['branch', '-d', 'plain']);
    await session.both(['branch', '-d', 'side']);
    await session.both(['config', 'advice.forceDeleteBranch', 'false']);
    await session.both(['branch', '-d', 'side']);
    await session.both(['branch', '-D', 'side']);
    await session.both(['branch', '-d', 'nope']);
    await session.both(['branch', '-d', 'origin/main']);
    await session.both(['branch', '-d', 'main']);
    await session.both(['branch', '-a', '-d', 'topic']);
    await session.both(['branch', '-q', '-d', 'badinh']);

    await session.both(['branch', '-c', 'topic', 'topic-copy']);
    await session.both(['reflog', 'topic-copy']);
    await session.both(['branch', '-c', 'topic', 'topic-copy']);
    await session.both(['branch', '-C', 'tracked', 'topic-copy']);
    await session.both(['config', '--get', 'branch.topic-copy.remote']);

    await session.write('a.txt', 'ahead\n');
    await session.both(['commit', '-am', 'ahead one']);
    await session.both(['branch', '-vv']);
    await session.both(['branch', '-v']);
    await session.both([
      'update-ref',
      'refs/remotes/origin/main',
      'remote-tip',
    ]);
    await session.both(['branch', '-vv']);
    await session.write('a.txt', 'diverge\n');
    await session.both(['commit', '-am', 'diverge']);
    await session.both(['branch', '-vv']);
    await session.both(['branch', '--format=%(upstream:trackshort)']);
    await session.both(['update-ref', '-d', 'refs/remotes/origin/main']);
    await session.both(['branch', '-vv']);
    await session.both(['update-ref', 'refs/remotes/origin/main', 'HEAD']);

    await session.both(['branch', '--list', 'feature*']);
    await session.both(['branch', '-i', '--list', '*one']);
    await session.both(['branch', '--contains', 'HEAD']);
    await session.both(['branch', '--no-contains', 'HEAD~1']);
    await session.both(['branch', '--merged']);
    await session.both(['branch', '--no-merged']);
    await session.both(['branch', '--points-at', 'HEAD']);
    await session.both(['branch', '--contains', '--list']);
    await session.both(['branch', '--points-at']);
    await session.both([
      'branch',
      '--format=%(refname:short) %(objectname:short=4)',
    ]);
    await session.both(['branch', '--format=%(nope)']);
    await session.both(['branch', '--format=%(refname:foo)']);
    await session.both([
      'branch',
      '--format=%(align:10,right)%(refname:short)%(end)|',
    ]);
    await session.both([
      'branch',
      '--format=%(authorname) %(authordate) %(authordate:unix)',
    ]);
    await session.both(['branch', '--format=%%n%(refname:short)']);
    await session.both([
      'branch',
      '--omit-empty',
      '--format=%(if:equals=nope)%(refname:short)%(then)x%(end)',
    ]);
    await session.both(['branch', '--sort=-refname']);
    await session.both(['branch', 'b2']);
    await session.both(['branch', 'b10']);
    await session.both(['branch', '--sort=version:refname']);
    await session.both(['branch', '--sort=nope']);
    await session.both(['branch', '-v', '--abbrev=0']);
    await session.both(['branch', '-v', '--abbrev=3']);
    await session.both(['branch', '-v', '--no-abbrev']);
    await session.both(['branch', '-v', '--abbrev=nope']);
    await session.both(['branch', '--color=nope']);
    await session.both(['branch', '--track=nope', 'x']);
    await session.both(['branch', '--column=nope']);
    await session.both(['branch', '--column', '-v']);
    await session.both(['branch', '--column=never', '-v']);
    await session.both(['branch', '--column=auto']);
    await session.both(['branch', '--no-column']);
    await session.both(['branch', '-m', '-d', 'x']);
    await session.both(['branch', '--nope']);
    await session.both(['branch', '--edit-description', 'a', 'b']);
    await session.both(['branch', '--edit-description', 'missing']);
    await session.both(['branch', '--recurse-submodules', 'rec']);
    await session.both(['config', 'submodule.propagateBranches', 'true']);
    await session.both(['branch', '--recurse-submodules', 'rec2']);
    await session.both(['branch', '--recurse-submodules', '-d', 'rec2']);
    await session.both(['branch', '-u', 'origin/missing']);
    await session.both(['config', 'advice.setUpstreamFailure', 'false']);
    await session.both(['branch', '-u', 'origin/missing']);
    await session.both(['branch', 'zz', 'origin/topic']);
    await session.both(['config', 'core.logAllRefUpdates', 'false']);
    await session.both(['branch', 'nologged']);
    await session.both(['branch', '--create-reflog', 'logged']);
    await session.both(['reflog', 'logged']);
    await session.both(['reflog', 'nologged']);
  });

  gitParityTest('колонки при COLUMNS=40 совпадают с git', () async {
    final session = GitParitySession(
      environment: {...gitParityEnvironment, 'COLUMNS': '40'},
    );
    await session.start();
    addTearDown(session.close);
    await session.both(['init', '-b', 'main']);
    await session.write('a.txt', 'a\n');
    await session.both(['add', 'a.txt']);
    await session.both(['commit', '-m', 'first']);
    await session.both(['branch', 'badinh']);
    await session.both(['branch', 'feature/One']);
    await session.both(['branch', 'inh']);
    await session.both(['branch', 'renamed']);
    await session.both(['branch', 'topic-copy']);
    await session.both(['branch', 'tracked']);
    await session.both(['branch', '--column']);
    await session.both(['branch', '--column=row']);
    await session.both(['branch', '--column=dense']);
    await session.both(['branch', '--column=plain']);
  });

  gitParityTest('пустой репозиторий печатает текущую ветку', () async {
    final session = GitParitySession();
    await session.start();
    addTearDown(session.close);
    await session.both(['init', '-b', 'main']);
    await session.both(['branch']);
    await session.both(['branch', '--show-current']);
    await session.both(['branch', '--edit-description']);
  });
}

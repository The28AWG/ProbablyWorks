// ignore_for_file: avoid-substring
// Причина: короткие хеши и fanout LFS режутся по фиксированной длине, как в git.
part of '../git_extra_commands.dart';

/// cherry-pick, revert и rebase поверх уже записанных коммитов.
Future<int> _cherryPick(
  AppletIo io,
  List<String> args,
  List<({String key, String value})> config,
) async {
  const usage = 'usage: git cherry-pick [<options>] <commit>...';
  final parsed = parseGitArgs(args, const [
    GitOption('continue'),
    GitOption('abort'),
    GitOption('skip'),
    GitOption('edit', negatable: true),
    GitOption('mainline', short: 'm', valued: true),
  ], usage: usage);
  final repo = await _repo(io);
  final signature = _signature(io, config);
  if (parsed.has('abort')) {
    await repo.sequencerAbort(reflogActor: signature);
    return 0;
  }
  if (parsed.has('continue')) {
    await repo.sequencerContinue(committer: signature);
    return 0;
  }
  if (parsed.has('skip')) {
    return _skipReplay(
      io,
      repo,
      command: 'cherry-pick',
      author: signature,
      committer: signature,
    );
  }
  if (parsed.has('edit')) throw const GitUsage(_replayEditorUnset, exitCode: 1);
  if (parsed.operands.isEmpty) throw const GitUsage('$usage\n');
  return _replayCommits(
    io,
    repo,
    revisions: await _expandPickOperands(
      repo,
      parsed.operands,
      failed: 'cherry-pick',
    ),
    author: signature,
    committer: signature,
    mainline: _mainline(parsed),
    revert: false,
  );
}

Future<int> _revert(
  AppletIo io,
  List<String> args,
  List<({String key, String value})> config,
) async {
  const usage = 'usage: git revert [<options>] <commit>...';
  final parsed = parseGitArgs(args, const [
    GitOption('skip'),
    GitOption('edit', negatable: true),
    GitOption('mainline', short: 'm', valued: true),
  ], usage: usage);
  final repo = await _repo(io);
  final author = _signature(io, config);
  if (parsed.has('skip')) {
    return _skipReplay(
      io,
      repo,
      command: 'revert',
      author: author,
      committer: author,
    );
  }
  if (parsed.has('edit')) throw const GitUsage(_replayEditorUnset, exitCode: 1);
  if (parsed.operands.isEmpty) throw const GitUsage('$usage\n');
  return _replayCommits(
    io,
    repo,
    revisions: await _expandPickOperands(
      repo,
      parsed.operands,
      failed: 'revert',
    ),
    author: author,
    committer: author,
    mainline: _mainline(parsed),
    revert: true,
  );
}

Future<int> _rebase(
  AppletIo io,
  List<String> args,
  List<({String key, String value})> config,
) async {
  final parsed = parseGitArgs(args, const [
    GitOption('onto', valued: true),
    GitOption('continue'),
    GitOption('abort'),
  ], usage: 'usage: git rebase [--onto <newbase>] <upstream>');
  final repo = await _repo(io);
  if (parsed.has('abort')) {
    await repo.sequencerAbort(reflogActor: _signature(io, config));
    return 0;
  }
  if (parsed.has('continue')) {
    await repo.sequencerContinue(committer: _signature(io, config));
    return 0;
  }
  if (parsed.operands.length != 1) {
    throw const GitUsage('usage: git rebase <upstream>\n');
  }
  final upstream = parsed.operands.single;
  if (await repo.revParse(upstream) == null) {
    throw GitUsage("fatal: invalid upstream '$upstream'\n", exitCode: 128);
  }
  final onto = parsed.value('onto');
  if (onto != null && await repo.revParse(onto) == null) {
    throw GitUsage(
      "fatal: Does not point to a valid commit '$onto'\n",
      exitCode: 128,
    );
  }
  final head = await repo.readReference('HEAD');
  final branch = _branchName(head?.targetReferenceName);
  final count = await repo.rebase(
    upstream,
    onto: onto,
    committer: _signature(io, config),
    onStep: (index, total) {
      io.stderr.writeText('Rebasing ($index/$total)\r');
    },
  );
  if (count == 0) {
    io.stdout.writeText(
      branch == null
          ? 'HEAD is up to date.\n'
          : 'Current branch $branch is up to date.\n',
    );
    return 0;
  }
  io.stderr.writeText(
    branch == null
        ? 'Successfully rebased and updated detached HEAD.\n'
        : 'Successfully rebased and updated refs/heads/$branch.\n',
  );
  return 0;
}

const _replayEditorUnset =
    'error: Terminal is dumb, but EDITOR unset\n'
    'Please supply the message using either -m or -F option.\n';

Future<int> _skipReplay(
  AppletIo io,
  GitRepository repo, {
  required String command,
  required GitCommitSignature author,
  required GitCommitSignature committer,
}) async {
  final state = await repo.readSequencer();
  if (state == null || state.action != command) {
    throw GitUsage(
      'error: no $command in progress\n'
      'fatal: $command failed\n',
      exitCode: 128,
    );
  }
  final rest = state.revisions.length <= 1
      ? const <String>[]
      : state.revisions.sublist(1);
  await repo.clearSequencer();
  if (rest.isEmpty) return 0;
  return _replayCommits(
    io,
    repo,
    revisions: rest,
    author: author,
    committer: committer,
    mainline: null,
    revert: command == 'revert',
  );
}

int? _mainline(GitInvocation parsed) {
  if (!parsed.has('mainline')) return null;
  final raw = parsed.value('mainline');
  final value = raw == null ? null : int.tryParse(raw);
  if (value == null || value < 1) {
    throw const GitUsage(
      "error: option `mainline' expects a number greater than zero\n",
    );
  }
  return value;
}

Future<List<String>> _expandPickOperands(
  GitRepository repo,
  List<String> operands, {
  required String failed,
}) async {
  final out = <String>[];
  for (final operand in operands) {
    if (operand.contains('...')) {
      out.add(operand);
      continue;
    }
    final dots = operand.indexOf('..');
    if (dots < 0) {
      out.add(operand);
      continue;
    }
    final base = dots == 0 ? 'HEAD' : operand.substring(0, dots);
    final tipRaw = operand.substring(dots + 2);
    final tip = tipRaw.isEmpty ? 'HEAD' : tipRaw;
    if (await repo.revParse(base) == null) {
      throw GitUsage("fatal: bad revision '$base'\n", exitCode: 128);
    }
    if (await repo.revParse(tip) == null) {
      throw GitUsage("fatal: bad revision '$tip'\n", exitCode: 128);
    }
    final entries = await repo.revListAncestryPath(
      base: base,
      tip: tip,
      excludeMerges: false,
    );
    for (final entry in entries) {
      out.add(entry.objectId.hex);
    }
  }
  if (out.isEmpty) {
    throw GitUsage(
      'error: empty commit set passed\n'
      'fatal: $failed failed\n',
      exitCode: 128,
    );
  }
  return out;
}

Future<int> _replayCommits(
  AppletIo io,
  GitRepository repo, {
  required List<String> revisions,
  required GitCommitSignature author,
  required GitCommitSignature committer,
  required int? mainline,
  required bool revert,
}) async {
  final command = revert ? 'revert' : 'cherry-pick';
  for (var index = 0; index < revisions.length; index++) {
    final loaded = await _loadReplayCommit(repo, revisions[index]);
    _checkMainline(loaded.commit, loaded.hex, mainline, command);
    final parentIndex = (mainline ?? 1) - 1;
    final id = revert
        ? await repo.revert(
            revisions[index],
            author: author,
            committer: committer,
            parentIndex: parentIndex,
          )
        : await repo.cherryPick(
            revisions[index],
            committer: committer,
            parentIndex: parentIndex,
          );
    if (id == null) {
      final rest = <String>[loaded.hex];
      for (final later in revisions.sublist(index + 1)) {
        rest.add((await repo.revParse(later))?.hex ?? later);
      }
      await repo.rememberSequencer(command, rest);
      _writeEmptyReplay(io, command);
      final report = await repo.status();
      final head = await repo.readReference('HEAD');
      writeGitLongStatus(
        io,
        branch: _branchName(head?.targetReferenceName),
        committed: await repo.revParse('HEAD') != null,
        report: report,
        showUntracked: true,
        sequencerAction: command,
        sequencerAbbr: _abbr(loaded.hex),
      );
      return 1;
    }
    final stored = const GitCommitCodec().decode(
      (await repo.show(id.hex))!.bytes,
    );
    await writeGitCommitSummary(
      io,
      repo,
      id: id,
      message: stored.message,
      author: stored.author,
      committer: stored.committer,
      showDate: true,
      initialCommit: false,
    );
  }
  return 0;
}

Future<({GitCommit commit, String hex})> _loadReplayCommit(
  GitRepository repo,
  String revision,
) async {
  final id = await repo.revParse(revision);
  final object = id == null ? null : await repo.show(id.hex);
  if (id == null || object == null || object.type != GitObjectType.commit) {
    throw GitUsage("fatal: bad revision '$revision'\n", exitCode: 128);
  }
  return (commit: const GitCommitCodec().decode(object.bytes), hex: id.hex);
}

void _checkMainline(
  GitCommit commit,
  String hex,
  int? mainline,
  String command,
) {
  if (commit.parents.length > 1 && mainline == null) {
    throw GitUsage(
      'error: commit $hex is a merge but no -m option was given.\n'
      'fatal: $command failed\n',
      exitCode: 128,
    );
  }
  if (mainline != null && mainline > commit.parents.length) {
    throw GitUsage(
      'error: commit $hex does not have parent $mainline\n'
      'fatal: $command failed\n',
      exitCode: 128,
    );
  }
}

void _writeEmptyReplay(AppletIo io, String command) {
  io.stderr.writeText(
    'The previous $command is now empty, possibly due to conflict resolution.\n'
    'If you wish to commit it anyway, use:\n'
    '\n'
    '    git commit --allow-empty\n'
    '\n'
    'Otherwise, please use \'git $command --skip\'\n',
  );
}

String? _branchName(String? reference) {
  const prefix = 'refs/heads/';
  if (reference == null || !reference.startsWith(prefix)) return null;
  return reference.substring(prefix.length);
}

part of '../git_branch_command.dart';

/// Создание, удаление, переименование ветки и upstream.
Future<bool> _propagate(GitRepository repo) async {
  final value = (await repo.configGet('submodule.propagateBranches'))
      ?.toLowerCase();
  return value == 'true' || value == 'yes' || value == 'on' || value == '1';
}

Future<bool> _hasSubmodule(GitRepository repo) async {
  if (await File(p.join(repo.path, '.gitmodules')).exists()) return true;
  final index = await repo.readIndex();
  if (index == null) return false;
  for (final entry in index.entries) {
    if (entry.mode == GitIndexEntry.gitLinkMode) return true;
  }
  return false;
}

int _abbrev(GitInvocation parsed) {
  if (parsed.isNegated('abbrev')) return 0;
  if (!parsed.has('abbrev')) return 7;
  final raw = parsed.value('abbrev') ?? '';
  if (raw.isEmpty) return 7;
  final number = int.tryParse(raw);
  if (number == null) {
    throw const GitUsage("error: option `abbrev' expects a numerical value\n");
  }
  if (number <= 0) return 0;
  if (number < 4) return 4;
  return number;
}

bool _color(GitInvocation parsed) {
  if (parsed.isNegated('color') || !parsed.has('color')) return false;
  final raw = parsed.value('color') ?? '';
  final mode = raw.isEmpty ? 'always' : raw;
  return switch (mode) {
    'always' => true,
    'never' || 'auto' => false,
    _ => throw const GitUsage(
      'error: option `color\' expects "always", "auto", or "never"\n',
    ),
  };
}

_Track _trackRequest(GitInvocation parsed) {
  if (parsed.isNegated('track')) return _Track.no;
  if (!parsed.has('track')) return _Track.auto;
  final raw = parsed.value('track') ?? '';
  return switch (raw) {
    '' || 'direct' => _Track.direct,
    'inherit' => _Track.inherit,
    _ => throw const GitUsage(
      'error: option `--track\' expects "direct" or "inherit"\n',
    ),
  };
}

_Columns _columns(GitInvocation parsed) {
  if (parsed.isNegated('column') || !parsed.has('column')) {
    return const _Columns.off();
  }
  final raw = parsed.value('column') ?? '';
  if (raw.isEmpty) return const _Columns(_Col.down);
  var mode = _Col.down;
  var dense = false;
  for (final part in raw.split(',')) {
    switch (part) {
      case '' || 'always' || 'column':
        mode = _Col.down;
      case 'row':
        mode = _Col.across;
      case 'plain':
        mode = _Col.plain;
      case 'never' || 'auto':
        return const _Columns.off();
      case 'dense':
        dense = true;
      case 'nodense':
        dense = false;
      case _:
        throw GitUsage("error: unsupported option '$part'\n");
    }
  }
  if (mode == _Col.plain) return const _Columns(_Col.plain);
  return _Columns(mode, dense: dense);
}

Future<int> _showCurrent(AppletIo io, GitRepository repo) async {
  final head = await repo.readReference('HEAD');
  if (head == null) {
    throw const GitUsage('fatal: could not resolve HEAD\n', exitCode: 128);
  }
  if (!head.isSymbolic) return 0;
  final target = head.targetReferenceName;
  if (target == null || !target.startsWith('refs/heads/')) {
    throw GitUsage(
      'fatal: HEAD ($target) points outside of refs/heads/\n',
      exitCode: 128,
    );
  }
  io.stdout.writeText(
    '${_slice(target, 'refs/heads/'.length, target.length)}\n',
  );
  return 0;
}

Future<int> _editDescription(
  AppletIo io,
  GitRepository repo,
  GitInvocation parsed,
) async {
  if (parsed.operands.length > 1) {
    throw const GitUsage(
      'fatal: cannot edit description of more than one branch\n',
      exitCode: 128,
    );
  }
  final head = await repo.readReference('HEAD');
  final current = _branchOf(head?.targetReferenceName);
  if (parsed.operands.isEmpty && (head == null || !head.isSymbolic)) {
    throw const GitUsage(
      'fatal: cannot give description to detached HEAD\n',
      exitCode: 128,
    );
  }
  final name = parsed.operands.isEmpty ? current : parsed.operands.first;
  if (name == null) {
    throw const GitUsage(
      'fatal: cannot give description to detached HEAD\n',
      exitCode: 128,
    );
  }
  if (await repo.readReference('refs/heads/$name') == null && current != name) {
    io.stderr.writeText("error: no branch named '$name'\n");
    return 1;
  }
  if (await repo.resolveReferenceObjectId('refs/heads/$name') == null) {
    io.stderr.writeText("error: no commit on branch '$name' yet\n");
    return 1;
  }
  io.stderr.writeText('error: Terminal is dumb, but EDITOR unset\n');
  return 1;
}

Future<int> _delete(
  AppletIo io,
  GitRepository repo,
  GitInvocation parsed,
) async {
  if (parsed.has('all')) {
    throw const GitUsage('fatal: cannot use -a with -d\n', exitCode: 128);
  }
  if (parsed.operands.isEmpty) {
    throw const GitUsage('fatal: branch name required\n', exitCode: 128);
  }
  final remote = parsed.has('remotes');
  final force = parsed.has('force-delete') || parsed.has('force');
  final head = await repo.readReference('HEAD');
  final current = _branchOf(head?.targetReferenceName);
  final advice = _adviceOff(await repo.configGet('advice.forceDeleteBranch'));
  var failed = false;
  for (final name in parsed.operands) {
    final reference = remote ? 'refs/remotes/$name' : 'refs/heads/$name';
    final id = await repo.resolveReferenceObjectId(reference);
    if (id == null) {
      failed = true;
      if (!remote &&
          await repo.resolveReferenceObjectId('refs/remotes/$name') != null) {
        io.stderr.writeText(
          "error: branch '$name' not found.\nDid you forget --remote?\n",
        );
      } else if (remote) {
        io.stderr.writeText(
          "error: remote-tracking branch '$name' not found\n",
        );
      } else {
        io.stderr.writeText("error: branch '$name' not found\n");
      }
      continue;
    }
    if (!remote && current == name) {
      failed = true;
      io.stderr.writeText(
        "error: cannot delete branch '$name' used by worktree at '${repo.path}'\n",
      );
      continue;
    }
    if (!remote && !force) {
      final base = await repo.mergeBase(name, 'HEAD');
      if (base != id) {
        failed = true;
        final hint = advice
            ? ''
            : "hint: If you are sure you want to delete it, run 'git branch -D $name'\n"
                  'hint: Disable this message with "git config set advice.forceDeleteBranch false"\n';
        io.stderr.writeText(
          "error: the branch '$name' is not fully merged\n$hint",
        );
        continue;
      }
    }
    await repo.deleteReference(reference);
    final log = File(repo.resolveReflogPath(reference));
    if (await log.exists()) await log.delete();
    if (!remote) await repo.configDeleteSubsection('branch', name);
    if (!parsed.has('quiet')) {
      final kind = remote ? 'remote-tracking branch' : 'branch';
      io.stdout.writeText(
        'Deleted $kind $name (was ${_slice(id.hex, 0, 7)}).\n',
      );
    }
  }
  return failed ? 1 : 0;
}

Future<int> _transfer(
  AppletIo io,
  GitRepository repo,
  GitInvocation parsed, {
  required GitCommitSignature committer,
  required bool copy,
  required bool force,
}) async {
  if (parsed.operands.isEmpty || parsed.operands.length > 2) {
    throw const GitUsage(_conflict);
  }
  final head = await repo.readReference('HEAD');
  final current = _branchOf(head?.targetReferenceName);
  final from = parsed.operands.length == 2 ? parsed.operands.first : current;
  final to = parsed.operands.length == 2
      ? parsed.operands[1]
      : parsed.operands.first;
  if (from == null) {
    final verb = copy ? 'copy' : 'rename';
    throw GitUsage(
      'fatal: cannot $verb the current branch while not on any\n',
      exitCode: 128,
    );
  }
  await _rejectName(repo, to);
  final id = await repo.resolveReferenceObjectId('refs/heads/$from');
  if (id == null) {
    io.stderr.writeText("fatal: no branch named '$from'\n");
    return 128;
  }
  if (await repo.readReference('refs/heads/$to') != null && !force) {
    io.stderr.writeText("fatal: a branch named '$to' already exists\n");
    return 128;
  }
  await repo.writeReference(GitReference.direct('refs/heads/$to', id));
  if (!copy && current == from) {
    await repo.writeReference(GitReference.symbolic('HEAD', 'refs/heads/$to'));
  }
  await _moveReflog(
    repo,
    from: 'refs/heads/$from',
    to: 'refs/heads/$to',
    id: id,
    verb: copy ? 'copied' : 'renamed',
    keepSource: copy,
    committer: committer,
  );
  if (copy) {
    await repo.configCopySubsection('branch', from, to);
  } else {
    await repo.deleteReference('refs/heads/$from');
    final tracking = await repo.branchTracking(from);
    if (tracking != null) {
      await repo.setBranchTracking(
        GitBranchTracking(
          branchName: to,
          referenceName: 'refs/heads/$to',
          remoteName: tracking.remoteName,
          mergeReferenceName: tracking.mergeReferenceName,
        ),
      );
      await repo.deleteBranchTracking(from);
    }
  }
  return 0;
}

/// Журнал копируется целиком, последняя строка — `Branch: renamed|copied`.
///
/// Актор берётся из предыдущей строки: так байты совпадают с git, когда
/// личность в окружении не менялась между записями.
Future<void> _moveReflog(
  GitRepository repo, {
  required String from,
  required String to,
  required GitObjectId id,
  required String verb,
  required bool keepSource,
  required GitCommitSignature committer,
}) async {
  final oldLog = File(repo.resolveReflogPath(from));
  final exists = await oldLog.exists();
  if (!exists) return;
  final text = await oldLog.readAsString();
  final lines = const LineSplitter().convert(text);
  final last = lines.isEmpty ? '' : lines.last;
  final tab = last.indexOf('\t');
  final header = tab < 0 ? '' : _slice(last, 0, tab);
  final firstSpace = header.indexOf(' ');
  final actor = firstSpace < 0
      ? '${committer.name} <${committer.email}> ${committer.timestampSeconds} ${committer.timezoneOffset}'
      : _slice(header, header.indexOf(' ', firstSpace + 1) + 1, header.length);
  final body = text.endsWith('\n') ? text : '$text\n';
  final newLog = File(repo.resolveReflogPath(to));
  await newLog.parent.create(recursive: true);
  await newLog.writeAsString(
    '$body${id.hex} ${id.hex} $actor\tBranch: $verb $from to $to\n',
  );
  if (!keepSource) await oldLog.delete();
}

Future<int> _setUpstream(
  AppletIo io,
  GitRepository repo,
  GitInvocation parsed,
) async {
  final upstream = parsed.value('set-upstream-to') ?? '';
  final head = await repo.readReference('HEAD');
  final current = _branchOf(head?.targetReferenceName);
  if (parsed.operands.length > 1) throw const GitUsage(_conflict);
  final name = parsed.operands.isEmpty ? current : parsed.operands.first;
  if (name == null) {
    throw GitUsage(
      'fatal: could not set upstream of HEAD to $upstream '
      'when it does not point to any branch\n',
      exitCode: 128,
    );
  }
  if (await repo.readReference('refs/heads/$name') == null) {
    throw GitUsage("fatal: branch '$name' does not exist\n", exitCode: 128);
  }
  final target = await _upstreamTarget(repo, upstream, explicit: true);
  await repo.setBranchTracking(
    GitBranchTracking(
      branchName: name,
      referenceName: 'refs/heads/$name',
      remoteName: target.remote,
      mergeReferenceName: target.merge,
    ),
  );
  if (!parsed.has('quiet')) {
    io.stdout.writeText("branch '$name' set up to track '${target.label}'.\n");
  }
  return 0;
}

Future<int> _unsetUpstream(GitRepository repo, GitInvocation parsed) async {
  final head = await repo.readReference('HEAD');
  final current = _branchOf(head?.targetReferenceName);
  if (parsed.operands.length > 1) throw const GitUsage(_conflict);
  final name = parsed.operands.isEmpty ? current : parsed.operands.first;
  if (name == null) {
    throw const GitUsage(
      'fatal: could not unset upstream of HEAD when it does not point to any branch\n',
      exitCode: 128,
    );
  }
  if (await repo.readReference('refs/heads/$name') == null) {
    throw GitUsage("fatal: branch '$name' does not exist\n", exitCode: 128);
  }
  final tracking = await repo.branchTracking(name);
  if (tracking == null) {
    throw GitUsage(
      "fatal: branch '$name' has no upstream information\n",
      exitCode: 128,
    );
  }
  await repo.configUnset('branch.$name.remote');
  await repo.configUnset('branch.$name.merge');
  return 0;
}

Future<int> _create(
  AppletIo io,
  GitRepository repo,
  GitInvocation parsed, {
  required GitCommitSignature committer,
}) async {
  if (parsed.operands.length > 2) throw const GitUsage(_conflict);
  final name = parsed.operands.first;
  await _rejectName(repo, name);
  final start = parsed.operands.length == 2 ? parsed.operands[1] : 'HEAD';
  if (await repo.revParse(start) == null) {
    throw GitUsage("fatal: not a valid object name: '$start'\n", exitCode: 128);
  }
  if (await repo.readReference('refs/heads/$name') != null &&
      !parsed.has('force')) {
    throw GitUsage(
      "fatal: a branch named '$name' already exists\n",
      exitCode: 128,
    );
  }
  final request = _trackRequest(parsed);
  final target = await _maybeUpstream(io, repo, start, request);
  final reflog = parsed.has('create-reflog') || await _logUpdates(repo);
  await repo.branch(
    name,
    startPoint: start,
    force: parsed.has('force'),
    writeReflog: reflog,
    reflogActor: committer,
  );
  if (target != null) {
    await repo.setBranchTracking(
      GitBranchTracking(
        branchName: name,
        referenceName: 'refs/heads/$name',
        remoteName: target.remote,
        mergeReferenceName: target.merge,
      ),
    );
    if (!parsed.has('quiet')) {
      io.stdout.writeText(
        "branch '$name' set up to track '${target.label}'.\n",
      );
    }
  }
  return 0;
}

Future<bool> _logUpdates(GitRepository repo) async {
  final value = (await repo.configGet('core.logAllRefUpdates'))?.toLowerCase();
  if (value == null) return !repo.bare;
  return value != 'false' && value != '0' && value != 'no' && value != 'off';
}

Future<_Upstream?> _maybeUpstream(
  AppletIo io,
  GitRepository repo,
  String start,
  _Track request,
) async {
  if (request == _Track.no) return null;
  final setup = (await repo.configGet('branch.autoSetupMerge'))?.toLowerCase();
  final mode = switch (request) {
    _Track.direct => _Track.direct,
    _Track.inherit => _Track.inherit,
    _Track.no => _Track.no,
    _Track.auto => switch (setup) {
      'false' || 'never' => _Track.no,
      'always' => _Track.direct,
      'inherit' => _Track.inherit,
      _ => _Track.direct,
    },
  };
  if (mode == _Track.no) return null;
  final resolved = await _resolveBranch(repo, start);
  if (mode == _Track.inherit) {
    if (resolved != null && resolved.reference.startsWith('refs/remotes/')) {
      return _upstreamTarget(repo, start, explicit: request != _Track.auto);
    }
    final source = resolved == null ? null : _branchOf(resolved.reference);
    final tracking = source == null ? null : await repo.branchTracking(source);
    if (tracking == null) {
      io.stderr.writeText(
        "warning: asked to inherit tracking from '$start', but no remote is set\n",
      );
      return null;
    }
    return _Upstream(
      remote: tracking.remoteName,
      merge: tracking.mergeReferenceName,
      label: _upstreamLabel(tracking.remoteName, tracking.mergeReferenceName),
    );
  }
  final remoteStart =
      resolved != null && resolved.reference.startsWith('refs/remotes/');
  if (request == _Track.auto && setup != 'always' && !remoteStart) {
    return null;
  }
  return _upstreamTarget(repo, start, explicit: request != _Track.auto);
}

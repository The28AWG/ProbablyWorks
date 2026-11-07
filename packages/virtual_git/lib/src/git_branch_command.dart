/// `git branch`: список, создание, переименование, копирование и upstream.
///
/// Справка git 2.53 разбирается целиком. Неизвестное имя — код 129.
/// Редактор описания не запускается: та же строка `EDITOR unset`, что у git
/// без `EDITOR`. Обход настоящих подмодулей в виртуальном хосте не делается:
/// при `submodule.propagateBranches=true` и gitlink/`.gitmodules` команда
/// завершается явным `fatal`, а не молча создаёт только локальную ветку.
library;

import 'dart:convert';

import 'package:virtual_git/src/git_branch_tracking.dart';
import 'package:virtual_git/src/git_cli.dart';
import 'package:virtual_git/src/git_commit.dart';
import 'package:virtual_git/src/git_commit_codec.dart';
import 'package:virtual_git/src/git_host_io.dart';
import 'package:virtual_git/src/git_index.dart';
import 'package:virtual_git/src/git_object_id.dart';
import 'package:virtual_git/src/git_object_type.dart';
import 'package:virtual_git/src/git_path.dart' as p;
import 'package:virtual_git/src/git_reference.dart';
import 'package:virtual_git/src/git_repository.dart';
import 'package:virtual_host/virtual_host.dart';

const _usage =
    'usage: git branch [<options>] [-r | -a] [--merged] [--no-merged]\n'
    '   or: git branch [<options>] [-f] [--recurse-submodules] <branch-name> [<start-point>]\n'
    '   or: git branch [<options>] [-l] [<pattern>...]\n'
    '   or: git branch [<options>] [-r] (-d | -D) <branch-name>...\n'
    '   or: git branch [<options>] (-m | -M) [<old-branch>] <new-branch>\n'
    '   or: git branch [<options>] (-c | -C) [<old-branch>] <new-branch>\n'
    '   or: git branch [<options>] [-r | -a] [--points-at]\n'
    '   or: git branch [<options>] [-r | -a] [--format]\n'
    '\n'
    'Generic options\n'
    '    -v, --[no-]verbose    show hash and subject, give twice for upstream branch\n'
    '    -q, --[no-]quiet      suppress informational messages\n'
    '    -t, --[no-]track[=(direct|inherit)]\n'
    '                          set branch tracking configuration\n'
    '    -u, --[no-]set-upstream-to <upstream>\n'
    '                          change the upstream info\n'
    '    --[no-]unset-upstream unset the upstream info\n'
    '    --[no-]color[=<when>] use colored output\n'
    '    -r, --remotes         act on remote-tracking branches\n'
    '    --contains <commit>   print only branches that contain the commit\n'
    '    --no-contains <commit>\n'
    '                          print only branches that don\'t contain the commit\n'
    '    --[no-]abbrev[=<n>]   use <n> digits to display object names\n'
    '\n'
    'Specific git-branch actions:\n'
    '    -a, --all             list both remote-tracking and local branches\n'
    '    -d, --[no-]delete     delete fully merged branch\n'
    '    -D                    delete branch (even if not merged)\n'
    '    -m, --[no-]move       move/rename a branch and its reflog\n'
    '    -M                    move/rename a branch, even if target exists\n'
    '    --[no-]omit-empty     do not output a newline after empty formatted refs\n'
    '    -c, --[no-]copy       copy a branch and its reflog\n'
    '    -C                    copy a branch, even if target exists\n'
    '    -l, --[no-]list       list branch names\n'
    '    --[no-]show-current   show current branch name\n'
    '    --[no-]create-reflog  create the branch\'s reflog\n'
    '    --[no-]edit-description\n'
    '                          edit the description for the branch\n'
    '    -f, --[no-]force      force creation, move/rename, deletion\n'
    '    --merged <commit>     print only branches that are merged\n'
    '    --no-merged <commit>  print only branches that are not merged\n'
    '    --[no-]column[=<style>]\n'
    '                          list branches in columns\n'
    '    --[no-]sort <key>     field name to sort on\n'
    '    --[no-]points-at <object>\n'
    '                          print only branches of the object\n'
    '    -i, --[no-]ignore-case\n'
    '                          sorting and filtering are case insensitive\n'
    '    --[no-]recurse-submodules\n'
    '                          recurse through submodules\n'
    '    --[no-]format <format>\n'
    '                          format to use for the output\n';

const _options = <GitOption>[
  GitOption('verbose', short: 'v', negatable: true),
  GitOption('quiet', short: 'q', negatable: true),
  GitOption('track', short: 't', valued: true, optional: true, negatable: true),
  GitOption('set-upstream-to', short: 'u', valued: true, negatable: true),
  GitOption('unset-upstream', negatable: true),
  GitOption('color', valued: true, optional: true, negatable: true),
  GitOption('remotes', short: 'r'),
  GitOption('contains', valued: true, whenAbsent: 'HEAD'),
  GitOption('no-contains', valued: true, whenAbsent: 'HEAD'),
  GitOption('abbrev', valued: true, optional: true, negatable: true),
  GitOption('all', short: 'a'),
  GitOption('delete', short: 'd', negatable: true),
  GitOption('force-delete', short: 'D'),
  GitOption('move', short: 'm', negatable: true),
  GitOption('force-move', short: 'M'),
  GitOption('omit-empty', negatable: true),
  GitOption('copy', short: 'c', negatable: true),
  GitOption('force-copy', short: 'C'),
  GitOption('list', short: 'l', negatable: true),
  GitOption('show-current', negatable: true),
  GitOption('create-reflog', negatable: true),
  GitOption('edit-description', negatable: true),
  GitOption('force', short: 'f'),
  GitOption('merged', valued: true, whenAbsent: 'HEAD'),
  GitOption('no-merged', valued: true, whenAbsent: 'HEAD'),
  GitOption('column', valued: true, optional: true, negatable: true),
  GitOption('sort', valued: true, negatable: true),
  GitOption('points-at', valued: true, negatable: true),
  GitOption('ignore-case', short: 'i', negatable: true),
  GitOption('recurse-submodules', negatable: true),
  GitOption('format', valued: true, negatable: true),
];

const _conflict = '$_usage\n';

/// Выполняет `git branch`. [committer] попадает в новые строки reflog.
Future<int> runGitBranch(
  AppletIo io,
  GitRepository repo,
  List<String> args, {
  required GitCommitSignature committer,
}) async {
  final parsed = parseGitArgs(args, _options, usage: _usage);
  final delete = parsed.has('delete') || parsed.has('force-delete');
  final move = parsed.has('move') || parsed.has('force-move');
  final copy = parsed.has('copy') || parsed.has('force-copy');
  final filtering =
      parsed.has('contains') ||
      parsed.has('no-contains') ||
      parsed.has('merged') ||
      parsed.has('no-merged') ||
      parsed.has('points-at');
  final kinds = <String>[
    if (delete) 'delete',
    if (move) 'move',
    if (copy) 'copy',
    if (parsed.has('set-upstream-to')) 'upstream',
    if (parsed.has('unset-upstream')) 'unset',
    if (parsed.has('show-current')) 'show',
    if (parsed.has('edit-description')) 'edit',
    if (parsed.has('list') || filtering) 'list',
  ];
  if (kinds.length > 1) throw const GitUsage(_conflict);
  if (parsed.has('recurse-submodules') && !await _propagate(repo)) {
    throw const GitUsage(
      'fatal: branch with --recurse-submodules can only be used if '
      'submodule.propagateBranches is enabled\n',
      exitCode: 128,
    );
  }
  final columns = _columns(parsed);
  if (columns.mode != _Col.off && parsed.count('verbose') > 0) {
    throw const GitUsage(
      "fatal: options '--column' and '--verbose' cannot be used together\n",
      exitCode: 128,
    );
  }
  _abbrev(parsed);
  _color(parsed);
  _trackRequest(parsed);

  final creating =
      kinds.isEmpty &&
      parsed.operands.isNotEmpty &&
      !parsed.has('all') &&
      !parsed.has('remotes');
  if (parsed.has('recurse-submodules') && !creating) {
    throw const GitUsage(
      'fatal: --recurse-submodules can only be used to create branches\n',
      exitCode: 128,
    );
  }
  if (creating &&
      parsed.has('recurse-submodules') &&
      await _hasSubmodule(repo)) {
    throw const GitUsage(
      'fatal: --recurse-submodules with submodules is not supported\n',
      exitCode: 128,
    );
  }

  if (delete) {
    return _delete(io, repo, parsed);
  }
  if (parsed.has('show-current')) return _showCurrent(io, repo);
  final listing =
      kinds.contains('list') ||
      (kinds.isEmpty &&
          (parsed.operands.isEmpty ||
              parsed.has('all') ||
              parsed.has('remotes')));
  if (listing) {
    if ((parsed.has('all') || parsed.has('remotes')) &&
        parsed.operands.isNotEmpty &&
        !parsed.has('list') &&
        !filtering) {
      throw const GitUsage(
        'fatal: the -a, and -r, options to \'git branch\' do not take a branch name.\n'
        'Did you mean to use: -a|-r --list <pattern>?\n',
        exitCode: 128,
      );
    }
    return _list(io, repo, parsed, columns: columns);
  }
  if (parsed.has('edit-description')) {
    return _editDescription(io, repo, parsed);
  }
  if (move || copy) {
    return _transfer(
      io,
      repo,
      parsed,
      committer: committer,
      copy: copy,
      force: copy
          ? parsed.has('force-copy') || parsed.has('force')
          : parsed.has('force-move') || parsed.has('force'),
    );
  }
  if (parsed.has('set-upstream-to')) return _setUpstream(io, repo, parsed);
  if (parsed.has('unset-upstream')) return _unsetUpstream(repo, parsed);
  return _create(io, repo, parsed, committer: committer);
}

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

Future<int> _list(
  AppletIo io,
  GitRepository repo,
  GitInvocation parsed, {
  required _Columns columns,
}) async {
  final remotesOnly = parsed.has('remotes') && !parsed.has('all');
  final includeRemotes = parsed.has('remotes') || parsed.has('all');
  final rows = <_Ref>[];
  if (!remotesOnly) {
    rows.addAll(await _load(repo, 'refs/heads'));
    final head = await repo.readReference('HEAD');
    if (head != null && head.isDirect) {
      final id = head.objectId;
      if (id != null) {
        rows.add(
          _Ref(
            refname: 'HEAD',
            objectId: id,
            commit: await _commit(repo, id),
            detached: true,
            current: true,
            symref: null,
            description: await _detachedDescription(repo, id),
          ),
        );
      }
    } else {
      final current = head?.targetReferenceName;
      for (final row in rows) {
        row.current = row.refname == current;
      }
    }
  }
  if (includeRemotes) rows.addAll(await _load(repo, 'refs/remotes'));
  final ignoreCase = parsed.has('ignore-case');
  final patterns = parsed.operands;
  final filtered = <_Ref>[
    for (final row in rows)
      if (_matches(row, patterns, ignoreCase: ignoreCase)) row,
  ];
  final reach = _Reach(repo);
  final selected = await _filter(repo, filtered, parsed, reach);
  final verbose = parsed.count('verbose');
  final abbrev = _abbrev(parsed);
  final color = _color(parsed);
  var maxWidth = 0;
  if (verbose > 0) {
    for (final row in selected) {
      final width = _nameWidth(row, remoteBonus: !remotesOnly);
      if (width > maxWidth) maxWidth = width;
    }
  }
  final configured = await repo.configGet('branch.sort');
  final keys = <String>[
    if (configured != null && configured.isNotEmpty) configured,
    ...parsed.valuesOf('sort'),
  ];
  selected.sort(
    (left, right) => _compare(left, right, keys: keys, ignoreCase: ignoreCase),
  );
  for (final row in selected) {
    await reach.describe(row);
  }
  final format =
      parsed.value('format') ??
      _defaultFormat(
        color: color,
        verbose: verbose,
        abbrev: abbrev,
        maxWidth: maxWidth,
        remotePrefix: remotesOnly ? '' : 'remotes/',
      );
  final lines = <String>[];
  for (final row in selected) {
    final text = _render(format, row, abbrev: abbrev, reach: reach);
    if (text.isEmpty && parsed.has('omit-empty')) continue;
    lines.add(text);
  }
  if (columns.mode == _Col.off || columns.mode == _Col.plain) {
    for (final line in lines) {
      io.stdout.writeText('$line\n');
    }
    return 0;
  }
  io.stdout.writeText(
    _layout(
      lines,
      width: _termWidth(io) - 1,
      across: columns.mode == _Col.across,
      dense: columns.dense,
    ),
  );
  return 0;
}

Future<List<_Ref>> _load(GitRepository repo, String prefix) async {
  final loaded = <_Ref>[];
  for (final info in await repo.references(prefix: prefix)) {
    final stored = await repo.readReference(info.referenceName);
    loaded.add(
      _Ref(
        refname: info.referenceName,
        objectId: info.objectId,
        commit: await _commit(repo, info.objectId),
        detached: false,
        current: false,
        symref: stored?.targetReferenceName,
        description: '',
      ),
    );
  }
  return loaded;
}

Future<GitCommit?> _commit(GitRepository repo, GitObjectId id) async {
  final object = await repo.show(id.hex);
  if (object == null || object.type != GitObjectType.commit) return null;
  return const GitCommitCodec().decode(object.bytes);
}

Future<String> _detachedDescription(GitRepository repo, GitObjectId id) async {
  final entries = await repo.reflog();
  var label = id.hex;
  var at = true;
  if (entries.isNotEmpty) {
    at = entries.first.newObjectId == id;
    for (final entry in entries) {
      const marker = ' to ';
      final atSign = entry.message.lastIndexOf(marker);
      if (atSign < 0) continue;
      label = _slice(
        entry.message,
        atSign + marker.length,
        entry.message.length,
      );
      break;
    }
  }
  final word = at ? 'at' : 'from';
  return '(HEAD detached $word $label)';
}

bool _matches(_Ref row, List<String> patterns, {required bool ignoreCase}) {
  if (patterns.isEmpty) return true;
  final names = row.detached
      ? <String>[row.description, 'HEAD']
      : <String>[_matchName(row.refname)];
  for (final pattern in patterns) {
    for (final name in names) {
      if (_wild(pattern, name, ignoreCase: ignoreCase)) return true;
    }
  }
  return false;
}

String _matchName(String refname) {
  for (final prefix in const [
    'refs/heads/',
    'refs/remotes/',
    'refs/tags/',
    'refs/',
  ]) {
    if (refname.startsWith(prefix)) {
      return _slice(refname, prefix.length, refname.length);
    }
  }
  return refname;
}

Future<List<_Ref>> _filter(
  GitRepository repo,
  List<_Ref> rows,
  GitInvocation parsed,
  _Reach reach,
) async {
  final contains = await _revs(repo, parsed.valuesOf('contains'));
  final absent = await _revs(repo, parsed.valuesOf('no-contains'));
  final merged = await _revs(repo, parsed.valuesOf('merged'));
  final unmerged = await _revs(repo, parsed.valuesOf('no-merged'));
  final points = await _revs(repo, parsed.valuesOf('points-at'));
  final kept = <_Ref>[];
  for (final row in rows) {
    final tip = row.objectId.hex;
    if (contains.isNotEmpty && !await _anyAncestor(reach, tip, contains)) {
      continue;
    }
    if (absent.isNotEmpty && await _anyAncestor(reach, tip, absent)) continue;
    if (merged.isNotEmpty && !await _anyContains(reach, merged, tip)) continue;
    if (unmerged.isNotEmpty && await _anyContains(reach, unmerged, tip)) {
      continue;
    }
    if (points.isNotEmpty && !points.contains(tip)) continue;
    kept.add(row);
  }
  return kept;
}

Future<List<String>> _revs(GitRepository repo, List<String> names) async {
  final ids = <String>[];
  for (final name in names) {
    final id = await repo.revParse(name);
    if (id == null) {
      throw GitUsage('error: malformed object name $name\n');
    }
    ids.add(id.hex);
  }
  return ids;
}

Future<bool> _anyAncestor(
  _Reach reach,
  String tip,
  List<String> commits,
) async {
  final set = await reach.of(tip);
  for (final commit in commits) {
    if (set.contains(commit)) return true;
  }
  return false;
}

Future<bool> _anyContains(
  _Reach reach,
  List<String> tips,
  String commit,
) async {
  for (final tip in tips) {
    if ((await reach.of(tip)).contains(commit)) return true;
  }
  return false;
}

int _compare(
  _Ref left,
  _Ref right, {
  required List<String> keys,
  required bool ignoreCase,
}) {
  if (left.detached != right.detached) return left.detached ? -1 : 1;
  final order = keys.isEmpty ? const <String>['refname'] : keys;
  for (var index = order.length - 1; index >= 0; index--) {
    final compared = _compareKey(
      order[index],
      left,
      right,
      ignoreCase: ignoreCase,
    );
    if (compared != 0) return compared;
  }
  return _text(left.refname, right.refname, ignoreCase: ignoreCase);
}

int _compareKey(String raw, _Ref left, _Ref right, {required bool ignoreCase}) {
  var key = raw;
  var reverse = false;
  if (key.startsWith('-')) {
    reverse = true;
    key = _slice(key, 1, key.length);
  }
  final compared = switch (key) {
    'refname' => _text(left.refname, right.refname, ignoreCase: ignoreCase),
    'objectname' => left.objectId.hex.compareTo(right.objectId.hex),
    'version:refname' => _version(
      left.refname,
      right.refname,
      ignoreCase: ignoreCase,
    ),
    'authordate' ||
    'committerdate' ||
    'creatordate' ||
    'taggerdate' => _dateOf(left, key).compareTo(_dateOf(right, key)),
    _ => throw GitUsage('fatal: unknown field name: $key\n', exitCode: 128),
  };
  return reverse ? -compared : compared;
}

int _dateOf(_Ref row, String key) {
  final commit = row.commit;
  if (commit == null) return 0;
  final signature = key == 'authordate' ? commit.author : commit.committer;
  return signature.timestampSeconds;
}

int _text(String left, String right, {required bool ignoreCase}) {
  if (!ignoreCase) return left.compareTo(right);
  return left.toLowerCase().compareTo(right.toLowerCase());
}

int _version(String left, String right, {required bool ignoreCase}) {
  final a = ignoreCase ? left.toLowerCase() : left;
  final b = ignoreCase ? right.toLowerCase() : right;
  var i = 0;
  var j = 0;
  while (i < a.length && j < b.length) {
    final aDigit = _isDigit(a.codeUnitAt(i));
    final bDigit = _isDigit(b.codeUnitAt(j));
    if (aDigit && bDigit) {
      final aStart = i;
      final bStart = j;
      while (i < a.length && _isDigit(a.codeUnitAt(i))) {
        i++;
      }
      while (j < b.length && _isDigit(b.codeUnitAt(j))) {
        j++;
      }
      final aNum = _slice(a, aStart, i);
      final bNum = _slice(b, bStart, j);
      final byLength = _significant(aNum).compareTo(_significant(bNum));
      if (byLength != 0) return byLength;
      final byText = _stripZeros(aNum).compareTo(_stripZeros(bNum));
      if (byText != 0) return byText;
      continue;
    }
    final unit = a.codeUnitAt(i).compareTo(b.codeUnitAt(j));
    if (unit != 0) return unit;
    i++;
    j++;
  }
  return (a.length - i).compareTo(b.length - j);
}

int _significant(String number) {
  var index = 0;
  while (index < number.length - 1 && number.codeUnitAt(index) == 0x30) {
    index++;
  }
  return number.length - index;
}

String _stripZeros(String number) {
  var index = 0;
  while (index < number.length - 1 && number.codeUnitAt(index) == 0x30) {
    index++;
  }
  return _slice(number, index, number.length);
}

bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;

int _nameWidth(_Ref row, {required bool remoteBonus}) {
  if (row.detached) return row.description.length;
  final short = _lstrip(row.refname, 2);
  if (remoteBonus && row.refname.startsWith('refs/remotes/')) {
    return short.length + 'remotes/'.length;
  }
  return short.length;
}

/// Формат по умолчанию как у git 2.53.
///
/// У локальной ветки в `% (else)` два пробела: так собран бинарник Debian,
/// а не один пробел из опубликованного `branch.c`. У remote-строки те же
/// два пробела перед `remotes/`. Цвет локальной ветки пустой, но сброс
/// `\x1b[m` после имени всё равно пишется, когда цвет включён.
String _defaultFormat({
  required bool color,
  required int verbose,
  required int abbrev,
  required int maxWidth,
  required String remotePrefix,
}) {
  final current = color ? '\x1b[32m' : '';
  final worktree = color ? '\x1b[36m' : '';
  final remote = color ? '\x1b[31m' : '';
  final upstream = color ? '\x1b[34m' : '';
  final reset = color ? '\x1b[m' : '';
  final localHead =
      '%(if)%(HEAD)%(then)* $current%(else)%(if)%(worktreepath)%(then)+ $worktree%(else)  %(end)%(end)';
  final remoteHead = '  $remote';
  final object = abbrev <= 0
      ? '%(objectname)'
      : abbrev == 7
      ? '%(objectname:short)'
      : '%(objectname:short=$abbrev)';
  final localBody = verbose == 0
      ? '%(refname:lstrip=2)$reset%(if)%(symref)%(then) -> %(symref:short)%(end)'
      : '%(align:$maxWidth,left)%(refname:lstrip=2)%(end)$reset $object '
            '${verbose > 1 ? '%(if:notequals=*)%(HEAD)%(then)%(if)%(worktreepath)%(then)($worktree%(worktreepath)$reset) %(end)%(end)%(if)%(upstream)%(then)[$upstream%(upstream:short)$reset%(if)%(upstream:track)%(then): %(upstream:track,nobracket)%(end)] %(end)%(contents:subject)' : '%(if)%(upstream:track)%(then)%(upstream:track) %(end)%(contents:subject)'}';
  final remoteBody = verbose == 0
      ? '$remotePrefix%(refname:lstrip=2)$reset%(if)%(symref)%(then) -> %(symref:short)%(end)'
      : '%(align:$maxWidth,left)$remotePrefix%(refname:lstrip=2)%(end)$reset'
            '%(if)%(symref)%(then) -> %(symref:short)%(else) $object %(contents:subject)%(end)';
  return '%(if:notequals=refs/remotes)%(refname:rstrip=-2)%(then)$localHead$localBody%(else)$remoteHead$remoteBody%(end)';
}

String _render(
  String format,
  _Ref row, {
  required int abbrev,
  required _Reach reach,
}) {
  final stack = <_Frame>[_Frame.root()];
  final units = format.codeUnits;
  var index = 0;
  while (index < units.length) {
    if (units[index] == 0x25 && index + 1 < units.length) {
      final next = units[index + 1];
      if (next == 0x25) {
        stack.last.buf.write('%');
        index += 2;
        continue;
      }
      if (next == 0x6e) {
        stack.last.buf.write('\n');
        index += 2;
        continue;
      }
      if (next == 0x28) {
        final close = _close(units, index + 2);
        final body = String.fromCharCodes(units.getRange(index + 2, close));
        _atom(body, stack, row, abbrev: abbrev, reach: reach);
        index = close + 1;
        continue;
      }
    }
    stack.last.buf.writeCharCode(units[index]);
    index++;
  }
  if (stack.length != 1) {
    throw const GitUsage('fatal: format: %(end) atom missing\n', exitCode: 128);
  }
  return stack.single.buf.toString();
}

int _close(List<int> units, int start) {
  var depth = 1;
  for (var index = start; index < units.length; index++) {
    if (units[index] == 0x28) depth++;
    if (units[index] == 0x29) {
      depth--;
      if (depth == 0) return index;
    }
  }
  throw const GitUsage('fatal: format: unterminated atom\n', exitCode: 128);
}

void _atom(
  String body,
  List<_Frame> stack,
  _Ref row, {
  required int abbrev,
  required _Reach reach,
}) {
  final colon = body.indexOf(':');
  final name = colon < 0 ? body : _slice(body, 0, colon);
  final arg = colon < 0 ? null : _slice(body, colon + 1, body.length);
  switch (name) {
    case 'if':
      stack.add(_Frame.condition(_ifSpec(arg)));
    case 'then':
      final frame = stack.last;
      final spec = frame.spec;
      if (frame.kind != _Kind.condition || spec == null || spec.sawThen) {
        throw const GitUsage(
          'fatal: format: %(then) atom missing\n',
          exitCode: 128,
        );
      }
      spec.sawThen = true;
      spec.satisfied = _satisfied(frame.buf.toString(), spec);
      frame.buf.clear();
    case 'else':
      final frame = stack.last;
      final spec = frame.spec;
      if (spec == null || !spec.sawThen || spec.sawElse) {
        throw const GitUsage(
          'fatal: format: %(else) atom missing\n',
          exitCode: 128,
        );
      }
      spec.sawElse = true;
      stack.add(_Frame.otherwise(spec));
    case 'end':
      _end(stack);
    case 'align':
      stack.add(_Frame.align(_align(arg)));
    default:
      stack.last.buf.write(
        _value(name, arg, row, abbrev: abbrev, reach: reach),
      );
  }
}

void _end(List<_Frame> stack) {
  if (stack.length < 2) {
    throw const GitUsage('fatal: format: %(end) atom missing\n', exitCode: 128);
  }
  final top = stack.last;
  switch (top.kind) {
    case _Kind.root:
      throw const GitUsage(
        'fatal: format: %(end) atom missing\n',
        exitCode: 128,
      );
    case _Kind.align:
      final padded = _pad(top.buf.toString(), top.alignWidth, top.alignWhere);
      stack.removeLast();
      stack.last.buf.write(padded);
    case _Kind.otherwise:
      final spec = top.spec!;
      final alternative = top.buf.toString();
      stack.removeLast();
      final chosen = spec.satisfied ? stack.last.buf.toString() : alternative;
      stack.removeLast();
      stack.last.buf.write(chosen);
    case _Kind.condition:
      final spec = top.spec;
      if (spec == null || !spec.sawThen) {
        throw const GitUsage(
          'fatal: format: %(then) atom missing\n',
          exitCode: 128,
        );
      }
      final text = spec.satisfied ? top.buf.toString() : '';
      stack.removeLast();
      stack.last.buf.write(text);
  }
}

_If _ifSpec(String? arg) {
  if (arg == null || arg.isEmpty) return _If();
  if (arg.startsWith('equals=')) {
    return _If(equals: _slice(arg, 'equals='.length, arg.length));
  }
  if (arg.startsWith('notequals=')) {
    return _If(
      equals: _slice(arg, 'notequals='.length, arg.length),
      negate: true,
    );
  }
  throw GitUsage('fatal: unrecognized %(if) argument: $arg\n', exitCode: 128);
}

bool _satisfied(String text, _If spec) {
  final equals = spec.equals;
  if (equals == null) return !_blank(text);
  final same = text == equals;
  return spec.negate ? !same : same;
}

bool _blank(String text) {
  for (final unit in text.codeUnits) {
    if (unit != 0x20 &&
        unit != 0x09 &&
        unit != 0x0a &&
        unit != 0x0b &&
        unit != 0x0c &&
        unit != 0x0d) {
      return false;
    }
  }
  return true;
}

({int width, String where}) _align(String? arg) {
  final spec = arg ?? '';
  final comma = spec.indexOf(',');
  final widthText = comma < 0 ? spec : _slice(spec, 0, comma);
  final where = comma < 0 ? 'left' : _slice(spec, comma + 1, spec.length);
  final width = int.tryParse(widthText);
  if (width == null || width < 0) {
    throw GitUsage(
      'fatal: positive width expected align:$spec\n',
      exitCode: 128,
    );
  }
  return (width: width, where: where);
}

String _pad(String text, int width, String where) {
  if (text.length >= width) return text;
  final gap = width - text.length;
  return switch (where) {
    'right' => '${' ' * gap}$text',
    'middle' => '${' ' * (gap ~/ 2)}$text${' ' * (gap - gap ~/ 2)}',
    _ => '$text${' ' * gap}',
  };
}

String _value(
  String name,
  String? arg,
  _Ref row, {
  required int abbrev,
  required _Reach reach,
}) => switch (name) {
  'refname' => _refname(row, arg),
  'objectname' => _objectName(row, arg, abbrev),
  'HEAD' => row.current ? '*' : ' ',
  'symref' => _symref(row, arg),
  'upstream' => _upstreamAtom(row, arg, reach),
  'contents' => _contents(row, arg),
  'subject' => _contents(row, 'subject'),
  'authorname' => row.commit?.author.name ?? '',
  'authoremail' => row.commit?.author.email ?? '',
  'author' => _person(row.commit?.author),
  'committername' => row.commit?.committer.name ?? '',
  'committeremail' => row.commit?.committer.email ?? '',
  'committer' => _person(row.commit?.committer),
  'authordate' => _when(row.commit?.author, arg, 'authordate'),
  'committerdate' ||
  'creatordate' ||
  'taggerdate' => _when(row.commit?.committer, arg, name),
  'objecttype' => row.commit == null ? '' : 'commit',
  'worktreepath' => '',
  _ => throw GitUsage('fatal: unknown field name: $name\n', exitCode: 128),
};

String _person(GitCommitSignature? signature) =>
    signature == null ? '' : '${signature.name} <${signature.email}>';

String _refname(_Ref row, String? arg) {
  if (row.detached) return row.description;
  if (arg == null || arg.isEmpty) return row.refname;
  if (arg == 'short') return _matchName(row.refname);
  if (arg.startsWith('lstrip=')) {
    return _lstrip(row.refname, _number(arg, 'lstrip=', 'refname'));
  }
  if (arg.startsWith('rstrip=')) {
    return _rstrip(row.refname, _number(arg, 'rstrip=', 'refname'));
  }
  throw GitUsage(
    'fatal: unrecognized %(refname) argument: $arg\n',
    exitCode: 128,
  );
}

int _number(String arg, String prefix, String atom) {
  final raw = _slice(arg, prefix.length, arg.length);
  final number = int.tryParse(raw);
  if (number == null) {
    throw GitUsage(
      'fatal: unrecognized %($atom) argument: $arg\n',
      exitCode: 128,
    );
  }
  return number;
}

String _lstrip(String refname, int count) {
  final slashes = _slashes(refname);
  final remaining = count < 0 ? slashes + count + 1 : count;
  if (remaining <= 0) return refname;
  var seen = 0;
  for (var index = 0; index < refname.length; index++) {
    if (refname.codeUnitAt(index) == 0x2f) {
      seen++;
      if (seen == remaining) {
        return _slice(refname, index + 1, refname.length);
      }
    }
  }
  return '';
}

String _rstrip(String refname, int count) {
  final slashes = _slashes(refname);
  final remaining = count < 0 ? slashes + count + 1 : count;
  if (remaining <= 0) return refname;
  var end = refname.length;
  var seen = 0;
  for (var index = refname.length - 1; index >= 0; index--) {
    if (refname.codeUnitAt(index) == 0x2f) {
      seen++;
      if (seen == remaining) {
        end = index;
        break;
      }
    }
  }
  if (seen < remaining) return '';
  return _slice(refname, 0, end);
}

int _slashes(String text) {
  var count = 0;
  for (final unit in text.codeUnits) {
    if (unit == 0x2f) count++;
  }
  return count;
}

String _objectName(_Ref row, String? arg, int abbrev) {
  final hex = row.objectId.hex;
  if (arg == null || arg.isEmpty) return hex;
  if (arg == 'short') return _shortHex(hex, abbrev);
  if (arg.startsWith('short=')) {
    return _shortHex(hex, _number(arg, 'short=', 'objectname'));
  }
  throw GitUsage(
    'fatal: unrecognized %(objectname) argument: $arg\n',
    exitCode: 128,
  );
}

String _shortHex(String hex, int length) {
  if (length <= 0 || length >= hex.length) return hex;
  final shown = length < 4 ? 4 : length;
  if (shown >= hex.length) return hex;
  return _slice(hex, 0, shown);
}

String _symref(_Ref row, String? arg) {
  final target = row.symref;
  if (target == null) return '';
  if (arg == null || arg.isEmpty) return target;
  if (arg == 'short') return _matchName(target);
  throw GitUsage(
    'fatal: unrecognized %(symref) argument: $arg\n',
    exitCode: 128,
  );
}

String _contents(_Ref row, String? arg) {
  final message = row.commit?.message ?? '';
  final newline = message.indexOf('\n');
  final subject = newline < 0 ? message : _slice(message, 0, newline);
  if (arg == null || arg == 'subject') return subject;
  if (arg == 'body') {
    if (newline < 0) return '';
    var rest = _slice(message, newline + 1, message.length);
    if (rest.startsWith('\n')) rest = _slice(rest, 1, rest.length);
    return rest;
  }
  throw GitUsage(
    'fatal: unrecognized %(contents) argument: $arg\n',
    exitCode: 128,
  );
}

String _when(GitCommitSignature? signature, String? arg, String atom) {
  if (signature == null) return '';
  if (arg == null || arg.isEmpty) return _gitDate(signature);
  if (arg == 'unix') return '${signature.timestampSeconds}';
  final date = _wall(signature);
  if (arg == 'short') {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }
  if (arg == 'iso' || arg == 'iso8601') {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')} '
        '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}:'
        '${date.second.toString().padLeft(2, '0')} '
        '${signature.timezoneOffset}';
  }
  throw GitUsage(
    'fatal: unrecognized %($atom) argument: $arg\n',
    exitCode: 128,
  );
}

String _gitDate(GitCommitSignature signature) {
  final date = _wall(signature);
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${weekdays[date.weekday - 1]} ${months[date.month - 1]} '
      '${date.day.toString().padLeft(2, ' ')} '
      '${date.hour.toString().padLeft(2, '0')}:'
      '${date.minute.toString().padLeft(2, '0')}:'
      '${date.second.toString().padLeft(2, '0')} '
      '${date.year} ${signature.timezoneOffset}';
}

DateTime _wall(GitCommitSignature signature) {
  final zoned = RegExp(r'^([+-])(\d\d)(\d\d)$')
      .firstMatch(signature.timezoneOffset);
  var seconds = signature.timestampSeconds;
  if (zoned != null) {
    final sign = zoned.group(1) == '-' ? -1 : 1;
    final shift =
        int.parse(zoned.group(2)!) * 3600 + int.parse(zoned.group(3)!) * 60;
    seconds += sign * shift;
  }
  return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}

String _upstreamAtom(_Ref row, String? arg, _Reach reach) {
  final info = row.detached ? null : reach.tracking[row.refname];
  if (info == null) return '';
  if (arg == null || arg.isEmpty || arg == 'short') return info.label;
  if (arg == 'track') return info.track;
  if (arg == 'track,nobracket') return info.bareTrack;
  if (arg == 'trackshort') return info.trackShort;
  throw GitUsage(
    'fatal: unrecognized %(upstream) argument: $arg\n',
    exitCode: 128,
  );
}

String _layout(
  List<String> items, {
  required int width,
  required bool across,
  required bool dense,
}) {
  if (items.isEmpty) return '';
  final room = width < 1 ? 1 : width;
  var longest = 0;
  for (final item in items) {
    if (item.length > longest) longest = item.length;
  }
  const padding = 1;
  final cell = longest + padding;
  var cols = room ~/ cell;
  if (cols < 1) cols = 1;
  if (cols > items.length) cols = items.length;
  var rows = (items.length + cols - 1) ~/ cols;
  if (dense) {
    while (cols < items.length) {
      final nextCols = cols + 1;
      final nextRows = (items.length + nextCols - 1) ~/ nextCols;
      if (_denseWidth(items, nextCols, nextRows, across) > room) break;
      cols = nextCols;
      rows = nextRows;
    }
  }
  final buffer = StringBuffer();
  for (var y = 0; y < rows; y++) {
    for (var x = 0; x < cols; x++) {
      final index = across ? y * cols + x : x * rows + y;
      if (index >= items.length) break;
      final item = items[index];
      buffer.write(item);
      final next = across ? y * cols + x + 1 : (x + 1) * rows + y;
      final last = x == cols - 1 || next >= items.length;
      if (!last) {
        final pad = dense
            ? _columnWidth(items, x, cols, rows, across) - item.length + padding
            : cell - item.length;
        if (pad > 0) buffer.write(' ' * pad);
      }
    }
    buffer.write('\n');
  }
  return buffer.toString();
}

int _denseWidth(List<String> items, int cols, int rows, bool across) {
  var total = 0;
  for (var column = 0; column < cols; column++) {
    total += _columnWidth(items, column, cols, rows, across);
    if (column + 1 < cols) total += 1;
  }
  return total;
}

int _columnWidth(
  List<String> items,
  int column,
  int cols,
  int rows,
  bool across,
) {
  var width = 0;
  for (var y = 0; y < rows; y++) {
    final index = across ? y * cols + column : column * rows + y;
    if (index >= items.length) continue;
    if (items[index].length > width) width = items[index].length;
  }
  return width;
}

int _termWidth(AppletIo io) {
  final raw = io.env['COLUMNS'];
  final number = raw == null ? 80 : int.tryParse(raw) ?? 80;
  return number <= 0 ? 80 : number;
}

Future<void> _rejectName(GitRepository repo, String name) async {
  if (_validBranch(name)) return;
  final hint = _adviceOff(await repo.configGet('advice.refSyntax'))
      ? ''
      : "hint: See 'git help check-ref-format'\n"
            'hint: Disable this message with "git config set advice.refSyntax false"\n';
  throw GitUsage(
    "fatal: '$name' is not a valid branch name\n$hint",
    exitCode: 128,
  );
}

bool _adviceOff(String? value) => switch (value?.toLowerCase()) {
  'false' || '0' || 'no' || 'off' => true,
  _ => false,
};

bool _validBranch(String name) {
  if (name.isEmpty || name == '@' || name == 'HEAD') return false;
  if (name.startsWith('/') || name.endsWith('/') || name.contains('//')) {
    return false;
  }
  if (name.contains('..') || name.contains('@{')) return false;
  if (name.endsWith('.lock') || name.endsWith('.')) return false;
  for (final unit in name.codeUnits) {
    if (unit < 0x20 || unit == 0x7f) return false;
    if (const {0x20, 0x7e, 0x5e, 0x3a, 0x3f, 0x2a, 0x5b, 0x5c}.contains(unit)) {
      return false;
    }
  }
  for (final part in name.split('/')) {
    if (part.isEmpty ||
        part.startsWith('.') ||
        part.endsWith('.lock') ||
        part.endsWith('.')) {
      return false;
    }
  }
  return true;
}

String? _branchOf(String? reference) {
  if (reference == null || !reference.startsWith('refs/heads/')) return null;
  return _slice(reference, 'refs/heads/'.length, reference.length);
}

Future<_Resolved?> _resolveBranch(GitRepository repo, String name) async {
  final candidates = <String>[
    if (name.startsWith('refs/')) name,
    'refs/remotes/$name',
    'refs/heads/$name',
  ];
  for (final candidate in candidates) {
    if (await repo.readReference(candidate) == null) continue;
    if (await repo.resolveReferenceObjectId(candidate) == null) continue;
    return _Resolved(candidate);
  }
  return null;
}

Future<_Upstream> _upstreamTarget(
  GitRepository repo,
  String name, {
  required bool explicit,
}) async {
  final resolved = await _resolveBranch(repo, name);
  if (resolved == null) {
    if (await repo.revParse(name) != null && explicit) {
      throw GitUsage(
        'fatal: cannot set up tracking information; starting point '
        "'$name' is not a branch\n",
        exitCode: 128,
      );
    }
    final hint = _adviceOff(await repo.configGet('advice.setUpstreamFailure'))
        ? '\n'
        : '\nhint:\n'
              'hint: If you are planning on basing your work on an upstream\n'
              'hint: branch that already exists at the remote, you may need to\n'
              'hint: run "git fetch" to retrieve it.\n'
              'hint:\n'
              'hint: If you are planning to push out a new local branch that\n'
              'hint: will track its remote counterpart, you may want to use\n'
              'hint: "git push -u" to set the upstream config as you push.\n'
              'hint: Disable this message with "git config set advice.setUpstreamFailure false"\n';
    throw GitUsage(
      "fatal: the requested upstream branch '$name' does not exist$hint",
      exitCode: 128,
    );
  }
  if (resolved.reference.startsWith('refs/heads/')) {
    final short = _branchOf(resolved.reference)!;
    return _Upstream(remote: '.', merge: resolved.reference, label: short);
  }
  final short = _slice(
    resolved.reference,
    'refs/remotes/'.length,
    resolved.reference.length,
  );
  final slash = short.indexOf('/');
  if (slash <= 0) {
    throw GitUsage(
      "fatal: cannot set up tracking information; starting point '$name' is not a branch\n",
      exitCode: 128,
    );
  }
  final remote = _slice(short, 0, slash);
  if (await repo.configGet('remote.$remote.url') == null) {
    throw GitUsage(
      "fatal: cannot set up tracking information; starting point '$name' is not a branch\n",
      exitCode: 128,
    );
  }
  final branch = _slice(short, slash + 1, short.length);
  return _Upstream(remote: remote, merge: 'refs/heads/$branch', label: short);
}

String _upstreamLabel(String remote, String merge) {
  final branch = merge.startsWith('refs/heads/')
      ? _slice(merge, 'refs/heads/'.length, merge.length)
      : merge;
  if (remote == '.') return branch;
  return '$remote/$branch';
}

bool _wild(String pattern, String text, {required bool ignoreCase}) {
  final left = ignoreCase ? pattern.toLowerCase() : pattern;
  final right = ignoreCase ? text.toLowerCase() : text;
  return _wildAt(left, 0, right, 0);
}

bool _wildAt(String pattern, int patternIndex, String text, int textIndex) {
  var pi = patternIndex;
  var ti = textIndex;
  while (pi < pattern.length) {
    final unit = pattern.codeUnitAt(pi);
    if (unit == 0x2a) {
      while (pi < pattern.length && pattern.codeUnitAt(pi) == 0x2a) {
        pi++;
      }
      if (pi == pattern.length) return true;
      for (var index = ti; index <= text.length; index++) {
        if (_wildAt(pattern, pi, text, index)) return true;
      }
      return false;
    }
    if (ti >= text.length) return false;
    if (unit != 0x3f && unit != text.codeUnitAt(ti)) return false;
    pi++;
    ti++;
  }
  return ti == text.length;
}

String _slice(String text, int start, int end) =>
    String.fromCharCodes(text.codeUnits.getRange(start, end));

enum _Track { auto, direct, inherit, no }

enum _Col { off, down, across, plain }

final class _Columns {
  const _Columns(this.mode, {this.dense = false});

  const _Columns.off() : mode = _Col.off, dense = false;

  final _Col mode;
  final bool dense;
}

final class _Upstream {
  const _Upstream({
    required this.remote,
    required this.merge,
    required this.label,
  });

  final String remote;
  final String merge;
  final String label;
}

final class _Resolved {
  const _Resolved(this.reference);

  final String reference;
}

final class _Ref {
  _Ref({
    required this.refname,
    required this.objectId,
    required this.commit,
    required this.detached,
    required this.current,
    required this.symref,
    required this.description,
  });

  final String refname;
  final GitObjectId objectId;
  final GitCommit? commit;
  final bool detached;
  bool current;
  final String? symref;
  final String description;
}

/// Кэш предков и уже посчитанный текст upstream для атомов формата.
final class _Reach {
  _Reach(this.repo);

  final GitRepository repo;
  final Map<String, Set<String>> _sets = {};
  final Map<String, _TrackText?> tracking = {};

  Future<Set<String>> of(String hex) async {
    final cached = _sets[hex];
    if (cached != null) return cached;
    final set = <String>{
      for (final entry in await repo.log(hex)) entry.objectId.hex,
    };
    _sets[hex] = set;
    return set;
  }

  Future<_TrackText?> describe(_Ref row) async {
    if (tracking.containsKey(row.refname)) return tracking[row.refname];
    final text = await _describe(row);
    tracking[row.refname] = text;
    return text;
  }

  Future<_TrackText?> _describe(_Ref row) async {
    if (row.detached || !row.refname.startsWith('refs/heads/')) return null;
    final name = _branchOf(row.refname);
    if (name == null) return null;
    final remote = await repo.configGet('branch.$name.remote');
    final merge = await repo.configGet('branch.$name.merge');
    if (remote == null || merge == null || remote.isEmpty || merge.isEmpty) {
      return null;
    }
    final label = _upstreamLabel(remote, merge);
    final upstream = remote == '.'
        ? merge
        : 'refs/remotes/$remote/${label.startsWith('$remote/') ? _slice(label, remote.length + 1, label.length) : label}';
    final id = await repo.revParse(upstream);
    if (id == null) {
      return _TrackText(label: label, ahead: 0, behind: 0, gone: true);
    }
    final local = await of(row.objectId.hex);
    final base = await of(id.hex);
    var ahead = 0;
    var behind = 0;
    for (final item in local) {
      if (!base.contains(item)) ahead++;
    }
    for (final item in base) {
      if (!local.contains(item)) behind++;
    }
    return _TrackText(label: label, ahead: ahead, behind: behind, gone: false);
  }
}

final class _TrackText {
  const _TrackText({
    required this.label,
    required this.ahead,
    required this.behind,
    required this.gone,
  });

  final String label;
  final int ahead;
  final int behind;
  final bool gone;

  String get bareTrack {
    if (gone) return 'gone';
    if (ahead == 0 && behind == 0) return '';
    if (behind == 0) return 'ahead $ahead';
    if (ahead == 0) return 'behind $behind';
    return 'ahead $ahead, behind $behind';
  }

  String get track {
    final bare = bareTrack;
    if (bare.isEmpty) return '';
    return '[$bare]';
  }

  String get trackShort {
    if (gone) return '';
    if (ahead == 0 && behind == 0) return '=';
    if (ahead > 0 && behind > 0) return '<>';
    if (ahead > 0) return '>';
    return '<';
  }
}

enum _Kind { root, condition, otherwise, align }

final class _If {
  _If({this.equals, this.negate = false});

  final String? equals;
  final bool negate;
  var sawThen = false;
  var sawElse = false;
  var satisfied = false;
}

final class _Frame {
  _Frame.root() : kind = _Kind.root;

  _Frame.condition(this.spec) : kind = _Kind.condition;

  _Frame.otherwise(this.spec) : kind = _Kind.otherwise;

  _Frame.align(({int width, String where}) align)
    : kind = _Kind.align,
      alignWidth = align.width,
      alignWhere = align.where;

  final _Kind kind;
  final buffer = StringBuffer();
  StringBuffer get buf => buffer;
  _If? spec;
  var alignWidth = 0;
  var alignWhere = 'left';
}

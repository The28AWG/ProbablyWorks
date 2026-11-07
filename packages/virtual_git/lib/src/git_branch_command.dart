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
part 'command/branch_format.dart';
part 'command/branch_list.dart';
part 'command/branch_update.dart';

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

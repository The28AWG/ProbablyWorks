import 'dart:convert';
import 'dart:typed_data';

import 'package:virtual_git/src/git_branch_command.dart';
import 'package:virtual_git/src/git_cli.dart';
import 'package:virtual_git/src/git_commit.dart';
import 'package:virtual_git/src/git_commit_codec.dart';
import 'package:virtual_git/src/git_commit_command.dart';
import 'package:virtual_git/src/git_diff.dart';
import 'package:virtual_git/src/git_diff_codec.dart';
import 'package:virtual_git/src/git_diff_options.dart';
import 'package:virtual_git/src/git_extra_commands.dart';
import 'package:virtual_git/src/git_fetch.dart';
import 'package:virtual_git/src/git_host_io.dart';
import 'package:virtual_git/src/git_index.dart';
import 'package:virtual_git/src/git_log.dart';
import 'package:virtual_git/src/git_merge.dart';
import 'package:virtual_git/src/git_object_type.dart';
import 'package:virtual_git/src/git_pull.dart';
import 'package:virtual_git/src/git_refspec.dart';
import 'package:virtual_git/src/git_remote.dart';
import 'package:virtual_git/src/git_repository.dart';
import 'package:virtual_git/src/git_reset.dart';
import 'package:virtual_git/src/git_status_format.dart';
import 'package:virtual_host/virtual_host.dart';

/// Команда `git` в оболочке виртуального хоста.
///
/// Аргументы разбираются как у git 2.53 (`LC_ALL=C`): длинные и короткие опции,
/// `--name=value`, `--` и глобальные `-C`/`-c`. Неизвестная опция завершается
/// кодом 129. Автор берётся из окружения, затем из `-c user.*`.
/// `--depth` на `file://` и HTTP обрезает историю и пишет `.git/shallow`.
/// Обычный путь каталога предупреждает и копирует целиком: так же делает git,
/// и в тексте предупреждения он сам предлагает `file://`.
final class GitApplet implements Applet {
  const GitApplet({this.http});

  /// Транспорт сети. Без него запросы идут через [PackageGitHttp].
  final GitHttp? http;

  @override
  String get name => 'git';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    try {
      final global = parseGitGlobals(args, cwd: io.cwd, resolve: _join);
      if (global.version) {
        io.stdout.writeText('git version 0.1.0\n');
        return 0;
      }
      if (global.help || global.args.isEmpty) {
        io.stdout.writeText(gitRootUsage);
        return global.help ? 0 : 1;
      }
      final commandIo = io.copyWith(cwd: global.cwd);
      bindGitIo(
        commandIo.fs,
        cwd: commandIo.cwd,
        environment: commandIo.env,
        http: http,
      );
      try {
        return await _dispatch(commandIo, global);
      } finally {
        clearGitIo();
      }
    } on GitUsage catch (error) {
      io.stderr.writeText(error.message);
      return error.exitCode;
    } on Object catch (error) {
      io.stderr.writeText('fatal: ${_fatalText(error)}\n');
      return 128;
    }
  }

  Future<int> _dispatch(AppletIo io, GitGlobals global) async {
    final command = global.args.first;
    final rest = global.args.sublist(1);
    final extra = await gitExtraCommand(io, command, rest, global.config);
    if (extra != null) return extra;
    return switch (command) {
      'init' => _init(io, rest, bare: global.bare),
      'clone' => _clone(io, rest),
      'status' => _needRepo(io, () => _status(io, rest)),
      'add' => _needRepo(io, () => _add(io, rest)),
      'commit' => _needRepo(io, () => _commit(io, rest, global.config)),
      'log' => _needRepo(io, () => _log(io, rest)),
      'diff' => _needRepo(io, () => _diff(io, rest)),
      'show' => _needRepo(io, () => _show(io, rest)),
      'rev-parse' => _needRepo(io, () => _revParse(io, rest)),
      'ls-files' => _needRepo(io, () => _lsFiles(io, rest)),
      'branch' => _needRepo(io, () => _branch(io, rest, global.config)),
      'tag' => _needRepo(io, () => _tag(io, rest, global.config)),
      'checkout' => _needRepo(io, () => _checkout(io, rest, global.config)),
      'switch' => _needRepo(io, () => _switch(io, rest, global.config)),
      'restore' => _needRepo(io, () => _restore(io, rest)),
      'reset' => _needRepo(io, () => _reset(io, rest, global.config)),
      'merge' => _needRepo(io, () => _merge(io, rest, global.config)),
      'stash' => _needRepo(io, () => _stash(io, rest, global.config)),
      'apply' => _needRepo(io, () => _apply(io, rest)),
      'remote' => _needRepo(io, () => _remote(io, rest)),
      'fetch' => _needRepo(io, () => _fetch(io, rest)),
      'pull' => _needRepo(io, () => _pull(io, rest, global.config)),
      'push' => _needRepo(io, () => _push(io, rest)),
      _ => _unknown(io, command),
    };
  }

  Future<int> _unknown(AppletIo io, String command) {
    io.stderr.writeText(
      "git: '$command' is not a git command. See 'git --help'.\n",
    );
    return Future<int>.value(1);
  }

  Future<int> _init(
    AppletIo io,
    List<String> args, {
    required bool bare,
  }) async {
    const usage = 'usage: git init [<options>] [<directory>]';
    final parsed = parseGitArgs(args, const [
      GitOption('quiet', short: 'q'),
      GitOption('bare'),
      GitOption('initial-branch', short: 'b', valued: true),
      GitOption('object-format', valued: true),
    ], usage: usage);
    if (parsed.operands.length > 1) {
      throw const GitUsage('usage: git init [<options>] [<directory>]\n');
    }
    final branch = parsed.value('initial-branch') ?? 'main';
    final directory = parsed.operands.isEmpty
        ? io.cwd
        : _join(io.cwd, parsed.operands.single);
    final gitDir = (bare || parsed.has('bare')) ? directory : '$directory/.git';
    await io.fs.mkdir('$gitDir/objects', recursive: true);
    await io.fs.mkdir('$gitDir/refs', recursive: true);
    await io.fs.mkdir('$gitDir/info', recursive: true);
    final headPath = '$gitDir/HEAD';
    var keepHead = false;
    if (parsed.value('initial-branch') == null) {
      try {
        await io.fs.readBytes(headPath);
        keepHead = true;
      } on VfsException {
        keepHead = false;
      }
    }
    if (!keepHead) {
      await io.fs.writeBytes(
        headPath,
        Uint8List.fromList(utf8.encode('ref: refs/heads/$branch\n')),
      );
    }
    final format = parsed.value('object-format');
    if (format != null && format != 'sha1') {
      if (format != 'sha256') {
        throw GitUsage(
          "fatal: unknown object format '$format'\n",
          exitCode: 128,
        );
      }
      await io.fs.writeBytes(
        '$gitDir/object-format',
        Uint8List.fromList(utf8.encode('sha256\n')),
      );
    }
    final configPath = '$gitDir/config';
    try {
      await io.fs.readBytes(configPath);
    } on VfsException {
      final bareRepo = bare || parsed.has('bare');
      await io.fs.writeBytes(
        configPath,
        Uint8List.fromList(
          utf8.encode(
            '[core]\n'
            '\trepositoryformatversion = 0\n'
            '\tfilemode = true\n'
            '\tbare = ${bareRepo ? 'true' : 'false'}\n'
            '\tlogallrefupdates = true\n',
          ),
        ),
      );
    }
    if (!parsed.has('quiet')) {
      io.stdout.writeText('Initialized empty Git repository in $gitDir/\n');
    }
    return 0;
  }

  Future<int> _status(AppletIo io, List<String> args) async {
    const usage = 'usage: git status [<options>] [--] [<pathspec>...]';
    final parsed = parseGitArgs(args, const [
      GitOption('short', short: 's'),
      GitOption('branch', short: 'b'),
      GitOption('porcelain', valued: true, optional: true),
      GitOption('ignored'),
      GitOption('untracked-files', short: 'u', valued: true, optional: true),
    ], usage: usage);
    final repo = await _repo(io);
    final untracked = _untrackedMode(parsed);
    final report = await repo.status(
      pathspecs: parsed.operands.isEmpty ? null : parsed.operands,
      includeIgnored: parsed.has('ignored'),
    );
    final head = await repo.readReference('HEAD');
    final branch = _branchOf(head?.targetReferenceName);
    final committed = await repo.revParse('HEAD') != null;
    if (parsed.has('porcelain') || parsed.has('short')) {
      final porcelain = parsed.value('porcelain');
      if (porcelain != null && porcelain.isNotEmpty && porcelain != 'v1') {
        throw GitUsage(
          'fatal: unsupported porcelain version: $porcelain\n',
          exitCode: 128,
        );
      }
      if (parsed.has('branch')) {
        writeGitBranchHeader(io, branch, committed: committed);
      }
      writeGitShortStatus(io, report, showUntracked: untracked != 'no');
      return 0;
    }
    writeGitLongStatus(
      io,
      branch: branch,
      committed: committed,
      report: report,
      showUntracked: untracked != 'no',
    );
    return 0;
  }

  Future<int> _add(AppletIo io, List<String> args) async {
    const usage = 'usage: git add [<options>] [--] <pathspec>...';
    final parsed = parseGitArgs(args, const [
      GitOption('all', short: 'A'),
      GitOption('update', short: 'u'),
      GitOption('force', short: 'f'),
    ], usage: usage);
    if (parsed.operands.isEmpty &&
        !parsed.has('all') &&
        !parsed.has('update')) {
      io.stderr.writeText(
        'Nothing specified, nothing added.\n'
        "hint: Maybe you wanted to say 'git add .'?\n",
      );
      return 0;
    }
    final repo = await _repo(io);
    final specs = parsed.operands.isEmpty
        ? const <String>['.']
        : parsed.operands;
    if (parsed.has('update')) {
      final paths = await _trackedChanges(repo, specs);
      if (paths.isNotEmpty) {
        await repo.add(paths, includeIgnored: parsed.has('force'));
      }
      return 0;
    }
    await repo.add(specs, includeIgnored: parsed.has('force'));
    return 0;
  }

  Future<int> _commit(
    AppletIo io,
    List<String> args,
    List<({String key, String value})> config,
  ) async {
    final repository = await _repo(io);
    return runGitCommit(
      io,
      repository,
      args,
      author: _author(io, config),
      committer: _committer(io, config),
    );
  }

  Future<int> _log(AppletIo io, List<String> args) async {
    const usage = 'usage: git log [<options>] [<revision>]';
    final plain = <String>[];
    int? dashedCount;
    for (final arg in args) {
      if (RegExp(r'^-\d+$').hasMatch(arg)) {
        dashedCount = int.parse(_piece(arg, 1, arg.length));
        continue;
      }
      plain.add(arg);
    }
    final parsed = parseGitArgs(plain, const [
      GitOption('max-count', short: 'n', valued: true),
      GitOption('oneline'),
      GitOption('first-parent'),
      GitOption('all'),
      GitOption('patch', short: 'p'),
      GitOption('author', valued: true),
      GitOption('grep', valued: true),
    ], usage: usage);
    if (parsed.operands.length > 1) {
      throw const GitUsage(
        'fatal: log path limits are not supported\n',
        exitCode: 128,
      );
    }
    final rawCount = parsed.value('max-count');
    final maxCount = rawCount == null ? dashedCount : int.tryParse(rawCount);
    if (rawCount != null && maxCount == null) {
      throw const GitUsage('fatal: invalid --max-count\n', exitCode: 128);
    }
    final repo = await _repo(io);
    final tips = parsed.has('all')
        ? [for (final branch in await repo.branches()) branch.name]
        : [parsed.operands.isEmpty ? 'HEAD' : parsed.operands.single];
    final entries = <GitLogEntry>[];
    final seen = <String>{};
    for (final tip in tips) {
      final page = await repo.log(
        tip,
        maxCount: maxCount,
        firstParent: parsed.has('first-parent'),
      );
      for (final entry in page) {
        if (seen.add(entry.objectId.hex)) entries.add(entry);
      }
    }
    final authorFilter = parsed.value('author');
    final grep = parsed.value('grep');
    for (final entry in entries) {
      if (authorFilter != null &&
          !entry.commit.author.name.contains(authorFilter)) {
        continue;
      }
      if (grep != null && !entry.commit.message.contains(grep)) continue;
      if (parsed.has('oneline')) {
        io.stdout.writeText(
          '${_abbr(entry.objectId.hex)} ${_subject(entry.commit.message)}\n',
        );
        continue;
      }
      _writeCommitHeader(io, entry.objectId.hex, entry.commit);
      if (parsed.has('patch') && entry.commit.parents.isNotEmpty) {
        final patch = await repo.diffRevisions(
          entry.commit.parents.first.hex,
          entry.objectId.hex,
        );
        io.stdout.writeText(_shortenDiff(const GitDiffCodec().encode(patch)));
      }
    }
    return 0;
  }

  Future<int> _diff(AppletIo io, List<String> args) async {
    const usage = 'usage: git diff [<options>] [--] [<path>...]';
    final parsed = parseGitArgs(args, gitDiffParseOptions, usage: usage);
    final repo = await _repo(io);
    final split = _splitDiffOperands(parsed.operands);
    final pathspecs = split.pathspecs;
    final revs = split.revOperands;
    final staged = parsed.has('staged') || parsed.has('cached');

    List<GitDiffEntry> entries;
    if (staged) {
      final ref = revs.isEmpty ? 'HEAD' : revs.first;
      if (revs.length > 1) {
        throw const GitUsage('$usage\n');
      }
      entries = await repo.diff(
        staged: true,
        referenceName: ref,
        pathspecs: pathspecs.isEmpty ? null : pathspecs,
      );
    } else if (revs.isEmpty) {
      entries = await repo.diff(
        pathspecs: pathspecs.isEmpty ? null : pathspecs,
      );
    } else if (parsed.has('merge-base') &&
        revs.length == 2 &&
        !revs.any((r) => r.contains('...'))) {
      final other = revs.first;
      final tip = revs.last;
      final mb = await repo.mergeBase(other, tip);
      if (mb == null) {
        throw const GitUsage('fatal: no merge base found\n', exitCode: 128);
      }
      entries = await repo.diffRevisions(
        mb.hex,
        tip,
        pathspecs: pathspecs.isEmpty ? null : pathspecs,
      );
    } else if (revs.length == 1 && revs.single.contains('...')) {
      final parts = revs.single.split('...');
      if (parts.length != 2) throw const GitUsage('$usage\n');
      final left = parts.first.trim();
      final right = parts.last.trim();
      final mb = await repo.mergeBase(left, right);
      if (mb == null) {
        throw const GitUsage('fatal: no merge base found\n', exitCode: 128);
      }
      entries = await repo.diffRevisions(
        mb.hex,
        right,
        pathspecs: pathspecs.isEmpty ? null : pathspecs,
      );
    } else if (revs.isNotEmpty &&
        await repo.revParse(revs.first) != null &&
        (revs.length == 1 || await repo.revParse(revs[1]) != null)) {
      if (revs.length > 2) throw const GitUsage('$usage\n');
      if (revs.length == 1) {
        entries = await repo.diffRevisions(
          'HEAD',
          revs.first,
          pathspecs: pathspecs.isEmpty ? null : pathspecs,
        );
      } else {
        var oldRev = revs.first;
        var newRev = revs[1];
        if (parsed.has('R')) {
          final swap = oldRev;
          oldRev = newRev;
          newRev = swap;
        }
        entries = await repo.diffRevisions(
          oldRev,
          newRev,
          pathspecs: pathspecs.isEmpty ? null : pathspecs,
        );
      }
    } else {
      throw const GitUsage('$usage\n');
    }

    if (parsed.has('quiet')) {
      return _diffExitCode(parsed, entries);
    }
    io.stdout.writeText(_renderDiff(parsed, entries));
    return _diffExitCode(parsed, entries);
  }

  Future<int> _show(AppletIo io, List<String> args) async {
    const usage = 'usage: git show [<options>] [<object>]';
    final parsed = parseGitArgs(args, const [
      GitOption('oneline'),
    ], usage: usage);
    if (parsed.operands.length > 1) throw const GitUsage('$usage\n');
    final repo = await _repo(io);
    final revision = parsed.operands.isEmpty ? 'HEAD' : parsed.operands.single;
    final colon = revision.indexOf(':');
    if (colon > 0) {
      final rev = _piece(revision, 0, colon);
      final path = _piece(revision, colon + 1, revision.length);
      final entry = await repo.treeEntry(rev, path);
      if (entry == null) {
        io.stderr.writeText("fatal: path '$path' does not exist in '$rev'\n");
        return 128;
      }
      final blob = await repo.show(entry.objectId.hex);
      if (blob == null) return 128;
      io.stdout.writeText(utf8.decode(blob.bytes, allowMalformed: true));
      return 0;
    }
    final object = await repo.show(revision);
    if (object == null) {
      io.stderr.writeText(
        "fatal: ambiguous argument '$revision': unknown revision or path\n",
      );
      return 128;
    }
    if (object.type == GitObjectType.commit) {
      final commit = const GitCommitCodec().decode(object.bytes);
      final id = await repo.revParse(revision);
      if (parsed.has('oneline')) {
        io.stdout.writeText('${_abbr(id!.hex)} ${_subject(commit.message)}\n');
      } else {
        _writeCommitHeader(io, id!.hex, commit);
      }
      if (commit.parents.isNotEmpty) {
        final patch = await repo.diffRevisions(
          commit.parents.first.hex,
          id.hex,
        );
        final diff = _shortenDiff(const GitDiffCodec().encode(patch));
        io.stdout.writeText(parsed.has('oneline') ? diff : '\n$diff');
      }
      return 0;
    }
    io.stdout.writeText(utf8.decode(object.bytes, allowMalformed: true));
    if (object.bytes.isEmpty || object.bytes.last != 0x0a) {
      io.stdout.writeText('\n');
    }
    return 0;
  }

  Future<int> _revParse(AppletIo io, List<String> args) async {
    const usage = 'usage: git rev-parse [<options>] [<args>...]';
    final parsed = parseGitArgs(args, const [
      GitOption('abbrev-ref'),
      GitOption('verify'),
      GitOption('quiet', short: 'q'),
      GitOption('short', valued: true, optional: true),
      GitOption('show-toplevel'),
      GitOption('git-dir'),
    ], usage: usage);
    final repo = await _repo(io);
    if (parsed.has('show-toplevel')) {
      io.stdout.writeText('${repo.path}\n');
    }
    if (parsed.has('git-dir')) {
      io.stdout.writeText('${repo.gitDirectoryPath}\n');
    }
    if (parsed.has('show-toplevel') || parsed.has('git-dir')) {
      if (parsed.operands.isEmpty) return 0;
    }
    if (parsed.operands.isEmpty) throw const GitUsage('$usage\n');
    final length = int.tryParse(parsed.value('short') ?? '') ?? 7;
    for (final revision in parsed.operands) {
      if (parsed.has('abbrev-ref')) {
        io.stdout.writeText('${await _abbrev(repo, revision)}\n');
        continue;
      }
      final id = await repo.revParse(revision);
      if (id == null) {
        if (!parsed.has('quiet')) {
          io.stderr.writeText(
            "fatal: ambiguous argument '$revision': unknown revision or path\n",
          );
        }
        return parsed.has('verify') ? 1 : 128;
      }
      final hex = parsed.has('short') ? _abbr(id.hex, length) : id.hex;
      io.stdout.writeText('$hex\n');
    }
    return 0;
  }

  Future<int> _lsFiles(AppletIo io, List<String> args) async {
    const usage = 'usage: git ls-files [<options>] [--] [<path>...]';
    final parsed = parseGitArgs(args, const [
      GitOption('others', short: 'o'),
      GitOption('ignored', short: 'i'),
      GitOption('cached', short: 'c'),
      GitOption('stage', short: 's'),
      GitOption('z'),
    ], usage: usage);
    final cached =
        parsed.has('cached') ||
        (!parsed.has('others') && !parsed.has('ignored'));
    final repo = await _repo(io);
    final entries = await repo.lsFiles(
      includeUntracked: parsed.has('others'),
      includeIgnored: parsed.has('ignored'),
      pathspecs: parsed.operands.isEmpty ? null : parsed.operands,
    );
    final end = parsed.has('z') ? '\x00' : '\n';
    for (final entry in entries) {
      if (entry.tracked && !cached) continue;
      if (!entry.tracked && parsed.has('stage')) {
        io.stdout.writeText('${entry.path}$end');
        continue;
      }
      if (parsed.has('stage') && entry.tracked) {
        io.stdout.writeText(
          '${_mode(entry.mode!)} ${entry.objectId!.hex} ${entry.stage}\t${entry.path}$end',
        );
        continue;
      }
      io.stdout.writeText('${entry.path}$end');
    }
    return 0;
  }

  Future<int> _branch(
    AppletIo io,
    List<String> args,
    List<({String key, String value})> config,
  ) async {
    final repo = await _repo(io);
    return runGitBranch(io, repo, args, committer: _committer(io, config));
  }

  Future<int> _tag(
    AppletIo io,
    List<String> args,
    List<({String key, String value})> config,
  ) async {
    const usage = 'usage: git tag [<options>] [<name> [<commit>]]';
    final parsed = parseGitArgs(args, const [
      GitOption('delete', short: 'd'),
      GitOption('annotate', short: 'a'),
      GitOption('message', short: 'm', valued: true),
      GitOption('force', short: 'f'),
      GitOption('list', short: 'l'),
    ], usage: usage);
    final repo = await _repo(io);
    if (parsed.has('delete')) {
      if (parsed.operands.isEmpty) {
        throw const GitUsage('fatal: tag name required\n', exitCode: 128);
      }
      for (final name in parsed.operands) {
        final reference = 'refs/tags/$name';
        final id = await repo.resolveReferenceObjectId(reference);
        if (id == null) {
          io.stderr.writeText("error: tag '$name' not found.\n");
          return 1;
        }
        await repo.deleteReference(reference);
        io.stdout.writeText("Deleted tag '$name' (was ${_abbr(id.hex)}).\n");
      }
      return 0;
    }
    if (parsed.operands.isEmpty || parsed.has('list')) {
      final tags = await repo.tags();
      for (final tag in tags) {
        if (parsed.operands.isEmpty || parsed.operands.contains(tag.name)) {
          io.stdout.writeText('${tag.name}\n');
        }
      }
      return 0;
    }
    if (parsed.operands.length > 2) throw const GitUsage('$usage\n');
    await repo.tag(
      parsed.operands.first,
      target: parsed.operands.length == 2 ? parsed.operands[1] : 'HEAD',
      message: parsed.value('message'),
      force: parsed.has('force'),
      tagger: _author(io, config),
    );
    return 0;
  }

  Future<int> _checkout(
    AppletIo io,
    List<String> args,
    List<({String key, String value})> config,
  ) {
    const usage = 'usage: git checkout [<options>] [--] <branch>';
    final parsed = parseGitArgs(args, const [
      GitOption('branch', short: 'b', valued: true),
      GitOption('force-branch', short: 'B', valued: true),
      GitOption('force', short: 'f'),
    ], usage: usage);
    return _switchTo(
      io,
      config,
      create: parsed.has('branch') || parsed.has('force-branch'),
      forceCreate: parsed.has('force-branch'),
      force: parsed.has('force') || parsed.has('force-branch'),
      detach: false,
      name: parsed.value('force-branch') ?? parsed.value('branch'),
      operands: parsed.operands,
      separated: parsed.separated,
    );
  }

  Future<int> _switch(
    AppletIo io,
    List<String> args,
    List<({String key, String value})> config,
  ) {
    const usage = 'usage: git switch [<options>] [<branch>]';
    final parsed = parseGitArgs(args, const [
      GitOption('create', short: 'c', valued: true),
      GitOption('force-create', short: 'C', valued: true),
      GitOption('discard-changes'),
      GitOption('force', short: 'f'),
      GitOption('detach', short: 'd'),
    ], usage: usage);
    return _switchTo(
      io,
      config,
      create: parsed.has('create') || parsed.has('force-create'),
      forceCreate: parsed.has('force-create'),
      force:
          parsed.has('force') ||
          parsed.has('discard-changes') ||
          parsed.has('force-create'),
      detach: parsed.has('detach'),
      name: parsed.value('force-create') ?? parsed.value('create'),
      operands: parsed.operands,
      separated: parsed.separated,
    );
  }

  Future<int> _switchTo(
    AppletIo io,
    List<({String key, String value})> config, {
    required bool create,
    required bool forceCreate,
    required bool force,
    required bool detach,
    required String? name,
    required List<String> operands,
    required bool separated,
  }) async {
    if (create && detach) {
      throw const GitUsage(
        'fatal: --detach cannot be used with --create\n',
        exitCode: 128,
      );
    }
    if (separated && !create) {
      return _restorePaths(
        io,
        operands,
        source: null,
        staged: false,
        workTree: true,
      );
    }
    final target = name ?? (operands.isEmpty ? null : operands.first);
    final start = name == null
        ? (operands.length > 1 ? operands[1] : null)
        : (operands.isEmpty ? null : operands.first);
    if (target == null || (name != null && operands.length > 1)) {
      throw const GitUsage(
        'fatal: missing branch or commit argument\n',
        exitCode: 128,
      );
    }
    if (name == null && operands.length > 1 && !create) {
      throw const GitUsage(
        'fatal: use -- to separate paths from revisions\n',
        exitCode: 128,
      );
    }
    final repo = await _repo(io);
    final before = _branchOf(
      (await repo.readReference('HEAD'))?.targetReferenceName,
    );
    if (!create && !detach && before == target && !force) {
      io.stderr.writeText("Already on '$target'\n");
      return 0;
    }
    final checkoutTarget = detach && !create
        ? (await repo.revParse(target))?.hex ?? target
        : target;
    final result = await repo.checkout(
      checkoutTarget,
      create: create,
      startPoint: start ?? 'HEAD',
      force: force || forceCreate,
      detachedLabel: detach && !create
          ? await _detachedLabel(repo, target)
          : null,
      reflogActor: _committer(io, config),
    );
    if (create) {
      io.stderr.writeText("Switched to a new branch '$target'\n");
      return 0;
    }
    if (result.detached || detach) {
      final commit = const GitCommitCodec().decode(
        (await repo.show(result.objectId.hex))!.bytes,
      );
      io.stderr.writeText(
        'HEAD is now at ${_abbr(result.objectId.hex)} ${_subject(commit.message)}\n',
      );
      return 0;
    }
    io.stderr.writeText("Switched to branch '$target'\n");
    return 0;
  }

  Future<int> _restore(AppletIo io, List<String> args) async {
    const usage = 'usage: git restore [<options>] [--] <path>...';
    final parsed = parseGitArgs(args, const [
      GitOption('staged'),
      GitOption('worktree'),
      GitOption('source', short: 's', valued: true),
    ], usage: usage);
    if (parsed.operands.isEmpty) throw const GitUsage('$usage\n');
    final staged = parsed.has('staged');
    return _restorePaths(
      io,
      parsed.operands,
      source: parsed.value('source'),
      staged: staged,
      workTree: parsed.has('worktree') || !staged,
    );
  }

  Future<int> _reset(
    AppletIo io,
    List<String> args,
    List<({String key, String value})> config,
  ) async {
    const usage = 'usage: git reset [<mode>] [<commit>] [--] [<path>...]';
    final parsed = parseGitArgs(args, const [
      GitOption('soft'),
      GitOption('mixed'),
      GitOption('hard'),
    ], usage: usage);
    var mode = GitResetMode.mixed;
    if (parsed.has('soft')) mode = GitResetMode.soft;
    if (parsed.has('mixed')) mode = GitResetMode.mixed;
    if (parsed.has('hard')) mode = GitResetMode.hard;
    final repo = await _repo(io);
    final paths = await _resetPaths(repo, parsed);
    if (paths != null) {
      if (mode == GitResetMode.soft) {
        throw const GitUsage(
          'fatal: Cannot do soft reset with paths.\n',
          exitCode: 128,
        );
      }
      await _restorePaths(
        io,
        paths.paths,
        source: paths.source,
        staged: true,
        workTree: mode == GitResetMode.hard,
      );
      if (mode == GitResetMode.mixed) {
        final after = await repo.status(pathspecs: paths.paths);
        final dirty = [
          for (final entry in after.entries)
            if (entry.isUnstaged && !entry.isUntracked) entry,
        ];
        if (dirty.isNotEmpty) {
          io.stdout.writeText('Unstaged changes after reset:\n');
          for (final entry in dirty) {
            io.stdout.writeText('M\t${entry.path}\n');
          }
        }
      }
      return 0;
    }
    final result = await repo.reset(
      parsed.operands.isEmpty ? 'HEAD' : parsed.operands.single,
      mode: mode,
      reflogActor: _committer(io, config),
    );
    if (mode == GitResetMode.hard) {
      final commitObject = await repo.show(result.objectId.hex);
      if (commitObject != null) {
        final commit = const GitCommitCodec().decode(commitObject.bytes);
        io.stdout.writeText(
          'HEAD is now at ${_abbr(result.objectId.hex)} ${_subject(commit.message)}\n',
        );
      }
    }
    return 0;
  }

  Future<int> _merge(
    AppletIo io,
    List<String> args,
    List<({String key, String value})> config,
  ) async {
    const usage = 'usage: git merge [<options>] [<commit>]';
    final parsed = parseGitArgs(args, const [
      GitOption('continue'),
      GitOption('abort'),
      GitOption('message', short: 'm', valued: true),
      GitOption('ff-only'),
      GitOption('no-ff'),
    ], usage: usage);
    final repo = await _repo(io);
    if (parsed.has('continue')) {
      final result = await repo.mergeContinue(
        author: _author(io, config),
        committer: _committer(io, config),
      );
      io.stdout.writeText('${_mergeText(result.status)}\n');
      return result.status == GitMergeStatus.conflict ? 1 : 0;
    }
    if (parsed.has('abort')) {
      await repo.mergeAbort();
      return 0;
    }
    if (parsed.operands.length != 1) throw const GitUsage('$usage\n');
    if (parsed.has('no-ff')) {
      throw const GitUsage(
        'fatal: merge --no-ff is not supported\n',
        exitCode: 128,
      );
    }
    if (parsed.has('ff-only')) {
      final base = await repo.mergeBase('HEAD', parsed.operands.single);
      final head = await repo.revParse('HEAD');
      if (base == null || base != head) {
        throw const GitUsage(
          'fatal: Not possible to fast-forward, aborting.\n',
          exitCode: 128,
        );
      }
    }
    final result = await repo.merge(
      parsed.operands.single,
      author: _author(io, config),
      committer: _committer(io, config),
      message: parsed.value('message'),
    );
    if (result.status == GitMergeStatus.fastForward &&
        result.currentObjectId != null &&
        result.resultObjectId != null) {
      final entries = await repo.diffRevisions(
        result.currentObjectId!.hex,
        result.resultObjectId!.hex,
      );
      io.stdout.writeText(
        'Updating ${_abbr(result.currentObjectId!.hex)}..'
        '${_abbr(result.resultObjectId!.hex)}\n'
        'Fast-forward\n'
        '${_diffStat(entries)}',
      );
      return 0;
    }
    io.stdout.writeText('${_mergeText(result.status)}\n');
    return result.status == GitMergeStatus.conflict ? 1 : 0;
  }

  Future<int> _stash(
    AppletIo io,
    List<String> args,
    List<({String key, String value})> config,
  ) async {
    const usage = 'usage: git stash [push|pop|apply|drop|list] [<options>]';
    const actions = {'push', 'pop', 'apply', 'drop', 'list', 'save'};
    final action = args.isNotEmpty && actions.contains(args.first)
        ? args.first
        : 'push';
    final rest = args.isNotEmpty && actions.contains(args.first)
        ? args.sublist(1)
        : args;
    final parsed = parseGitArgs(rest, const [
      GitOption('include-untracked', short: 'u'),
      GitOption('message', short: 'm', valued: true),
      GitOption('keep-index'),
      GitOption('index'),
    ], usage: usage);
    final repo = await _repo(io);
    final revision = parsed.operands.isEmpty ? null : parsed.operands.single;
    switch (action) {
      case 'push' || 'save':
        final result = await repo.stash(
          message:
              parsed.value('message') ?? (action == 'save' ? revision : null),
          includeUntracked: parsed.has('include-untracked'),
          keepIndex: parsed.has('keep-index'),
          author: _author(io, config),
          committer: _committer(io, config),
        );
        io.stdout.writeText(
          result.created
              ? 'Saved working directory and index state ${result.message}\n'
              : 'No local changes to save\n',
        );
        return 0;
      case 'pop':
        final result = await repo.stashPop(
          revision: revision ?? 'stash',
          reinstateIndex: parsed.has('index'),
        );
        if (result.applied) await _status(io, const []);
        final drop = result.dropResult;
        if (drop != null) {
          io.stdout.writeText(
            _droppedLine(drop.revision, drop.stashObjectId.hex),
          );
        }
        return result.applied ? 0 : 1;
      case 'apply':
        final result = await repo.stashApply(
          revision: revision ?? 'stash',
          reinstateIndex: parsed.has('index'),
        );
        return result.applied ? 0 : 1;
      case 'drop':
        final result = await repo.stashDrop(revision: revision ?? 'stash@{0}');
        io.stdout.writeText(
          _droppedLine(result.revision, result.stashObjectId.hex),
        );
        return 0;
      case 'list':
        final entries = await repo.stashList();
        for (final entry in entries) {
          io.stdout.writeText('${entry.revision}: ${entry.message}\n');
        }
        return 0;
      default:
        throw const GitUsage('$usage\n');
    }
  }

  Future<int> _apply(AppletIo io, List<String> args) async {
    const usage = 'usage: git apply [<options>] [<patch>...]';
    final parsed = parseGitArgs(args, const [
      GitOption('check'),
      GitOption('3way', short: '3'),
      GitOption('abort'),
    ], usage: usage);
    final repo = await _repo(io);
    if (parsed.has('abort')) {
      await repo.applyAbort();
      return 0;
    }
    final chunks = <String>[];
    if (parsed.operands.isEmpty) {
      chunks.add(utf8.decode(io.stdin));
    }
    for (final operand in parsed.operands) {
      if (operand == '-') {
        chunks.add(utf8.decode(io.stdin));
        continue;
      }
      chunks.add(utf8.decode(await io.fs.readBytes(_join(io.cwd, operand))));
    }
    await repo.applyPatch(
      chunks.join(),
      check: parsed.has('check'),
      threeWay: parsed.has('3way'),
    );
    return 0;
  }

  Future<int> _remote(AppletIo io, List<String> args) async {
    const usage =
        'usage: git remote [-v] [add|remove|get-url|set-url] [<args>]';
    final parsed = parseGitArgs(args, const [
      GitOption('verbose', short: 'v'),
    ], usage: usage);
    final repo = await _repo(io);
    if (parsed.operands.isEmpty) {
      for (final remote in await repo.remotes()) {
        if (!parsed.has('verbose')) {
          io.stdout.writeText('${remote.name}\n');
          continue;
        }
        final push = remote.pushUrl ?? remote.url;
        io.stdout.writeText('${remote.name}\t${remote.url} (fetch)\n');
        io.stdout.writeText('${remote.name}\t$push (push)\n');
      }
      return 0;
    }
    final action = parsed.operands.first;
    final tail = parsed.operands.sublist(1);
    switch (action) {
      case 'add':
        if (tail.length != 2) throw const GitUsage('$usage\n');
        await repo.setRemote(GitRemote(name: tail.first, url: tail[1]));
        return 0;
      case 'remove' || 'rm':
        if (tail.length != 1) throw const GitUsage('$usage\n');
        final removed = await repo.deleteRemote(tail.single);
        if (!removed) {
          io.stderr.writeText("fatal: No such remote: '${tail.single}'\n");
          return 128;
        }
        return 0;
      case 'get-url':
        if (tail.length != 1) throw const GitUsage('$usage\n');
        final remote = await repo.remote(tail.single);
        if (remote == null) {
          io.stderr.writeText("fatal: No such remote: '${tail.single}'\n");
          return 128;
        }
        io.stdout.writeText('${remote.url}\n');
        return 0;
      case 'set-url':
        if (tail.length != 2) throw const GitUsage('$usage\n');
        final remote = await repo.remote(tail.first);
        if (remote == null) {
          io.stderr.writeText("fatal: No such remote: '${tail.first}'\n");
          return 128;
        }
        await repo.setRemote(
          GitRemote(
            name: remote.name,
            url: tail[1],
            fetchRefSpecs: remote.fetchRefSpecs,
            pushUrl: remote.pushUrl,
          ),
        );
        return 0;
      default:
        throw const GitUsage('$usage\n');
    }
  }

  Future<int> _clone(AppletIo io, List<String> args) async {
    const usage = 'usage: git clone [<options>] [--] <repo> [<dir>]';
    final parsed = parseGitArgs(args, const [
      GitOption('quiet', short: 'q'),
      GitOption('branch', short: 'b', valued: true),
      GitOption('origin', short: 'o', valued: true),
      GitOption('depth', valued: true),
      GitOption('filter', valued: true),
      GitOption('bare'),
    ], usage: usage);
    if (parsed.operands.isEmpty || parsed.operands.length > 2) {
      throw const GitUsage('$usage\n');
    }
    if (parsed.has('bare')) {
      throw const GitUsage(
        'fatal: clone --bare is not supported\n',
        exitCode: 128,
      );
    }
    final url = parsed.operands.first;
    final directory = parsed.operands.length == 2
        ? parsed.operands[1]
        : _cloneDirectoryName(url);
    final depth = parsed.value('depth');
    if (depth != null) {
      final number = int.tryParse(depth);
      if (number == null || number < 1) {
        throw GitUsage(
          'fatal: depth $depth is not a positive number\n',
          exitCode: 128,
        );
      }
    }
    final localPath = !_networkUrl(url) && !url.startsWith('file://');
    if (!parsed.has('quiet')) {
      io.stderr.writeText("Cloning into '$directory'...\n");
    }
    final shallow = depth == null ? null : int.parse(depth);
    if (shallow != null && localPath) {
      io.stderr.writeText(
        'warning: --depth is ignored in local clones; use file:// instead.\n',
      );
    }
    await GitRepository.clone(
      url,
      _join(io.cwd, directory),
      remoteName: parsed.value('origin') ?? 'origin',
      branchName: parsed.value('branch'),
      depth: shallow != null && (_networkUrl(url) || url.startsWith('file://'))
          ? shallow
          : null,
      filter: parsed.value('filter'),
      httpHeaders: _extraHeaders(io),
    );
    if (!parsed.has('quiet') && localPath) io.stderr.writeText('done.\n');
    return 0;
  }

  Future<int> _fetch(AppletIo io, List<String> args) async {
    const usage = 'usage: git fetch [<options>] [<repository> [<refspec>...]]';
    final parsed = parseGitArgs(args, const [
      GitOption('dry-run'),
      GitOption('quiet', short: 'q'),
      GitOption('depth', valued: true),
      GitOption('filter', valued: true),
      GitOption('prune'),
      GitOption('tags'),
    ], usage: usage);
    final depth = int.tryParse(parsed.value('depth') ?? '');
    if (parsed.has('depth') && (depth == null || depth < 1)) {
      throw GitUsage(
        'fatal: depth ${parsed.value('depth')} is not a positive number\n',
        exitCode: 128,
      );
    }
    final network = _network(parsed, fallback: 'origin');
    final repo = await _repo(io);
    final specs = [
      ...?network.refSpecs,
      if (parsed.has('tags')) GitRefSpec.parse('refs/tags/*:refs/tags/*'),
    ];
    final result = await repo.fetch(
      network.remote,
      dryRun: parsed.has('dry-run'),
      depth: depth,
      filter: parsed.value('filter'),
      refSpecs: specs.isEmpty ? null : specs,
      httpHeaders: _extraHeaders(io),
    );
    if (parsed.has('prune') && !parsed.has('dry-run')) {
      final prefix = 'refs/remotes/${network.remote}/';
      final kept = {
        for (final reference in result.references)
          reference.destinationReferenceName,
      };
      for (final reference in await repo.references(prefix: prefix)) {
        if (kept.contains(reference.referenceName)) continue;
        await repo.deleteReference(reference.referenceName);
      }
    }
    if (parsed.has('quiet')) return 0;
    if (result.references.isNotEmpty) {
      io.stdout.writeText('From ${result.remoteUrl}\n');
    }
    for (final reference in result.references) {
      io.stdout.writeText(_fetchLine(reference));
    }
    return 0;
  }

  Future<int> _pull(
    AppletIo io,
    List<String> args,
    List<({String key, String value})> config,
  ) async {
    const usage = 'usage: git pull [<options>] [<repository>]';
    final parsed = parseGitArgs(args, const [
      GitOption('dry-run'),
      GitOption('quiet', short: 'q'),
      GitOption('ff-only'),
      GitOption('no-ff'),
      GitOption('rebase'),
    ], usage: usage);
    if (parsed.has('rebase')) {
      throw const GitUsage(
        'fatal: pull --rebase is not supported\n',
        exitCode: 128,
      );
    }
    final network = _network(parsed, fallback: 'origin');
    final repo = await _repo(io);
    final result = await repo.pull(
      network.remote,
      dryRun: parsed.has('dry-run'),
      strategy: parsed.has('no-ff')
          ? GitPullStrategy.merge
          : GitPullStrategy.fastForward,
      author: _author(io, config),
      committer: _committer(io, config),
      httpHeaders: _extraHeaders(io),
    );
    if (!parsed.has('quiet')) io.stdout.writeText('${result.status.name}\n');
    return result.status == GitPullStatus.conflict ? 1 : 0;
  }

  Future<int> _push(AppletIo io, List<String> args) async {
    const usage = 'usage: git push [<options>] [<repository> [<refspec>...]]';
    final parsed = parseGitArgs(args, const [
      GitOption('dry-run'),
      GitOption('quiet', short: 'q'),
      GitOption('force', short: 'f'),
      GitOption('set-upstream', short: 'u'),
    ], usage: usage);
    final network = _network(parsed, fallback: 'origin');
    final repo = await _repo(io);
    final result = await repo.push(
      network.remote,
      dryRun: parsed.has('dry-run'),
      force: parsed.has('force'),
      setUpstream: parsed.has('set-upstream'),
      refSpecs: network.refSpecs,
      httpHeaders: _extraHeaders(io),
    );
    if (parsed.has('quiet')) return 0;
    for (final reference in result.references) {
      io.stdout.writeText(
        '${reference.status.name} ${reference.destinationReferenceName}\n',
      );
    }
    return 0;
  }

  /// Сначала репозиторий, потом опции: вне репозитория git отвечает 128,
  /// даже если аргумент сам по себе был бы ошибкой разбора.
  Future<int> _needRepo(AppletIo io, Future<int> Function() body) async {
    await _repo(io);
    return body();
  }

  Future<GitRepository> _repo(AppletIo io) async {
    final repository = await GitRepository.discover(io.cwd);
    if (repository == null) {
      throw const GitUsage(
        'fatal: not a git repository (or any of the parent directories): .git\n',
        exitCode: 128,
      );
    }
    return repository;
  }

  Future<int> _restorePaths(
    AppletIo io,
    List<String> paths, {
    required String? source,
    required bool staged,
    required bool workTree,
  }) async {
    if (paths.isEmpty) {
      throw const GitUsage(
        'fatal: you must specify path(s) to restore\n',
        exitCode: 128,
      );
    }
    final repo = await _repo(io);
    await repo.restore(
      paths,
      source: source,
      staged: staged,
      workTree: workTree,
    );
    return 0;
  }

  Future<({String source, List<String> paths})?> _resetPaths(
    GitRepository repo,
    GitInvocation parsed,
  ) async {
    if (!parsed.separated && parsed.operands.length < 2) return null;
    if (parsed.separated && parsed.operands.isEmpty) return null;
    if (parsed.separated && parsed.operands.length == 1) {
      final only = parsed.operands.single;
      if (await repo.revParse(only) != null && !only.contains('/')) {
        return null;
      }
      return (source: 'HEAD', paths: parsed.operands);
    }
    final first = parsed.operands.first;
    if (await repo.revParse(first) != null) {
      return (source: first, paths: parsed.operands.sublist(1));
    }
    return (source: 'HEAD', paths: parsed.operands);
  }

  Future<List<String>> _trackedChanges(
    GitRepository repo,
    List<String> specs,
  ) async {
    final report = await repo.status();
    return [
      for (final entry in report.entries)
        if (!entry.isUntracked &&
            !entry.isIgnored &&
            entry.isUnstaged &&
            _matches(entry.path, specs))
          entry.path,
    ];
  }

  void _writeCommitHeader(AppletIo io, String hex, GitCommit commit) {
    io.stdout.writeText('commit $hex\n');
    io.stdout.writeText(
      'Author: ${commit.author.name} <${commit.author.email}>\n',
    );
    io.stdout.writeText('Date:   ${_gitDate(commit.author)}\n\n');
    for (final line in const LineSplitter().convert(commit.message)) {
      io.stdout.writeText('    $line\n');
    }
    io.stdout.writeText('\n');
  }

  String _untrackedMode(GitInvocation parsed) {
    final raw = parsed.value('untracked-files');
    if (!parsed.has('untracked-files')) return 'normal';
    if (raw == null || raw.isEmpty) {
      final operand = parsed.operands.isEmpty ? null : parsed.operands.first;
      if (operand == 'no' || operand == 'normal' || operand == 'all') {
        return operand!;
      }
      return 'all';
    }
    return raw;
  }

  GitCommitSignature _author(
    AppletIo io,
    List<({String key, String value})> config,
  ) => _signature(
    io,
    config,
    nameKeys: const ['GIT_AUTHOR_NAME'],
    emailKeys: const ['GIT_AUTHOR_EMAIL'],
    dateKeys: const ['GIT_AUTHOR_DATE'],
    configName: 'user.name',
    configEmail: 'user.email',
  );

  GitCommitSignature _committer(
    AppletIo io,
    List<({String key, String value})> config,
  ) => _signature(
    io,
    config,
    nameKeys: const ['GIT_COMMITTER_NAME', 'GIT_AUTHOR_NAME'],
    emailKeys: const ['GIT_COMMITTER_EMAIL', 'GIT_AUTHOR_EMAIL'],
    dateKeys: const ['GIT_COMMITTER_DATE', 'GIT_AUTHOR_DATE'],
    configName: 'user.name',
    configEmail: 'user.email',
  );

  GitCommitSignature _signature(
    AppletIo io,
    List<({String key, String value})> config, {
    required List<String> nameKeys,
    required List<String> emailKeys,
    required List<String> dateKeys,
    required String configName,
    required String configEmail,
  }) {
    final name =
        _env(io.env, nameKeys) ??
        _configValue(config, configName) ??
        io.profile.user;
    final email =
        _env(io.env, emailKeys) ??
        _configValue(config, configEmail) ??
        '$name@${io.profile.hostname}';
    final rawDate = _env(io.env, dateKeys);
    if (rawDate != null) {
      final parsed = parseGitDate(rawDate);
      if (parsed == null) {
        throw GitUsage('fatal: invalid date format: $rawDate\n', exitCode: 128);
      }
      return GitCommitSignature(
        name: name,
        email: email,
        timestampSeconds: parsed.seconds,
        timezoneOffset: parsed.zone,
      );
    }
    return GitCommitSignature.fromDateTime(
      name: name,
      email: email,
      timestamp: DateTime.now(),
    );
  }

  String? _env(Map<String, String> env, List<String> keys) {
    for (final key in keys) {
      final value = env[key];
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  String? _configValue(List<({String key, String value})> config, String key) {
    String? found;
    for (final pair in config) {
      if (pair.key == key) found = pair.value;
    }
    return found;
  }

  Map<String, String> _extraHeaders(AppletIo io) {
    final line = io.env['GIT_HTTP_EXTRA_HEADER'];
    if (line == null || line.isEmpty) return const {};
    final separator = line.indexOf(':');
    if (separator <= 0) return const {};
    final name = _piece(line, 0, separator).trim();
    final value = _piece(line, separator + 1, line.length).trim();
    if (name.isEmpty) return const {};
    return {name: value};
  }

  String _cloneDirectoryName(String url) {
    final trimmed = url.endsWith('/') ? _piece(url, 0, url.length - 1) : url;
    final slash = trimmed.lastIndexOf('/');
    final colon = trimmed.lastIndexOf(':');
    final cut = slash > colon ? slash : colon;
    final name = cut < 0 ? trimmed : _piece(trimmed, cut + 1, trimmed.length);
    return name.endsWith('.git') ? _piece(name, 0, name.length - 4) : name;
  }

  bool _networkUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('://') || RegExp(r'^[^/]+@[^/]+:').hasMatch(lower);
  }

  _Network _network(GitInvocation parsed, {required String fallback}) {
    if (parsed.operands.isEmpty) {
      return _Network(fallback, null);
    }
    final first = parsed.operands.first;
    if (first.contains(':') ||
        first.startsWith('refs/') ||
        first.startsWith('+')) {
      return _Network(fallback, [
        for (final spec in parsed.operands) GitRefSpec.parse(spec),
      ]);
    }
    final specs = parsed.operands.sublist(1);
    return _Network(
      first,
      specs.isEmpty ? null : [for (final spec in specs) GitRefSpec.parse(spec)],
    );
  }

  String _join(String cwd, String path) => path.startsWith('/')
      ? VfsPath.normalize(path)
      : VfsPath.normalize('$cwd/$path');

  bool _matches(String path, List<String> specs) {
    for (final spec in specs) {
      if (spec == '.' || spec == './') return true;
      if (path == spec || path.startsWith('$spec/')) return true;
    }
    return false;
  }

  Future<String> _abbrev(GitRepository repo, String revision) async {
    if (revision == 'HEAD') {
      final branch = _branchOf(
        (await repo.readReference('HEAD'))?.targetReferenceName,
      );
      return branch ?? 'HEAD';
    }
    if (revision.startsWith('refs/heads/')) {
      return _piece(revision, 'refs/heads/'.length, revision.length);
    }
    return revision;
  }

  /// Имя, которое git пишет в reflog при `switch --detach`.
  ///
  /// Ветка становится `refs/heads/<имя>`: список потом показывает
  /// `(HEAD detached at refs/heads/side)`, а не полный хеш.
  Future<String> _detachedLabel(GitRepository repo, String target) async {
    if (await repo.resolveReferenceObjectId('refs/heads/$target') != null) {
      return 'refs/heads/$target';
    }
    return target;
  }

  String? _branchOf(String? reference) {
    if (reference == null || !reference.startsWith('refs/heads/')) return null;
    return _piece(reference, 'refs/heads/'.length, reference.length);
  }

  /// git печатает `Dropped refs/stash@{n} (<полный хеш>)` без точки.
  String _droppedLine(String revision, String hex) {
    final name = revision.startsWith('refs/') ? revision : 'refs/$revision';
    return 'Dropped $name ($hex)\n';
  }

  String _subject(String message) {
    final end = message.indexOf('\n');
    return end < 0 ? message : _piece(message, 0, end);
  }

  String _abbr(String hex, [int length = 7]) {
    if (length < 1) return _piece(hex, 0, 1);
    if (length >= hex.length) return hex;
    return _piece(hex, 0, length);
  }

  String _mode(int mode) => switch (mode) {
    GitIndexEntry.regularFileMode => '100644',
    GitIndexEntry.executableFileMode => '100755',
    GitIndexEntry.symbolicLinkMode => '120000',
    GitIndexEntry.gitLinkMode => '160000',
    _ => mode.toRadixString(8).padLeft(6, '0'),
  };

  String _fetchLine(GitFetchedReference reference) {
    final destination = reference.destinationReferenceName;
    final source = reference.sourceReferenceName;
    if (reference.previousObjectId == null) {
      return ' * [new branch]      $source -> $destination\n';
    }
    if (reference.status == GitFetchReferenceStatus.upToDate) return '';
    final previous = _abbr(reference.previousObjectId!.hex);
    final next = _abbr(reference.objectId.hex);
    return '   $previous..$next  $source -> $destination\n';
  }

  String _mergeText(GitMergeStatus status) => switch (status) {
    GitMergeStatus.alreadyUpToDate => 'Already up to date.',
    GitMergeStatus.fastForward => 'Fast-forward',
    GitMergeStatus.merged => "Merge made by the 'ort' strategy.",
    GitMergeStatus.conflict =>
      'Automatic merge failed; fix conflicts and then commit the result.',
  };

  String _shortenDiff(String diff) {
    if (diff.isEmpty) return diff;
    final buffer = StringBuffer();
    for (final line in const LineSplitter().convert(diff)) {
      buffer.writeln(line.startsWith('index ') ? _shortenIndex(line) : line);
    }
    return buffer.toString();
  }

  String _shortenIndex(String line) {
    final body = _piece(line, 'index '.length, line.length);
    final dots = body.indexOf('..');
    if (dots < 0) return line;
    final space = body.indexOf(' ', dots);
    final oldHex = _piece(body, 0, dots);
    final newHex = space < 0
        ? _piece(body, dots + 2, body.length)
        : _piece(body, dots + 2, space);
    final suffix = space < 0 ? '' : _piece(body, space, body.length);
    return 'index ${_abbr(oldHex)}..${_abbr(newHex)}$suffix';
  }

  ({List<String> revOperands, List<String> pathspecs}) _splitDiffOperands(
    List<String> operands,
  ) {
    final sep = operands.indexOf('--');
    final revPart = sep < 0 ? operands : operands.sublist(0, sep);
    final tail = sep < 0 ? const <String>[] : operands.sublist(sep + 1);
    return (revOperands: revPart, pathspecs: tail);
  }

  int _diffExitCode(GitInvocation parsed, List<GitDiffEntry> entries) {
    if (!parsed.has('exit-code')) return 0;
    return entries.isEmpty ? 0 : 1;
  }

  String _renderDiff(GitInvocation parsed, List<GitDiffEntry> entries) {
    final hasPatch = parsed.has('patch') && !parsed.has('no-patch');
    final fmtStat = parsed.has('stat') || parsed.has('patch-with-stat');
    final onlyFormats =
        parsed.has('stat') ||
        parsed.has('shortstat') ||
        parsed.has('numstat') ||
        parsed.has('name-only') ||
        parsed.has('name-status');
    var showPatch =
        !parsed.has('no-patch') &&
        (hasPatch || parsed.has('patch-with-stat') || !onlyFormats);
    if (parsed.has('no-patch')) {
      showPatch = false;
    }
    final parts = <String>[];

    if (parsed.has('name-only')) {
      parts.add([for (final entry in entries) '${entry.path}\n'].join());
    }
    if (parsed.has('name-status')) {
      final buf = StringBuffer();
      for (final entry in entries) {
        buf.writeln('${_diffNameStatusLetter(entry)}\t${entry.path}');
      }
      parts.add(buf.toString());
    }
    if (fmtStat) {
      parts.add(_diffStat(entries));
    }
    if (parsed.has('shortstat')) {
      parts.add(entries.isEmpty ? '' : _shortstat(entries));
    }
    if (parsed.has('numstat')) {
      parts.add(_diffNumstat(entries));
    }
    if (showPatch && entries.isNotEmpty) {
      final patchText = const GitDiffCodec().encode(entries);
      parts.add(parsed.has('full-index') ? patchText : _shortenDiff(patchText));
    }

    return parts.join();
  }

  String _diffNameStatusLetter(GitDiffEntry entry) {
    if (entry.conflicted) return 'U';
    return switch (entry.changeType) {
      GitDiffChangeType.added => 'A',
      GitDiffChangeType.deleted => 'D',
      GitDiffChangeType.modified => 'M',
    };
  }

  String _diffNumstat(List<GitDiffEntry> entries) {
    final buf = StringBuffer();
    for (final entry in entries) {
      if (entry.binary) {
        buf.writeln('-\t-\t${entry.path}');
        continue;
      }
      var add = 0;
      var del = 0;
      for (final hunk in entry.hunks) {
        for (final line in hunk.lines) {
          switch (line.type) {
            case GitDiffLineType.addition:
              add++;
            case GitDiffLineType.deletion:
              del++;
            case GitDiffLineType.context:
              break;
          }
        }
      }
      buf.writeln('$add\t$del\t${entry.path}');
    }
    return buf.toString();
  }

  /// Строки `git diff --stat`: график по файлам и сводка.
  ///
  /// Для небольшого diff один `+` или `-` равен одной строке. Ширина числа
  /// берётся по самому длинному счётчику, как у git.
  String _diffStat(List<GitDiffEntry> entries) {
    if (entries.isEmpty) return '';
    final rows = <({String path, int additions, int deletions})>[];
    var pathWidth = 0;
    var countWidth = 1;
    for (final entry in entries) {
      var additions = 0;
      var deletions = 0;
      for (final hunk in entry.hunks) {
        for (final line in hunk.lines) {
          switch (line.type) {
            case GitDiffLineType.addition:
              additions++;
            case GitDiffLineType.deletion:
              deletions++;
            case GitDiffLineType.context:
              break;
          }
        }
      }
      final count = '${additions + deletions}'.length;
      if (entry.path.length > pathWidth) pathWidth = entry.path.length;
      if (count > countWidth) countWidth = count;
      rows.add((path: entry.path, additions: additions, deletions: deletions));
    }
    final buffer = StringBuffer();
    for (final row in rows) {
      final graph = '${'+' * row.additions}${'-' * row.deletions}';
      final count = '${row.additions + row.deletions}'.padLeft(countWidth);
      buffer.writeln(' ${row.path.padRight(pathWidth)} | $count $graph');
    }
    buffer.write(_shortstat(entries));
    return buffer.toString();
  }

  /// Сводка `git commit`: число строк и create/delete mode.
  String _shortstat(List<GitDiffEntry> entries) {
    if (entries.isEmpty) return '';
    var insertions = 0;
    var deletions = 0;
    final modes = StringBuffer();
    for (final entry in entries) {
      for (final hunk in entry.hunks) {
        for (final line in hunk.lines) {
          switch (line.type) {
            case GitDiffLineType.addition:
              insertions++;
            case GitDiffLineType.deletion:
              deletions++;
            case GitDiffLineType.context:
              break;
          }
        }
      }
      if (entry.changeType == GitDiffChangeType.added) {
        modes.write(
          ' create mode ${entry.newMode ?? '100644'} ${entry.path}\n',
        );
      } else if (entry.changeType == GitDiffChangeType.deleted) {
        modes.write(
          ' delete mode ${entry.oldMode ?? '100644'} ${entry.path}\n',
        );
      }
    }
    final files = entries.length == 1 ? '1 file' : '${entries.length} files';
    final parts = <String>['$files changed'];
    if (insertions > 0) {
      parts.add('$insertions insertion${insertions == 1 ? '' : 's'}(+)');
    }
    if (deletions > 0) {
      parts.add('$deletions deletion${deletions == 1 ? '' : 's'}(-)');
    }
    return ' ${parts.join(', ')}\n$modes';
  }

  String _fatalText(Object error) {
    if (error is StateError) return error.message;
    if (error is FormatException) return error.message;
    if (error is ArgumentError) {
      final message = error.message;
      return message == null ? '$error' : '$message';
    }
    return '$error';
  }

  String _gitDate(GitCommitSignature signature) {
    final zoned = RegExp(r'^([+-])(\d\d)(\d\d)$')
        .firstMatch(signature.timezoneOffset);
    var seconds = signature.timestampSeconds;
    if (zoned != null) {
      final sign = zoned.group(1) == '-' ? -1 : 1;
      final shift =
          int.parse(zoned.group(2)!) * 3600 + int.parse(zoned.group(3)!) * 60;
      seconds += sign * shift;
    }
    final date = DateTime.fromMillisecondsSinceEpoch(
      seconds * 1000,
      isUtc: true,
    );
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
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    final second = date.second.toString().padLeft(2, '0');
    return '${weekdays[date.weekday - 1]} ${months[date.month - 1]} '
        '${date.day} $hour:$minute:$second ${date.year} ${signature.timezoneOffset}';
  }
}

final class _Network {
  const _Network(this.remote, this.refSpecs);

  final String remote;
  final List<GitRefSpec>? refSpecs;
}

String _piece(String text, int start, int end) =>
    String.fromCharCodes(text.codeUnits.getRange(start, end));

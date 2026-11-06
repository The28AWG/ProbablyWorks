import 'dart:convert';
import 'dart:typed_data';

import 'package:virtual_git/src/git_cli.dart';
import 'package:virtual_git/src/git_commit.dart';
import 'package:virtual_git/src/git_commit_codec.dart';
import 'package:virtual_git/src/git_diff_codec.dart';
import 'package:virtual_git/src/git_host_io.dart';
import 'package:virtual_git/src/git_index.dart';
import 'package:virtual_git/src/git_merge.dart';
import 'package:virtual_git/src/git_object_type.dart';
import 'package:virtual_git/src/git_pull.dart';
import 'package:virtual_git/src/git_refspec.dart';
import 'package:virtual_git/src/git_remote.dart';
import 'package:virtual_git/src/git_repository.dart';
import 'package:virtual_git/src/git_reset.dart';
import 'package:virtual_git/src/git_status.dart';
import 'package:virtual_host/virtual_host.dart';

/// Команда `git` в оболочке виртуального хоста.
///
/// Аргументы разбираются как у git 2.53 (`LC_ALL=C`): длинные и короткие опции,
/// `--name=value`, `--` и глобальные `-C`/`-c`. Неизвестная опция завершается
/// кодом 129. Автор берётся из окружения, затем из `-c user.*`.
/// Сетевой `--depth` не выполняется: протокол shallow в библиотеке нет,
/// локальный путь предупреждает и клонирует целиком, как сам git.
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

  Future<int> _dispatch(AppletIo io, GitGlobals global) {
    final command = global.args.first;
    final rest = global.args.sublist(1);
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
        _writeBranchHeader(io, branch, committed: committed);
      }
      _writeShortStatus(io, report, showUntracked: untracked != 'no');
      return 0;
    }
    _writeLongStatus(
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
    const usage = 'usage: git commit [<options>] [--] [<pathspec>...]';
    final parsed = parseGitArgs(args, const [
      GitOption('message', short: 'm', valued: true),
      GitOption('file', short: 'F', valued: true),
      GitOption('allow-empty'),
      GitOption('all', short: 'a'),
      GitOption('author', valued: true),
    ], usage: usage);
    final messages = [...parsed.valuesOf('message')];
    final file = parsed.value('file');
    if (file != null) {
      messages.add(utf8.decode(await io.fs.readBytes(_join(io.cwd, file))));
    }
    if (messages.isEmpty) {
      io.stderr.writeText('Aborting commit due to empty commit message.\n');
      return 1;
    }
    final repo = await _repo(io);
    if (parsed.has('all')) {
      final paths = await _trackedChanges(repo, const ['.']);
      if (paths.isNotEmpty) await repo.add(paths);
    }
    if (!parsed.has('allow-empty')) {
      final preview = await repo.status();
      if (!preview.hasStagedChanges) {
        await _status(io, const []);
        return 1;
      }
    }
    var message = messages.join('\n\n');
    if (!message.endsWith('\n')) message = '$message\n';
    final baseAuthor = _author(io, config);
    final override = _authorLine(parsed.value('author'));
    final author = override == null
        ? baseAuthor
        : GitCommitSignature(
            name: override.name,
            email: override.email,
            timestampSeconds: baseAuthor.timestampSeconds,
            timezoneOffset: baseAuthor.timezoneOffset,
          );
    final id = await repo.commit(
      author: author,
      committer: _committer(io, config),
      message: message,
      allowEmpty: parsed.has('allow-empty'),
    );
    final head = await repo.readReference('HEAD');
    final branch = _branchOf(head?.targetReferenceName) ?? 'detached HEAD';
    final stored = const GitCommitCodec().decode(
      (await repo.show(id.hex))!.bytes,
    );
    final root = stored.parents.isEmpty ? ' (root-commit)' : '';
    io.stdout.writeText(
      '[$branch$root ${_abbr(id.hex)}] ${_subject(message)}\n',
    );
    return 0;
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
    final entries = await repo.log(
      parsed.operands.isEmpty ? 'HEAD' : parsed.operands.single,
      maxCount: maxCount,
      firstParent: parsed.has('first-parent'),
    );
    for (final entry in entries) {
      if (parsed.has('oneline')) {
        io.stdout.writeText(
          '${_abbr(entry.objectId.hex)} ${_subject(entry.commit.message)}\n',
        );
        continue;
      }
      _writeCommitHeader(io, entry.objectId.hex, entry.commit);
    }
    return 0;
  }

  Future<int> _diff(AppletIo io, List<String> args) async {
    const usage = 'usage: git diff [<options>] [--] [<path>...]';
    final parsed = parseGitArgs(args, const [
      GitOption('staged'),
      GitOption('cached'),
    ], usage: usage);
    final repo = await _repo(io);
    final entries = await repo.diff(
      staged: parsed.has('staged') || parsed.has('cached'),
      pathspecs: parsed.operands.isEmpty ? null : parsed.operands,
    );
    io.stdout.writeText(_shortenDiff(const GitDiffCodec().encode(entries)));
    return 0;
  }

  Future<int> _show(AppletIo io, List<String> args) async {
    const usage = 'usage: git show [<options>] [<object>]';
    final parsed = parseGitArgs(args, const [
      GitOption('oneline'),
    ], usage: usage);
    if (parsed.operands.length > 1) throw const GitUsage('$usage\n');
    final repo = await _repo(io);
    final revision = parsed.operands.isEmpty ? 'HEAD' : parsed.operands.single;
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
        return 0;
      }
      _writeCommitHeader(io, id!.hex, commit);
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
    const usage = 'usage: git branch [<options>] [<name> [<start-point>]]';
    final parsed = parseGitArgs(args, const [
      GitOption('delete', short: 'd'),
      GitOption('force-delete', short: 'D'),
      GitOption('force', short: 'f'),
      GitOption('show-current'),
    ], usage: usage);
    final repo = await _repo(io);
    if (parsed.has('show-current')) {
      final head = await repo.readReference('HEAD');
      final branch = _branchOf(head?.targetReferenceName);
      if (branch != null) io.stdout.writeText('$branch\n');
      return 0;
    }
    if (parsed.has('delete') || parsed.has('force-delete')) {
      if (parsed.operands.isEmpty) {
        throw const GitUsage('fatal: branch name required\n', exitCode: 128);
      }
      for (final name in parsed.operands) {
        final code = await _deleteBranch(
          io,
          repo,
          name,
          force: parsed.has('force-delete'),
        );
        if (code != 0) return code;
      }
      return 0;
    }
    if (parsed.operands.isEmpty) {
      final branches = await repo.branches();
      for (final branch in branches) {
        final mark = branch.current ? '* ' : '  ';
        io.stdout.writeText('$mark${branch.name}\n');
      }
      return 0;
    }
    if (parsed.operands.length > 2) throw const GitUsage('$usage\n');
    await repo.branch(
      parsed.operands.first,
      startPoint: parsed.operands.length == 2 ? parsed.operands[1] : 'HEAD',
      force: parsed.has('force'),
      reflogActor: _committer(io, config),
    );
    return 0;
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
    await repo.reset(
      parsed.operands.isEmpty ? 'HEAD' : parsed.operands.single,
      mode: mode,
      reflogActor: _committer(io, config),
    );
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
    if (!parsed.has('quiet')) {
      io.stdout.writeText("Cloning into '$directory'...\n");
    }
    if (depth != null && _networkUrl(url)) {
      throw const GitUsage(
        'fatal: shallow clone is not supported\n',
        exitCode: 128,
      );
    }
    if (depth != null) {
      io.stderr.writeText(
        'warning: --depth is ignored in local clones; use file:// instead.\n',
      );
    }
    await GitRepository.clone(
      url,
      _join(io.cwd, directory),
      remoteName: parsed.value('origin') ?? 'origin',
      branchName: parsed.value('branch'),
      httpHeaders: _extraHeaders(io),
    );
    if (!parsed.has('quiet')) io.stdout.writeText('done.\n');
    return 0;
  }

  Future<int> _fetch(AppletIo io, List<String> args) async {
    const usage = 'usage: git fetch [<options>] [<repository> [<refspec>...]]';
    final parsed = parseGitArgs(args, const [
      GitOption('dry-run'),
      GitOption('quiet', short: 'q'),
      GitOption('depth', valued: true),
    ], usage: usage);
    if (parsed.has('depth')) {
      throw const GitUsage('fatal: --depth is not supported\n', exitCode: 128);
    }
    final network = _network(parsed, fallback: 'origin');
    final repo = await _repo(io);
    final result = await repo.fetch(
      network.remote,
      dryRun: parsed.has('dry-run'),
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

  Future<int> _deleteBranch(
    AppletIo io,
    GitRepository repo,
    String name, {
    required bool force,
  }) async {
    final reference = 'refs/heads/$name';
    final id = await repo.resolveReferenceObjectId(reference);
    if (id == null) {
      io.stderr.writeText("error: branch '$name' not found\n");
      return 1;
    }
    final current = _branchOf(
      (await repo.readReference('HEAD'))?.targetReferenceName,
    );
    if (current == name) {
      io.stderr.writeText(
        "error: cannot delete branch '$name' which you are currently on\n",
      );
      return 1;
    }
    if (!force) {
      final base = await repo.mergeBase(name, 'HEAD');
      if (base != id) {
        io.stderr.writeText(
          "error: the branch '$name' is not fully merged\n"
          "hint: If you are sure you want to delete it, run 'git branch -D $name'\n",
        );
        return 1;
      }
    }
    await repo.deleteReference(reference);
    io.stdout.writeText('Deleted branch $name (was ${_abbr(id.hex)}).\n');
    return 0;
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

  void _writeLongStatus(
    AppletIo io, {
    required String? branch,
    required bool committed,
    required GitStatus report,
    required bool showUntracked,
  }) {
    io.stdout.writeText(
      branch == null ? 'HEAD detached\n' : 'On branch $branch\n',
    );
    final staged = [
      for (final entry in report.entries)
        if (entry.isStaged) entry,
    ];
    final unstaged = [
      for (final entry in report.entries)
        if (entry.isUnstaged && !entry.isUntracked && !entry.isIgnored) entry,
    ];
    final untracked = [
      for (final entry in report.entries)
        if (showUntracked && entry.isUntracked) entry,
    ];
    if (staged.isEmpty && unstaged.isEmpty && untracked.isEmpty) {
      if (!committed) {
        io.stdout.writeText(
          '\nNo commits yet\n\n'
          'nothing to commit (create/copy files and use "git add" to track)\n',
        );
        return;
      }
      io.stdout.writeText('nothing to commit, working tree clean\n');
      return;
    }
    if (!committed) io.stdout.writeText('\nNo commits yet\n');
    final lead = committed ? '' : '\n';
    if (staged.isNotEmpty) {
      io.stdout.writeText(
        '${lead}Changes to be committed:\n'
        '  (use "git restore --staged <file>..." to unstage)\n',
      );
      for (final entry in staged) {
        io.stdout.writeText(
          '\t${_longLabel(entry.indexStatus)}${entry.path}\n',
        );
      }
    }
    if (unstaged.isNotEmpty) {
      final beforeUnstaged = staged.isEmpty ? lead : '\n';
      io.stdout.writeText(
        '${beforeUnstaged}Changes not staged for commit:\n'
        '  (use "git add <file>..." to update what will be committed)\n'
        '  (use "git restore <file>..." to discard changes in working directory)\n',
      );
      for (final entry in unstaged) {
        io.stdout.writeText(
          '\t${_longLabel(entry.workTreeStatus)}${entry.path}\n',
        );
      }
    }
    if (untracked.isNotEmpty) {
      final beforeUntracked = staged.isEmpty && unstaged.isEmpty ? lead : '\n';
      io.stdout.writeText(
        '${beforeUntracked}Untracked files:\n'
        '  (use "git add <file>..." to include in what will be committed)\n',
      );
      for (final entry in untracked) {
        io.stdout.writeText('\t${entry.path}\n');
      }
    }
    if (staged.isEmpty && untracked.isNotEmpty && unstaged.isEmpty) {
      io.stdout.writeText(
        '\nnothing added to commit but untracked files present (use "git add" to track)\n',
      );
    } else if (staged.isEmpty && unstaged.isNotEmpty) {
      io.stdout.writeText(
        '\nno changes added to commit (use "git add" and/or "git commit -a")\n',
      );
    }
  }

  void _writeShortStatus(
    AppletIo io,
    GitStatus report, {
    required bool showUntracked,
  }) {
    for (final entry in report.entries) {
      if (entry.isUntracked) {
        if (showUntracked) io.stdout.writeText('?? ${entry.path}\n');
        continue;
      }
      if (entry.isIgnored) {
        io.stdout.writeText('!! ${entry.path}\n');
        continue;
      }
      if (entry.indexStatus == GitFileStatus.unchanged &&
          entry.workTreeStatus == GitFileStatus.unchanged) {
        continue;
      }
      io.stdout.writeText(
        '${_letter(entry.indexStatus)}${_letter(entry.workTreeStatus)} ${entry.path}\n',
      );
    }
  }

  void _writeBranchHeader(
    AppletIo io,
    String? branch, {
    required bool committed,
  }) {
    if (branch == null) {
      io.stdout.writeText('## HEAD (no branch)\n');
      return;
    }
    if (!committed) {
      io.stdout.writeText('## No commits yet on $branch\n');
      return;
    }
    io.stdout.writeText('## $branch\n');
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

  ({String name, String email})? _authorLine(String? raw) {
    if (raw == null) return null;
    final open = raw.lastIndexOf('<');
    final close = raw.lastIndexOf('>');
    if (open <= 0 || close < open) {
      throw GitUsage(
        "fatal: --author '$raw' is not in the form Name <email>\n",
        exitCode: 128,
      );
    }
    return (
      name: _piece(raw, 0, open).trim(),
      email: _piece(raw, open + 1, close).trim(),
    );
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
      final parsed = _parseGitDate(rawDate);
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

  ({int seconds, String zone})? _parseGitDate(String raw) {
    final trimmed = raw.trim();
    final zoned = RegExp(r'^(\d+) ([+-]\d{4})$').firstMatch(trimmed);
    if (zoned != null) {
      return (seconds: int.parse(zoned.group(1)!), zone: zoned.group(2)!);
    }
    final unix = RegExp(r'^@?(\d+)$').firstMatch(trimmed);
    if (unix != null) {
      return (seconds: int.parse(unix.group(1)!), zone: '+0000');
    }
    return null;
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

  String _longLabel(GitFileStatus status) => switch (status) {
    GitFileStatus.added => 'new file:   ',
    GitFileStatus.modified => 'modified:   ',
    GitFileStatus.deleted => 'deleted:    ',
    GitFileStatus.conflicted => 'both modified:   ',
    GitFileStatus.unchanged ||
    GitFileStatus.untracked ||
    GitFileStatus.ignored => 'modified:   ',
  };

  String _letter(GitFileStatus status) => switch (status) {
    GitFileStatus.unchanged => ' ',
    GitFileStatus.added => 'A',
    GitFileStatus.modified => 'M',
    GitFileStatus.deleted => 'D',
    GitFileStatus.conflicted => 'U',
    GitFileStatus.untracked => '?',
    GitFileStatus.ignored => '!',
  };

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

part of '../git_applet.dart';

/// init, add, commit, branch, tag, checkout, switch, restore и reset.
extension GitAppletLocal on GitApplet {
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
}

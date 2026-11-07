part of '../git_applet.dart';

/// merge, stash, apply, remote, clone, fetch, pull и push.
extension GitAppletSync on GitApplet {
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
}

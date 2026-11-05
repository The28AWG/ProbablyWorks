import 'dart:convert';
import 'dart:typed_data';

import 'package:virtual_git/src/git_commit.dart';
import 'package:virtual_git/src/git_commit_codec.dart';
import 'package:virtual_git/src/git_diff_codec.dart';
import 'package:virtual_git/src/git_host_io.dart';
import 'package:virtual_git/src/git_object_type.dart';
import 'package:virtual_git/src/git_refspec.dart';
import 'package:virtual_git/src/git_remote.dart';
import 'package:virtual_git/src/git_repository.dart';
import 'package:virtual_git/src/git_reset.dart';
import 'package:virtual_git/src/git_status.dart';
import 'package:virtual_host/virtual_host.dart';

/// Команда `git` в оболочке виртуального хоста.
///
/// Разбирает argv как POSIX-утилита и вызывает [GitRepository]. Автор коммита
/// и дополнительный HTTP-заголовок берутся из [AppletIo.env], а не из
/// `.git/config`. Неизвестная подкоманда завершается кодом 1.
final class GitApplet implements Applet {
  const GitApplet({this.http});

  /// Транспорт сети. Без него запросы идут через [PackageGitHttp].
  final GitHttp? http;

  @override
  String get name => 'git';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    if (args.isEmpty) {
      io.stderr.writeText('git: command required\n');
      return 1;
    }
    bindGitIo(io.fs, cwd: io.cwd, environment: io.env, http: http);
    try {
      return await _dispatch(io, args);
    } on Object catch (error) {
      io.stderr.writeText('fatal: $error\n');
      return 128;
    } finally {
      clearGitIo();
    }
  }

  Future<int> _dispatch(AppletIo io, List<String> args) {
    final command = args.first;
    final rest = args.sublist(1);
    return switch (command) {
      'init' => _init(io, rest),
      'status' => _status(io, rest),
      'add' => _add(io, rest),
      'commit' => _commit(io, rest),
      'log' => _log(io, rest),
      'diff' => _diff(io, rest),
      'show' => _show(io, rest),
      'rev-parse' => _revParse(io, rest),
      'ls-files' => _lsFiles(io, rest),
      'branch' => _branch(io, rest),
      'tag' => _tag(io, rest),
      'checkout' => _checkout(io, rest),
      'switch' => _switch(io, rest),
      'restore' => _restore(io, rest),
      'reset' => _reset(io, rest),
      'merge' => _merge(io, rest),
      'stash' => _stash(io, rest),
      'apply' => _apply(io, rest),
      'remote' => _remote(io, rest),
      'clone' => _clone(io, rest),
      'fetch' => _fetch(io, rest),
      'pull' => _pull(io, rest),
      'push' => _push(io, rest),
      _ => _unknown(io, command),
    };
  }

  Future<int> _unknown(AppletIo io, String command) {
    io.stderr.writeText('git: \'$command\' is not a git command\n');
    return Future<int>.value(1);
  }

  Future<int> _init(AppletIo io, List<String> args) async {
    if (args.length > 1) return _usage(io, 'init');
    final path = args.isEmpty ? io.cwd : _absolute(io, args.single);
    await io.fs.mkdir('$path/.git/objects', recursive: true);
    await io.fs.mkdir('$path/.git/refs', recursive: true);
    await io.fs.mkdir('$path/.git/info', recursive: true);
    await io.fs.writeBytes(
      '$path/.git/HEAD',
      Uint8List.fromList(utf8.encode('ref: refs/heads/main\n')),
    );
    io.stdout.writeText('Initialized empty Git repository in $path/.git/\n');
    return 0;
  }

  Future<int> _status(AppletIo io, List<String> args) async {
    final repo = await _repo(io);
    final report = await repo.status(pathspecs: args.isEmpty ? null : args);
    final head = await repo.readReference('HEAD');
    final branch = head?.targetReferenceName?.replaceFirst('refs/heads/', '');
    io.stdout.writeText('On branch ${branch ?? 'HEAD detached'}\n');
    if (report.isClean) {
      io.stdout.writeText('nothing to commit, working tree clean\n');
      return 0;
    }
    for (final entry in report.entries) {
      if (entry.indexStatus == GitFileStatus.unchanged &&
          (entry.workTreeStatus == GitFileStatus.unchanged ||
              entry.isIgnored)) {
        continue;
      }
      io.stdout.writeText(
        '${_statusLetter(entry.indexStatus)}${_statusLetter(entry.workTreeStatus)} ${entry.path}\n',
      );
    }
    return 0;
  }

  Future<int> _add(AppletIo io, List<String> args) async {
    if (args.isEmpty) return _usage(io, 'add');
    final repo = await _repo(io);
    await repo.add(args);
    return 0;
  }

  Future<int> _commit(AppletIo io, List<String> args) async {
    String? message;
    var allowEmpty = false;
    for (var index = 0; index < args.length; index++) {
      final arg = args[index];
      if (arg == '-m' || arg == '--message') {
        message = _value(io, args, index, 'commit');
        if (message == null) return 1;
        index++;
        continue;
      }
      if (arg == '--allow-empty') {
        allowEmpty = true;
        continue;
      }
      return _usage(io, 'commit');
    }
    if (message == null) return _usage(io, 'commit');
    final repo = await _repo(io);
    final id = await repo.commit(
      author: _author(io),
      committer: _committer(io),
      message: message.endsWith('\n') ? message : '$message\n',
      allowEmpty: allowEmpty,
    );
    io.stdout.writeText('[main ${id.hex}] $message\n');
    return 0;
  }

  Future<int> _log(AppletIo io, List<String> args) async {
    var revision = 'HEAD';
    int? maxCount;
    for (var index = 0; index < args.length; index++) {
      final arg = args[index];
      if (arg == '-n' || arg == '--max-count') {
        final raw = _value(io, args, index, 'log');
        if (raw == null) return 1;
        maxCount = int.tryParse(raw);
        if (maxCount == null) return _usage(io, 'log');
        index++;
        continue;
      }
      if (arg.startsWith('-')) return _usage(io, 'log');
      revision = arg;
    }
    final repo = await _repo(io);
    final entries = await repo.log(revision, maxCount: maxCount);
    for (final entry in entries) {
      io.stdout.writeText('commit ${entry.objectId.hex}\n');
      io.stdout.writeText('Author: ${entry.commit.author.name}\n\n');
      io.stdout.writeText('    ${entry.commit.message.trim()}\n\n');
    }
    return 0;
  }

  Future<int> _diff(AppletIo io, List<String> args) async {
    var staged = false;
    final paths = <String>[];
    for (final arg in args) {
      if (arg == '--staged' || arg == '--cached') {
        staged = true;
        continue;
      }
      if (arg.startsWith('-')) return _usage(io, 'diff');
      paths.add(arg);
    }
    final repo = await _repo(io);
    final entries = await repo.diff(
      staged: staged,
      pathspecs: paths.isEmpty ? null : paths,
    );
    io.stdout.writeText(const GitDiffCodec().encode(entries));
    return 0;
  }

  Future<int> _show(AppletIo io, List<String> args) async {
    if (args.length > 1) return _usage(io, 'show');
    final repo = await _repo(io);
    final revision = args.isEmpty ? 'HEAD' : args.single;
    final object = await repo.show(revision);
    if (object == null) {
      io.stderr.writeText('fatal: ambiguous argument \'$revision\'\n');
      return 128;
    }
    if (object.type == GitObjectType.commit) {
      final commit = const GitCommitCodec().decode(object.bytes);
      io.stdout.writeText('commit ${commit.tree.hex}\n');
      io.stdout.writeText(commit.message);
      if (!commit.message.endsWith('\n')) io.stdout.writeText('\n');
      return 0;
    }
    io.stdout.writeText(utf8.decode(object.bytes, allowMalformed: true));
    if (object.bytes.isEmpty || object.bytes.last != 0x0a) {
      io.stdout.writeText('\n');
    }
    return 0;
  }

  Future<int> _revParse(AppletIo io, List<String> args) async {
    if (args.length != 1) return _usage(io, 'rev-parse');
    final repo = await _repo(io);
    final id = await repo.revParse(args.single);
    if (id == null) {
      io.stderr.writeText('fatal: ambiguous argument \'${args.single}\'\n');
      return 128;
    }
    io.stdout.writeText('${id.hex}\n');
    return 0;
  }

  Future<int> _lsFiles(AppletIo io, List<String> args) async {
    var untracked = false;
    var ignored = false;
    final paths = <String>[];
    for (final arg in args) {
      switch (arg) {
        case '-o' || '--others':
          untracked = true;
        case '-i' || '--ignored':
          ignored = true;
        case _:
          if (arg.startsWith('-')) return _usage(io, 'ls-files');
          paths.add(arg);
      }
    }
    final repo = await _repo(io);
    final entries = await repo.lsFiles(
      includeUntracked: untracked,
      includeIgnored: ignored,
      pathspecs: paths.isEmpty ? null : paths,
    );
    for (final entry in entries) {
      io.stdout.writeText('${entry.path}\n');
    }
    return 0;
  }

  Future<int> _branch(AppletIo io, List<String> args) async {
    final repo = await _repo(io);
    if (args.isEmpty) {
      final branches = await repo.branches();
      for (final branch in branches) {
        final mark = branch.current ? '* ' : '  ';
        io.stdout.writeText('$mark${branch.name}\n');
      }
      return 0;
    }
    if (args.length != 1 || args.single.startsWith('-')) {
      return _usage(io, 'branch');
    }
    final created = await repo.branch(args.single, reflogActor: _committer(io));
    io.stdout.writeText('${created.name}\n');
    return 0;
  }

  Future<int> _tag(AppletIo io, List<String> args) async {
    final repo = await _repo(io);
    if (args.isEmpty) {
      final tags = await repo.tags();
      for (final tag in tags) {
        io.stdout.writeText('${tag.name}\n');
      }
      return 0;
    }
    String? message;
    var force = false;
    String? name;
    for (var index = 0; index < args.length; index++) {
      final arg = args[index];
      if (arg == '-m' || arg == '--message') {
        message = _value(io, args, index, 'tag');
        if (message == null) return 1;
        index++;
        continue;
      }
      if (arg == '-f' || arg == '--force') {
        force = true;
        continue;
      }
      if (arg == '-a' || arg == '--annotate') continue;
      if (arg.startsWith('-') || name != null) return _usage(io, 'tag');
      name = arg;
    }
    if (name == null) return _usage(io, 'tag');
    final tag = await repo.tag(
      name,
      message: message,
      force: force,
      tagger: _author(io),
    );
    io.stdout.writeText('${tag.name}\n');
    return 0;
  }

  Future<int> _checkout(AppletIo io, List<String> args) async {
    var create = false;
    var force = false;
    String? target;
    for (final arg in args) {
      switch (arg) {
        case '-b':
          create = true;
        case '-f' || '--force':
          force = true;
        case _:
          if (arg.startsWith('-') || target != null) {
            return _usage(io, 'checkout');
          }
          target = arg;
      }
    }
    if (target == null) return _usage(io, 'checkout');
    final repo = await _repo(io);
    await repo.checkout(
      target,
      create: create,
      force: force,
      reflogActor: _committer(io),
    );
    io.stdout.writeText('Switched to branch \'$target\'\n');
    return 0;
  }

  Future<int> _switch(AppletIo io, List<String> args) {
    final rewritten = <String>[
      for (final arg in args)
        if (arg == '-c' || arg == '--create') '-b' else arg,
    ];
    return _checkout(io, rewritten);
  }

  Future<int> _restore(AppletIo io, List<String> args) async {
    var staged = false;
    var workTree = true;
    String? source;
    final paths = <String>[];
    for (var index = 0; index < args.length; index++) {
      final arg = args[index];
      if (arg == '--staged') {
        staged = true;
        continue;
      }
      if (arg == '--worktree') {
        workTree = true;
        continue;
      }
      if (arg == '--source') {
        source = _value(io, args, index, 'restore');
        if (source == null) return 1;
        index++;
        continue;
      }
      if (arg.startsWith('-')) return _usage(io, 'restore');
      paths.add(arg);
    }
    if (paths.isEmpty) return _usage(io, 'restore');
    final repo = await _repo(io);
    await repo.restore(
      paths,
      source: source,
      staged: staged,
      workTree: workTree,
    );
    return 0;
  }

  Future<int> _reset(AppletIo io, List<String> args) async {
    var mode = GitResetMode.mixed;
    String? target;
    for (final arg in args) {
      switch (arg) {
        case '--soft':
          mode = GitResetMode.soft;
        case '--mixed':
          mode = GitResetMode.mixed;
        case '--hard':
          mode = GitResetMode.hard;
        case _:
          if (arg.startsWith('-') || target != null) return _usage(io, 'reset');
          target = arg;
      }
    }
    final repo = await _repo(io);
    await repo.reset(target ?? 'HEAD', mode: mode, reflogActor: _committer(io));
    return 0;
  }

  Future<int> _merge(AppletIo io, List<String> args) async {
    final repo = await _repo(io);
    if (args.isEmpty) return _usage(io, 'merge');
    if (args.single == '--continue') {
      final result = await repo.mergeContinue(
        author: _author(io),
        committer: _committer(io),
      );
      io.stdout.writeText('${result.status.name}\n');
      return 0;
    }
    if (args.single == '--abort') {
      await repo.mergeAbort();
      io.stdout.writeText('merge aborted\n');
      return 0;
    }
    if (args.length != 1) return _usage(io, 'merge');
    final result = await repo.merge(
      args.single,
      author: _author(io),
      committer: _committer(io),
    );
    io.stdout.writeText('${result.status.name}\n');
    return result.status.name == 'conflict' ? 1 : 0;
  }

  Future<int> _stash(AppletIo io, List<String> args) async {
    final action = args.isEmpty ? 'push' : args.first;
    final repo = await _repo(io);
    switch (action) {
      case 'push' || 'save':
        final result = await repo.stash(
          author: _author(io),
          committer: _committer(io),
          includeUntracked:
              args.contains('-u') || args.contains('--include-untracked'),
        );
        io.stdout.writeText(
          result.created
              ? 'Saved working directory\n'
              : 'No local changes to save\n',
        );
        return 0;
      case 'pop':
        final result = await repo.stashPop();
        io.stdout.writeText(
          result.dropResult != null ? 'Dropped stash\n' : 'stash kept\n',
        );
        return result.applied ? 0 : 1;
      case 'apply':
        final result = await repo.stashApply();
        return result.applied ? 0 : 1;
      case 'drop':
        await repo.stashDrop();
        io.stdout.writeText('Dropped stash@{0}\n');
        return 0;
      case 'list':
        final entries = await repo.reflog(referenceName: 'refs/stash');
        for (var index = 0; index < entries.length; index++) {
          io.stdout.writeText('stash@{$index}: ${entries[index].message}\n');
        }
        return 0;
      default:
        return _usage(io, 'stash');
    }
  }

  Future<int> _apply(AppletIo io, List<String> args) async {
    var check = false;
    String? path;
    for (final arg in args) {
      if (arg == '--check') {
        check = true;
        continue;
      }
      if (arg == '-' || arg.startsWith('-')) {
        if (arg != '-') return _usage(io, 'apply');
        continue;
      }
      if (path != null) return _usage(io, 'apply');
      path = arg;
    }
    final bytes = path == null
        ? io.stdin
        : await io.fs.readBytes(_absolute(io, path));
    final repo = await _repo(io);
    await repo.applyPatch(utf8.decode(bytes), check: check);
    return 0;
  }

  Future<int> _remote(AppletIo io, List<String> args) async {
    final repo = await _repo(io);
    if (args.isEmpty) {
      for (final remote in await repo.remotes()) {
        io.stdout.writeText('${remote.name}\n');
      }
      return 0;
    }
    if (args.first == 'add' && args.length == 3) {
      await repo.setRemote(GitRemote(name: args[1], url: args[2]));
      return 0;
    }
    if ((args.first == 'remove' || args.first == 'rm') && args.length == 2) {
      final removed = await repo.deleteRemote(args[1]);
      if (!removed) {
        io.stderr.writeText('fatal: No such remote: \'${args[1]}\'\n');
        return 128;
      }
      return 0;
    }
    return _usage(io, 'remote');
  }

  Future<int> _clone(AppletIo io, List<String> args) async {
    if (args.isEmpty || args.length > 2) return _usage(io, 'clone');
    final url = args.first;
    final directory = args.length == 2 ? args[1] : _cloneDirectoryName(url);
    final path = _absolute(io, directory);
    await GitRepository.clone(url, path, httpHeaders: _extraHeaders(io));
    io.stdout.writeText('Cloning into \'$directory\'...\n');
    return 0;
  }

  Future<int> _fetch(AppletIo io, List<String> args) async {
    final parsed = _networkArgs(io, args, fallbackRemote: 'origin');
    if (parsed == null) return 1;
    final repo = await _repo(io);
    final result = await repo.fetch(
      parsed.remote,
      dryRun: parsed.dryRun,
      refSpecs: parsed.refSpecs,
      httpHeaders: _extraHeaders(io),
    );
    for (final reference in result.references) {
      io.stdout.writeText(
        '${reference.status.name} ${reference.destinationReferenceName}\n',
      );
    }
    return 0;
  }

  Future<int> _pull(AppletIo io, List<String> args) async {
    final parsed = _networkArgs(io, args, fallbackRemote: 'origin');
    if (parsed == null) return 1;
    final repo = await _repo(io);
    final result = await repo.pull(
      parsed.remote,
      dryRun: parsed.dryRun,
      author: _author(io),
      committer: _committer(io),
      httpHeaders: _extraHeaders(io),
    );
    io.stdout.writeText('${result.status.name}\n');
    return 0;
  }

  Future<int> _push(AppletIo io, List<String> args) async {
    var force = false;
    var setUpstream = false;
    final plain = <String>[];
    for (final arg in args) {
      switch (arg) {
        case '--force' || '-f':
          force = true;
        case '-u' || '--set-upstream':
          setUpstream = true;
        case '--dry-run':
          plain.add(arg);
        case _:
          plain.add(arg);
      }
    }
    final parsed = _networkArgs(io, plain, fallbackRemote: 'origin');
    if (parsed == null) return 1;
    final repo = await _repo(io);
    final result = await repo.push(
      parsed.remote,
      dryRun: parsed.dryRun,
      force: force,
      setUpstream: setUpstream,
      refSpecs: parsed.refSpecs,
      httpHeaders: _extraHeaders(io),
    );
    for (final reference in result.references) {
      io.stdout.writeText(
        '${reference.status.name} ${reference.destinationReferenceName}\n',
      );
    }
    return 0;
  }

  Future<GitRepository> _repo(AppletIo io) async {
    final repository = await GitRepository.discover(io.cwd);
    if (repository == null) {
      throw StateError('not a git repository');
    }
    return repository;
  }

  int _usage(AppletIo io, String command) {
    io.stderr.writeText('git: usage: git $command\n');
    return 1;
  }

  String? _value(AppletIo io, List<String> args, int index, String command) {
    if (index + 1 >= args.length) {
      _usage(io, command);
      return null;
    }
    return args[index + 1];
  }

  String _absolute(AppletIo io, String path) => path.startsWith('/')
      ? VfsPath.normalize(path)
      : VfsPath.normalize('${io.cwd}/$path');

  GitCommitSignature _author(AppletIo io) => _signature(
    io,
    nameKeys: const ['GIT_AUTHOR_NAME'],
    emailKeys: const ['GIT_AUTHOR_EMAIL'],
  );

  GitCommitSignature _committer(AppletIo io) => _signature(
    io,
    nameKeys: const ['GIT_COMMITTER_NAME', 'GIT_AUTHOR_NAME'],
    emailKeys: const ['GIT_COMMITTER_EMAIL', 'GIT_AUTHOR_EMAIL'],
  );

  GitCommitSignature _signature(
    AppletIo io, {
    required List<String> nameKeys,
    required List<String> emailKeys,
  }) {
    final name = _first(io.env, nameKeys) ?? io.profile.user;
    final email = _first(io.env, emailKeys) ?? '$name@${io.profile.hostname}';
    return GitCommitSignature.fromDateTime(
      name: name,
      email: email,
      timestamp: DateTime.now(),
    );
  }

  String? _first(Map<String, String> env, List<String> keys) {
    for (final key in keys) {
      final value = env[key];
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  /// Одна строка `Имя: значение`. В конфиг репозитория не пишется.
  Map<String, String> _extraHeaders(AppletIo io) {
    final line = io.env['GIT_HTTP_EXTRA_HEADER'];
    if (line == null || line.isEmpty) return const {};
    final separator = line.indexOf(':');
    if (separator <= 0) return const {};
    final name = String.fromCharCodes(line.codeUnits.sublist(0, separator))
        .trim();
    final value = String.fromCharCodes(line.codeUnits.sublist(separator + 1))
        .trim();
    if (name.isEmpty) return const {};
    return {name: value};
  }

  String _cloneDirectoryName(String url) {
    final trimmed = url.endsWith('/')
        ? String.fromCharCodes(url.codeUnits.sublist(0, url.length - 1))
        : url;
    final slash = trimmed.lastIndexOf('/');
    final name = slash < 0
        ? trimmed
        : String.fromCharCodes(trimmed.codeUnits.sublist(slash + 1));
    return name.endsWith('.git')
        ? String.fromCharCodes(name.codeUnits.sublist(0, name.length - 4))
        : name;
  }

  _NetworkArgs? _networkArgs(
    AppletIo io,
    List<String> args, {
    required String fallbackRemote,
  }) {
    var dryRun = false;
    final operands = <String>[];
    for (final arg in args) {
      if (arg == '--dry-run') {
        dryRun = true;
        continue;
      }
      if (arg.startsWith('-')) {
        _usage(io, 'network');
        return null;
      }
      operands.add(arg);
    }
    final remote = operands.isEmpty ? fallbackRemote : operands.first;
    final refSpecs = <GitRefSpec>[
      for (final spec in operands.skip(1)) GitRefSpec.parse(spec),
    ];
    return _NetworkArgs(
      remote: remote,
      dryRun: dryRun,
      refSpecs: refSpecs.isEmpty ? null : refSpecs,
    );
  }
}

final class _NetworkArgs {
  const _NetworkArgs({
    required this.remote,
    required this.dryRun,
    required this.refSpecs,
  });

  final String remote;
  final bool dryRun;
  final List<GitRefSpec>? refSpecs;
}

String _statusLetter(GitFileStatus status) => switch (status) {
  GitFileStatus.unchanged => ' ',
  GitFileStatus.added => 'A',
  GitFileStatus.modified => 'M',
  GitFileStatus.deleted => 'D',
  GitFileStatus.conflicted => 'U',
  GitFileStatus.untracked => '?',
  GitFileStatus.ignored => '!',
};

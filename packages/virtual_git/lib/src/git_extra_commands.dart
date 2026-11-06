// ignore_for_file: avoid-substring
// Причина: короткие хеши и fanout LFS режутся по фиксированной длине, как в git.
/// Команды, которых не было в первом разборе апплета.
/// Каждая опирается на публичные методы репозитория и пишет текст git.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:virtual_git/src/git_am.dart';
import 'package:virtual_git/src/git_apply.dart';
import 'package:virtual_git/src/git_apply_whitespace.dart';
import 'package:virtual_git/src/git_cli.dart';
import 'package:virtual_git/src/git_commit.dart';
import 'package:virtual_git/src/git_diff.dart';
import 'package:virtual_git/src/git_diff_codec.dart';
import 'package:virtual_git/src/git_hash_algorithm.dart';
import 'package:virtual_git/src/git_host_io.dart' show Directory, File;
import 'package:virtual_git/src/git_index.dart';
import 'package:virtual_git/src/git_log.dart';
import 'package:virtual_git/src/git_object.dart';
import 'package:virtual_git/src/git_object_id.dart';
import 'package:virtual_git/src/git_object_type.dart';
import 'package:virtual_git/src/git_path.dart' as p;
import 'package:virtual_git/src/git_reference.dart';
import 'package:virtual_git/src/git_remote.dart';
import 'package:virtual_git/src/git_repository.dart';
import 'package:virtual_git/src/git_reset.dart';
import 'package:virtual_host/virtual_host.dart';

/// Разбирает префикс `scalar` до имени подкоманды: только `-C` и `-c`.
///
/// Остальные флаги относятся к подкоманде. Возвращает [GitGlobals] с [GitGlobals.args]
/// — хвост после глобальных опций. Неизвестный `--флаг` даёт код 129 через [GitUsage].
GitGlobals parseScalarGlobals(
  List<String> args, {
  required String cwd,
  required String Function(String cwd, String path) resolve,
}) {
  var current = cwd;
  final config = <({String key, String value})>[];
  for (var index = 0; index < args.length; index++) {
    final arg = args[index];
    if (arg == '--') {
      return GitGlobals(
        cwd: current,
        bare: false,
        version: false,
        help: false,
        config: config,
        args: args.sublist(index + 1),
      );
    }
    if (!arg.startsWith('-') || arg == '-') {
      return GitGlobals(
        cwd: current,
        bare: false,
        version: false,
        help: false,
        config: config,
        args: args.sublist(index),
      );
    }
    if (arg == '-C' || arg.startsWith('-C')) {
      final inline = arg == '-C' ? null : arg.substring(2);
      final path = inline ?? args[++index];
      current = resolve(current, path);
      continue;
    }
    if (arg == '-c' || arg.startsWith('-c')) {
      final inline = arg == '-c' ? null : arg.substring(2);
      final raw = inline ?? args[++index];
      final eq = raw.indexOf('=');
      if (eq <= 0) {
        throw GitUsage('error: key does not contain a section: $raw\n');
      }
      config.add((key: raw.substring(0, eq), value: raw.substring(eq + 1)));
      continue;
    }
    if (arg.startsWith('--')) {
      throw GitUsage("error: unknown option `${arg.substring(2)}'\n");
    }
    throw GitUsage("error: unknown switch `${arg.substring(1)}'\n");
  }
  return GitGlobals(
    cwd: current,
    bare: false,
    version: false,
    help: false,
    config: config,
    args: const [],
  );
}

/// Возвращает код команды или null, если это не дополнительная команда.
Future<int?> gitExtraCommand(
  AppletIo io,
  String command,
  List<String> args,
  List<({String key, String value})> config,
) => switch (command) {
  'reflog' => _reflog(io, args),
  'check-ignore' => _checkIgnore(io, args),
  'merge-base' => _mergeBase(io, args),
  'show-ref' => _showRef(io, args),
  'worktree' => _worktree(io, args, config),
  'rm' => _rm(io, args),
  'mv' => _mv(io, args),
  'clean' => _clean(io, args),
  'cherry-pick' => _cherryPick(io, args, config),
  'revert' => _revert(io, args, config),
  'rebase' => _rebase(io, args, config),
  'ls-tree' => _lsTree(io, args),
  'cat-file' => _catFile(io, args),
  'config' => _config(io, args),
  'notes' => _notes(io, args, config),
  'replace' => _replace(io, args),
  'blame' => _blame(io, args),
  'grep' => _grep(io, args),
  'describe' => _describe(io, args),
  'bisect' => _bisect(io, args),
  'archive' => _archive(io, args),
  'bundle' => _bundle(io, args),
  'format-patch' => _formatPatch(io, args),
  'am' => _am(io, args, config),
  'fsck' => _fsck(io),
  'prune' => _prune(io),
  'gc' => _gc(io),
  'submodule' => _submodule(io, args),
  'sparse-checkout' => _sparse(io, args),
  'lfs' => _lfs(io, args),
  'rev-list' => _revList(io, args),
  'hash-object' => _hashObject(io, args),
  'update-ref' => _updateRef(io, args),
  'symbolic-ref' => _symbolicRef(io, args),
  'commit-tree' => _commitTree(io, args, config),
  'write-tree' => _writeTree(io),
  'merge-file' => _mergeFile(io, args),
  'merge-tree' => _mergeTree(io, args),
  'shortlog' => _shortlog(io, args),
  'name-rev' => _nameRev(io, args),
  'range-diff' => _rangeDiff(io, args),
  'check-attr' => _checkAttr(io, args),
  'check-mailmap' => _checkMailmap(io, args),
  'backfill' => _backfill(io, args),
  'maintenance' => _maintenance(io, args),
  'scalar' => _scalar(io, args, config),
  _ => Future<int?>.value(),
};

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

GitCommitSignature _signature(
  AppletIo io,
  List<({String key, String value})> config,
) {
  String? env(String key) {
    final value = io.env[key];
    if (value == null || value.isEmpty) return null;
    return value;
  }

  String? configured(String key) {
    for (final item in config) {
      if (item.key == key) return item.value;
    }
    return null;
  }

  final name =
      env('GIT_AUTHOR_NAME') ?? configured('user.name') ?? io.profile.user;
  final email =
      env('GIT_AUTHOR_EMAIL') ??
      configured('user.email') ??
      '$name@${io.profile.hostname}';
  final raw = env('GIT_AUTHOR_DATE') ?? env('GIT_COMMITTER_DATE');
  if (raw != null) {
    final parts = raw.split(' ');
    final seconds = int.tryParse(parts.first);
    if (seconds != null) {
      return GitCommitSignature(
        name: name,
        email: email,
        timestampSeconds: seconds,
        timezoneOffset: parts.length > 1 ? parts[1] : '+0000',
      );
    }
  }
  return GitCommitSignature.fromDateTime(
    name: name,
    email: email,
    timestamp: DateTime.now(),
  );
}

GitCommitSignature _committer(
  AppletIo io,
  List<({String key, String value})> config,
) {
  String? env(String key) {
    final value = io.env[key];
    if (value == null || value.isEmpty) return null;
    return value;
  }

  String? configured(String key) {
    for (final item in config) {
      if (item.key == key) return item.value;
    }
    return null;
  }

  final name =
      env('GIT_COMMITTER_NAME') ??
      env('GIT_AUTHOR_NAME') ??
      configured('user.name') ??
      io.profile.user;
  final email =
      env('GIT_COMMITTER_EMAIL') ??
      env('GIT_AUTHOR_EMAIL') ??
      configured('user.email') ??
      '$name@${io.profile.hostname}';
  final raw = env('GIT_COMMITTER_DATE') ?? env('GIT_AUTHOR_DATE');
  if (raw != null) {
    final parts = raw.split(' ');
    final seconds = int.tryParse(parts.first);
    if (seconds != null) {
      return GitCommitSignature(
        name: name,
        email: email,
        timestampSeconds: seconds,
        timezoneOffset: parts.length > 1 ? parts[1] : '+0000',
      );
    }
  }
  return GitCommitSignature.fromDateTime(
    name: name,
    email: email,
    timestamp: DateTime.now(),
  );
}

String _abbr(String hex) => hex.length <= 7 ? hex : hex.substring(0, 7);

String _subject(String message) {
  final line = const LineSplitter().convert(message);
  return line.isEmpty ? '' : line.first;
}

Future<int> _reflog(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(args, const [], usage: 'usage: git reflog\n');
  final repo = await _repo(io);
  final name = parsed.operands.isEmpty ? 'HEAD' : parsed.operands.first;
  final entries = await repo.reflog(referenceName: name);
  for (var index = 0; index < entries.length; index++) {
    final entry = entries[index];
    final hex = entry.newObjectId?.hex ?? '0' * 40;
    io.stdout.writeText('${_abbr(hex)} $name@{$index}: ${entry.message}\n');
  }
  return 0;
}

Future<int> _checkIgnore(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(args, const [
    GitOption('verbose', short: 'v'),
    GitOption('quiet', short: 'q'),
  ], usage: 'usage: git check-ignore [<options>] <path>...');
  if (parsed.operands.isEmpty) {
    throw const GitUsage('fatal: no path specified\n', exitCode: 128);
  }
  final repo = await _repo(io);
  final matches = await repo.checkIgnore(parsed.operands);
  if (!parsed.has('quiet')) {
    for (final match in matches) {
      if (parsed.has('verbose')) {
        io.stdout.writeText(
          '${match.source}:${match.lineNumber}:${match.pattern}\t${match.path}\n',
        );
      } else {
        io.stdout.writeText('${match.path}\n');
      }
    }
  }
  return matches.isEmpty ? 1 : 0;
}

Future<int> _mergeBase(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(args, const [
    GitOption('is-ancestor'),
  ], usage: 'usage: git merge-base <commit> <commit>');
  if (parsed.operands.length != 2) {
    throw const GitUsage('usage: git merge-base <commit> <commit>\n');
  }
  final repo = await _repo(io);
  if (parsed.has('is-ancestor')) {
    final ancestor = await repo.isAncestor(
      parsed.operands.first,
      parsed.operands[1],
    );
    return ancestor ? 0 : 1;
  }
  final base = await repo.mergeBase(parsed.operands.first, parsed.operands[1]);
  if (base == null) {
    io.stderr.writeText('fatal: no merge base\n');
    return 1;
  }
  io.stdout.writeText('${base.hex}\n');
  return 0;
}

Future<int> _showRef(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(args, const [
    GitOption('heads'),
    GitOption('tags'),
  ], usage: 'usage: git show-ref');
  final repo = await _repo(io);
  final refs = await repo.references();
  for (final ref in refs) {
    if (parsed.has('heads') && !ref.referenceName.startsWith('refs/heads/')) {
      continue;
    }
    if (parsed.has('tags') && !ref.referenceName.startsWith('refs/tags/')) {
      continue;
    }
    if (parsed.operands.isNotEmpty &&
        !parsed.operands.any(ref.referenceName.contains)) {
      continue;
    }
    io.stdout.writeText('${ref.objectId.hex} ${ref.referenceName}\n');
  }
  return 0;
}

Future<int> _worktree(
  AppletIo io,
  List<String> args,
  List<({String key, String value})> config,
) async {
  final parsed = parseGitArgs(args, const [
    GitOption('branch', short: 'b', valued: true),
  ], usage: 'usage: git worktree add|list|remove');
  final repo = await _repo(io);
  if (parsed.operands.isEmpty) {
    throw const GitUsage('usage: git worktree add|list|remove\n');
  }
  final action = parsed.operands.first;
  final tail = parsed.operands.sublist(1);
  switch (action) {
    case 'add':
      if (tail.isEmpty) {
        throw const GitUsage('usage: git worktree add <path>\n');
      }
      final path = tail.first.startsWith('/')
          ? tail.first
          : '${io.cwd}/${tail.first}';
      await repo.worktree(
        path,
        branchName: parsed.value('branch'),
        startPoint: tail.length > 1 ? tail[1] : 'HEAD',
        reflogActor: _signature(io, config),
      );
      final branch = parsed.value('branch');
      if (branch != null) {
        io.stdout.writeText("Preparing worktree (new branch '$branch')\n");
      }
      final id = await repo.revParse('HEAD');
      if (id != null) io.stdout.writeText('HEAD is now at ${_abbr(id.hex)}\n');
      return 0;
    case 'list':
      io.stdout.writeText(
        '${repo.path}  ${_abbr((await repo.revParse('HEAD'))?.hex ?? '')}\n',
      );
      final directory = Directory(repo.worktreesDirectoryPath);
      if (await directory.exists()) {
        await for (final entity in directory.list()) {
          io.stdout.writeText('${entity.path}\n');
        }
      }
      return 0;
    case 'remove':
      if (tail.length != 1) {
        throw const GitUsage('usage: git worktree remove <path>\n');
      }
      final name = tail.single;
      final directory = Directory('${repo.worktreesDirectoryPath}/$name');
      if (await directory.exists()) await directory.delete(recursive: true);
      return 0;
    default:
      throw const GitUsage('usage: git worktree add|list|remove\n');
  }
}

Future<int> _rm(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(args, const [
    GitOption('cached'),
    GitOption('recursive', short: 'r'),
  ], usage: 'usage: git rm [--cached] <path>...');
  if (parsed.operands.isEmpty) {
    throw const GitUsage('usage: git rm <path>...\n');
  }
  final repo = await _repo(io);
  final removed = await repo.removePaths(
    parsed.operands,
    cached: parsed.has('cached'),
    recursive: parsed.has('recursive'),
  );
  for (final path in removed) {
    io.stdout.writeText("rm '${parsed.has('cached') ? 'cached ' : ''}$path'\n");
  }
  return 0;
}

Future<int> _mv(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(
    args,
    const [],
    usage: 'usage: git mv <source> <destination>',
  );
  if (parsed.operands.length != 2) {
    throw const GitUsage('usage: git mv <source> <destination>\n');
  }
  final repo = await _repo(io);
  await repo.movePath(parsed.operands.first, parsed.operands[1]);
  return 0;
}

Future<int> _clean(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(args, const [
    GitOption('force', short: 'f'),
    GitOption('dry-run', short: 'n'),
    GitOption('directories', short: 'd'),
    GitOption('remove-ignored', short: 'x'),
  ], usage: 'usage: git clean');
  if (!parsed.has('force') && !parsed.has('dry-run')) {
    throw const GitUsage(
      'fatal: clean.requireForce defaults to true and neither -i, -n, nor -f given; refusing to clean\n',
      exitCode: 128,
    );
  }
  final repo = await _repo(io);
  final paths = await repo.clean(
    directories: parsed.has('directories'),
    removeIgnored: parsed.has('remove-ignored'),
    dryRun: parsed.has('dry-run'),
  );
  final verb = parsed.has('dry-run') ? 'Would remove' : 'Removing';
  for (final path in paths) {
    io.stdout.writeText('$verb $path\n');
  }
  return 0;
}

Future<int> _cherryPick(
  AppletIo io,
  List<String> args,
  List<({String key, String value})> config,
) async {
  final parsed = parseGitArgs(args, const [
    GitOption('continue'),
    GitOption('abort'),
  ], usage: 'usage: git cherry-pick <commit>');
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
    throw const GitUsage('usage: git cherry-pick <commit>\n');
  }
  final id = await repo.cherryPick(
    parsed.operands.single,
    committer: _signature(io, config),
  );
  io.stdout.writeText('[${_abbr(id.hex)}] cherry-pick\n');
  return 0;
}

Future<int> _revert(
  AppletIo io,
  List<String> args,
  List<({String key, String value})> config,
) async {
  final parsed = parseGitArgs(
    args,
    const [],
    usage: 'usage: git revert <commit>',
  );
  if (parsed.operands.length != 1) {
    throw const GitUsage('usage: git revert <commit>\n');
  }
  final repo = await _repo(io);
  final id = await repo.revert(
    parsed.operands.single,
    author: _signature(io, config),
    committer: _signature(io, config),
  );
  io.stdout.writeText('[${_abbr(id.hex)}] revert\n');
  return 0;
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
  await repo.rebase(
    parsed.operands.single,
    onto: parsed.value('onto'),
    committer: _signature(io, config),
  );
  io.stdout.writeText('Successfully rebased.\n');
  return 0;
}

Future<int> _lsTree(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(args, const [
    GitOption('recursive', short: 'r'),
    GitOption('name-only'),
  ], usage: 'usage: git ls-tree <tree>');
  if (parsed.operands.isEmpty) {
    throw const GitUsage('usage: git ls-tree <tree>\n');
  }
  final repo = await _repo(io);
  final rows = await repo.listTree(
    parsed.operands.first,
    recursive: parsed.has('recursive'),
  );
  for (final row in rows) {
    if (parsed.has('name-only')) {
      io.stdout.writeText('${row.path}\n');
      continue;
    }
    io.stdout.writeText(
      '${row.entry.mode} blob ${row.entry.objectId.hex}\t${row.path}\n',
    );
  }
  return 0;
}

Future<int> _catFile(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(args, const [
    GitOption('type', short: 't'),
    GitOption('pretty', short: 'p'),
    GitOption('size', short: 's'),
  ], usage: 'usage: git cat-file (-t | -p | -s) <object>');
  if (parsed.operands.length != 1) {
    throw const GitUsage('usage: git cat-file (-t | -p | -s) <object>\n');
  }
  final repo = await _repo(io);
  final id = await repo.revParse(parsed.operands.single);
  if (id == null) {
    io.stderr.writeText('fatal: Not a valid object name\n');
    return 128;
  }
  final object = await repo.readObject(id);
  if (object == null) {
    io.stderr.writeText('fatal: Not a valid object name\n');
    return 128;
  }
  if (parsed.has('type')) {
    io.stdout.writeText('${object.type.headerName}\n');
    return 0;
  }
  if (parsed.has('size')) {
    io.stdout.writeText('${object.size}\n');
    return 0;
  }
  io.stdout.writeText(utf8.decode(object.bytes, allowMalformed: true));
  if (object.bytes.isEmpty || object.bytes.last != 0x0a) {
    io.stdout.writeText('\n');
  }
  return 0;
}

Future<int> _config(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(args, const [
    GitOption('get'),
    GitOption('local'),
  ], usage: 'usage: git config [--get] <key> [<value>]');
  final repo = await _repo(io);
  if (parsed.operands.isEmpty) {
    throw const GitUsage('usage: git config <key>\n');
  }
  if (parsed.operands.length == 1 || parsed.has('get')) {
    final value = await repo.configGet(parsed.operands.first);
    if (value == null) return 1;
    io.stdout.writeText('$value\n');
    return 0;
  }
  await repo.configSet(parsed.operands.first, parsed.operands[1]);
  return 0;
}

Future<int> _notes(
  AppletIo io,
  List<String> args,
  List<({String key, String value})> config,
) async {
  final parsed = parseGitArgs(args, const [
    GitOption('message', short: 'm', valued: true),
  ], usage: 'usage: git notes add|show');
  final repo = await _repo(io);
  if (parsed.operands.isEmpty) {
    throw const GitUsage('usage: git notes add|show\n');
  }
  final action = parsed.operands.first;
  final revision = parsed.operands.length > 1 ? parsed.operands[1] : 'HEAD';
  final id = await repo.revParse(revision);
  if (id == null) return 128;
  switch (action) {
    case 'add':
      final message = parsed.value('message') ?? '';
      await repo.addNote(revision, message, author: _signature(io, config));
      return 0;
    case 'show':
      final note = await repo.readNote(revision);
      if (note == null) {
        io.stderr.writeText('error: no note found\n');
        return 1;
      }
      io.stdout.writeText(note.endsWith('\n') ? note : '$note\n');
      return 0;
    default:
      throw const GitUsage('usage: git notes add|show\n');
  }
}

Future<int> _replace(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(
    args,
    const [],
    usage: 'usage: git replace <object> <replacement>',
  );
  if (parsed.operands.length != 2) {
    throw const GitUsage('usage: git replace <object> <replacement>\n');
  }
  final repo = await _repo(io);
  final object = await repo.revParse(parsed.operands.first);
  final replacement = await repo.revParse(parsed.operands[1]);
  if (object == null || replacement == null) return 128;
  await repo.replaceObject(object, replacement);
  return 0;
}

Future<int> _blame(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(args, const [], usage: 'usage: git blame <file>');
  if (parsed.operands.isEmpty) {
    throw const GitUsage('usage: git blame <file>\n');
  }
  final repo = await _repo(io);
  final path = parsed.operands.last;
  final history = await repo.log('HEAD');
  final lines = const LineSplitter().convert(
    utf8.decode(
      await File(repo.resolveWorkTreePath(path)).readAsBytes(),
      allowMalformed: true,
    ),
  );
  for (var index = 0; index < lines.length; index++) {
    var owner = history.isEmpty ? null : history.last;
    for (final entry in history.reversed) {
      final blob = await repo.treeEntry(entry.objectId.hex, path);
      if (blob == null) continue;
      final object = await repo.readObject(blob.objectId);
      if (object == null) continue;
      final blobLines = const LineSplitter().convert(
        utf8.decode(object.bytes, allowMalformed: true),
      );
      if (index < blobLines.length && blobLines[index] == lines[index]) {
        owner = entry;
        break;
      }
    }
    final hex = owner == null ? '0' * 7 : _abbr(owner.objectId.hex);
    io.stdout.writeText('$hex ${index + 1}) ${lines[index]}\n');
  }
  return 0;
}

Future<int> _grep(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(
    args,
    const [],
    usage: 'usage: git grep <pattern>',
  );
  if (parsed.operands.isEmpty) {
    throw const GitUsage('usage: git grep <pattern>\n');
  }
  final repo = await _repo(io);
  final pattern = parsed.operands.first;
  final rows = await repo.listTree('HEAD', recursive: true);
  var found = false;
  for (final row in rows) {
    final object = await repo.readObject(row.entry.objectId);
    if (object == null || object.type != GitObjectType.blob) continue;
    final lines = const LineSplitter().convert(
      utf8.decode(object.bytes, allowMalformed: true),
    );
    for (var index = 0; index < lines.length; index++) {
      if (!lines[index].contains(pattern)) continue;
      found = true;
      io.stdout.writeText('${row.path}:${index + 1}:${lines[index]}\n');
    }
  }
  return found ? 0 : 1;
}

Future<int> _describe(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(args, const [
    GitOption('tags'),
  ], usage: 'usage: git describe');
  final repo = await _repo(io);
  final revision = parsed.operands.isEmpty ? 'HEAD' : parsed.operands.first;
  final history = await repo.log(revision);
  final tags = await repo.references(prefix: 'refs/tags');
  final byId = {for (final tag in tags) tag.objectId.hex: tag.name};
  for (var distance = 0; distance < history.length; distance++) {
    final name = byId[history[distance].objectId.hex];
    if (name == null) continue;
    if (distance == 0) {
      io.stdout.writeText('$name\n');
    } else {
      io.stdout.writeText(
        '$name-$distance-g${_abbr(history.first.objectId.hex)}\n',
      );
    }
    return 0;
  }
  io.stderr.writeText('fatal: no tags can describe\n');
  return 128;
}

Future<int> _bisect(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(
    args,
    const [],
    usage: 'usage: git bisect start|good|bad|reset',
  );
  final repo = await _repo(io);
  final action = parsed.operands.isEmpty ? 'start' : parsed.operands.first;
  final file = File('${repo.gitDirectoryPath}/BISECT_LOG');
  switch (action) {
    case 'start':
      await file.parent.create(recursive: true);
      await file.writeAsString('start\n');
      return 0;
    case 'good' || 'bad':
      final revision = parsed.operands.length > 1 ? parsed.operands[1] : 'HEAD';
      final id = await repo.revParse(revision);
      if (id == null) return 128;
      final previous = await file.exists() ? await file.readAsString() : '';
      await file.writeAsString('$previous$action ${id.hex}\n');
      return 0;
    case 'reset':
      if (await file.exists()) await file.delete();
      return 0;
    default:
      throw const GitUsage('usage: git bisect start|good|bad|reset\n');
  }
}

Future<int> _archive(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(args, const [
    GitOption('output', short: 'o', valued: true),
    GitOption('format', valued: true),
  ], usage: 'usage: git archive -o <file> <tree>');
  final repo = await _repo(io);
  final revision = parsed.operands.isEmpty ? 'HEAD' : parsed.operands.first;
  final rows = await repo.listTree(revision, recursive: true);
  final bytes = BytesBuilder();
  for (final row in rows) {
    final object = await repo.readObject(row.entry.objectId);
    if (object == null) continue;
    bytes.add(_ustar(row.path, object.bytes));
  }
  bytes.add(Uint8List(1024));
  final output = parsed.value('output');
  if (output == null) {
    io.stdout.write(bytes.toBytes());
  } else {
    final path = output.startsWith('/') ? output : '${io.cwd}/$output';
    await io.fs.writeBytes(path, bytes.toBytes());
  }
  return 0;
}

Uint8List _ustar(String name, List<int> content) {
  final header = Uint8List(512);
  void field(int offset, String value) {
    final encoded = ascii.encode(value);
    header.setRange(offset, offset + encoded.length, encoded);
  }

  field(0, name);
  field(100, '0000644\u0000');
  field(108, '0000000\u0000');
  field(116, '0000000\u0000');
  field(124, content.length.toRadixString(8).padLeft(11, '0'));
  field(136, '00000000000');
  field(156, '0');
  field(257, 'ustar\u0000');
  field(263, '00');
  var sum = 0;
  for (final byte in header) {
    sum += byte;
  }
  sum += 0x20 * 8;
  field(148, sum.toRadixString(8).padLeft(6, '0'));
  final padding = (512 - (content.length % 512)) % 512;
  final block = BytesBuilder()
    ..add(header)
    ..add(content)
    ..add(Uint8List(padding));
  return block.toBytes();
}

Future<int> _bundle(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(
    args,
    const [],
    usage: 'usage: git bundle create|verify|unbundle <file>',
  );
  if (parsed.operands.length < 2) {
    throw const GitUsage('usage: git bundle create|verify|unbundle <file>\n');
  }
  final repo = await _repo(io);
  final action = parsed.operands.first;
  final path = parsed.operands[1].startsWith('/')
      ? parsed.operands[1]
      : '${io.cwd}/${parsed.operands[1]}';
  switch (action) {
    case 'create':
      final id = await repo.revParse('HEAD');
      if (id == null) return 128;
      final pack = await repo.exportPack([id]);
      final header = ascii.encode(
        '# v2 git bundle\n${id.hex} refs/heads/main\n\n',
      );
      final bytes = BytesBuilder()
        ..add(header)
        ..add(pack);
      await io.fs.writeBytes(path, bytes.toBytes());
      return 0;
    case 'verify':
      final bytes = await io.fs.readBytes(path);
      final text = ascii.decode(bytes, allowInvalid: true);
      if (!text.startsWith('# v2 git bundle\n')) {
        io.stderr.writeText('fatal: not a bundle\n');
        return 128;
      }
      io.stdout.writeText('The bundle records a complete history.\n');
      return 0;
    case 'unbundle':
      final bytes = await io.fs.readBytes(path);
      final marker = ascii.encode('\n\n');
      final start = _indexOf(bytes, marker);
      if (start < 0) return 128;
      await repo.importPackBytes(bytes.sublist(start + marker.length));
      return 0;
    default:
      throw const GitUsage('usage: git bundle create|verify|unbundle <file>\n');
  }
}

int _indexOf(List<int> bytes, List<int> needle) {
  for (var index = 0; index + needle.length <= bytes.length; index++) {
    var matches = true;
    for (var offset = 0; offset < needle.length; offset++) {
      if (bytes[index + offset] != needle[offset]) {
        matches = false;
        break;
      }
    }
    if (matches) return index;
  }
  return -1;
}

Future<int> _formatPatch(AppletIo io, List<String> args) async {
  var maxCount = 1;
  final filtered = <String>[];
  for (final arg in args) {
    final digit = RegExp(r'^-(\d+)$').firstMatch(arg);
    if (digit != null) {
      maxCount = int.parse(digit.group(1)!);
      continue;
    }
    filtered.add(arg);
  }
  final parsed = parseGitArgs(filtered, const [
    GitOption('stdout'),
    GitOption('output-directory', short: 'o', valued: true),
  ], usage: 'usage: git format-patch [<options>] [<since> | <revision-range>]');
  final repo = await _repo(io);
  final revision = parsed.operands.isEmpty ? 'HEAD' : parsed.operands.first;
  if (maxCount == 0) {
    return 0;
  }
  final history = await repo.log(revision, maxCount: maxCount);
  if (history.isEmpty) return 128;
  final commits = history.reversed.toList();

  Future<String> mboxFor(GitLogEntry entry) async {
    final parent = entry.commit.parents.isEmpty
        ? null
        : entry.commit.parents.first.hex;
    final patch = parent == null
        ? ''
        : const GitDiffCodec().encode(
            await repo.diffRevisions(parent, entry.objectId.hex),
          );
    return 'From ${entry.objectId.hex} Mon Sep 17 00:00:00 2001\n'
        'From: ${entry.commit.author.name} <${entry.commit.author.email}>\n'
        'Subject: [PATCH] ${_subject(entry.commit.message)}\n\n'
        '${entry.commit.message}\n$patch';
  }

  if (parsed.has('stdout')) {
    final buffer = StringBuffer();
    for (var index = 0; index < commits.length; index++) {
      if (index > 0) {
        buffer.writeln();
      }
      buffer.write(await mboxFor(commits[index]));
    }
    io.stdout.writeText(buffer.toString());
    return 0;
  }

  final outDir = parsed.value('output-directory');
  if (outDir != null) {
    await io.fs.mkdir(
      outDir.startsWith('/') ? outDir : p.join(io.cwd, outDir),
      recursive: true,
    );
  }
  for (var index = 0; index < commits.length; index++) {
    final entry = commits[index];
    final n = index + 1;
    final stem = _subject(entry.commit.message);
    final fileName = '${n.toString().padLeft(4, '0')}-$stem.patch';
    final text = await mboxFor(entry);
    final fullPath = outDir == null
        ? p.join(io.cwd, fileName)
        : p.join(io.cwd, outDir, fileName);
    await io.fs.writeBytes(fullPath, Uint8List.fromList(utf8.encode(text)));
    final listed = outDir == null ? fileName : p.join(outDir, fileName);
    io.stdout.writeText('$listed\n');
  }
  return 0;
}

Future<int> _am(
  AppletIo io,
  List<String> args,
  List<({String key, String value})> config,
) async {
  const usage =
      'usage: git am [<options>] [(<mbox> | <Maildir>)...]\n'
      '   or: git am [<options>] (--continue | --skip | --abort)\n';
  final parsed = parseGitArgs(args, const [
    GitOption('interactive', short: 'i'),
    GitOption('no-verify', short: 'n'),
    GitOption('verify'),
    GitOption('3way', short: '3'),
    GitOption('quiet', short: 'q'),
    GitOption('signoff', short: 's'),
    GitOption('utf8', short: 'u'),
    GitOption('keep', short: 'k'),
    GitOption('keep-non-patch'),
    GitOption('message-id'),
    GitOption('keep-cr'),
    GitOption('scissors', short: 'c'),
    GitOption('quoted-cr', valued: true),
    GitOption('whitespace', valued: true),
    GitOption('ignore-space-change'),
    GitOption('ignore-whitespace'),
    GitOption('directory', valued: true),
    GitOption('exclude', valued: true),
    GitOption('include', valued: true),
    GitOption('C', short: 'C', valued: true),
    GitOption('p', short: 'p', valued: true),
    GitOption('patch-format', valued: true),
    GitOption('reject'),
    GitOption('resolvemsg', valued: true),
    GitOption('continue'),
    GitOption('resolved', short: 'r'),
    GitOption('skip'),
    GitOption('abort'),
    GitOption('quit'),
    GitOption('show-current-patch', valued: true, optional: true),
    GitOption('retry'),
    GitOption('allow-empty'),
    GitOption('committer-date-is-author-date'),
    GitOption('ignore-date'),
    GitOption('rerere-autoupdate'),
    GitOption('gpg-sign', short: 'S', valued: true, optional: true),
    GitOption('empty', valued: true),
  ], usage: usage);
  final repo = await _repo(io);

  if (parsed.has('interactive')) {
    throw GitUsage(
      'fatal: interactive mode is not supported in virtual git\n',
      exitCode: 128,
    );
  }
  if (parsed.has('gpg-sign')) {
    throw GitUsage(
      'fatal: gpg signing is not supported in virtual git\n',
      exitCode: 128,
    );
  }
  if (parsed.has('rerere-autoupdate')) {
    throw GitUsage(
      'fatal: rerere is not supported in virtual git\n',
      exitCode: 128,
    );
  }

  final patchFormat = parsed.value('patch-format');
  if (patchFormat != null && patchFormat != 'mbox') {
    throw GitUsage(
      "fatal: unsupported patch format: '$patchFormat'\n",
      exitCode: 128,
    );
  }

  final emptyMode = parsed.value('empty') ?? 'stop';
  if (emptyMode != 'stop' && emptyMode != 'drop' && emptyMode != 'keep') {
    throw GitUsage(
      "fatal: invalid mode '$emptyMode' for --empty\n",
      exitCode: 128,
    );
  }

  if (parsed.has('continue') || parsed.has('resolved')) {
    return _amContinue(io, repo, config, parsed);
  }
  if (parsed.has('skip')) {
    return _amSkip(io, repo);
  }
  if (parsed.has('abort')) {
    return _amAbort(io, repo);
  }
  if (parsed.has('quit')) {
    return _amQuit(io, repo);
  }
  if (parsed.has('retry')) {
    return _amRetry(io, repo, config, parsed);
  }
  final showPatch = parsed.value('show-current-patch');
  if (parsed.has('show-current-patch')) {
    return _amShowCurrentPatch(
      io,
      repo,
      diff: showPatch == 'diff' || showPatch == '',
    );
  }

  if (parsed.operands.isEmpty) {
    throw GitUsage('$usage\n');
  }
  if (await _amRebaseApplyExists(repo)) {
    io.stderr.writeText(
      'fatal: previous rebase directory .git/rebase-apply still exists but mbox given.\n',
    );
    return 128;
  }

  for (final operand in parsed.operands) {
    final path = operand.startsWith('/') ? operand : '${io.cwd}/$operand';
    final bytes = await io.fs.readBytes(path);
    var text = utf8.decode(bytes, allowMalformed: true);
    if (!parsed.has('keep-cr')) {
      text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    }
    final messages = splitMboxMessages(text);
    for (final message in messages) {
      final code = await _amApplyOneMailboxMessage(
        io,
        repo,
        config,
        parsed,
        message,
        emptyMode: emptyMode,
      );
      if (code != 0) return code;
    }
  }
  return 0;
}

String _amRebaseApplyDir(GitRepository repo) =>
    p.join(repo.gitDirectoryPath, 'rebase-apply');

Future<bool> _amRebaseApplyExists(GitRepository repo) async =>
    await Directory(_amRebaseApplyDir(repo)).exists();

Future<void> _amClearRebaseApply(GitRepository repo) async {
  final dir = Directory(_amRebaseApplyDir(repo));
  if (await dir.exists()) {
    await dir.delete(recursive: true);
  }
}

Future<void> _amWriteRebaseApplyFile(
  GitRepository repo,
  String name,
  String content,
) async {
  final file = File(p.join(_amRebaseApplyDir(repo), name));
  await file.parent.create(recursive: true);
  await file.writeAsString(content.endsWith('\n') ? content : '$content\n');
}

Future<String?> _amReadRebaseApplyFile(GitRepository repo, String name) async {
  final file = File(p.join(_amRebaseApplyDir(repo), name));
  if (!await file.exists()) return null;
  return file.readAsString();
}

Future<int> _amAbort(AppletIo io, GitRepository repo) async {
  if (!await _amRebaseApplyExists(repo)) {
    io.stderr.writeText('fatal: No patch am in progress\n');
    return 128;
  }
  final abortSafety = await _amReadRebaseApplyFile(repo, 'abort-safety');
  final headId =
      await repo.revParse('HEAD') ??
      (abortSafety == null ? null : GitObjectId.fromHex(abortSafety.trim()));
  if (headId != null) {
    await repo.reset(headId.hex, mode: GitResetMode.hard, reflogActor: null);
  }
  await _amClearRebaseApply(repo);
  final orig = File(repo.origHeadFilePath);
  if (await orig.exists()) await orig.delete();
  return 0;
}

Future<int> _amQuit(AppletIo io, GitRepository repo) async {
  if (!await _amRebaseApplyExists(repo)) {
    io.stderr.writeText('fatal: No patch am in progress\n');
    return 128;
  }
  await _amClearRebaseApply(repo);
  final orig = File(repo.origHeadFilePath);
  if (await orig.exists()) await orig.delete();
  return 0;
}

Future<int> _amShowCurrentPatch(
  AppletIo io,
  GitRepository repo, {
  required bool diff,
}) async {
  if (!await _amRebaseApplyExists(repo)) {
    return 128;
  }
  final patchText = await _amReadRebaseApplyFile(repo, 'patch');
  if (patchText == null) {
    return 128;
  }
  if (diff) {
    final start = patchText.indexOf('diff --git ');
    final body = start >= 0 ? patchText.substring(start) : patchText;
    io.stdout.writeText(body);
    if (!body.endsWith('\n')) io.stdout.writeText('\n');
    return 0;
  }
  io.stdout.writeText(patchText);
  if (!patchText.endsWith('\n')) io.stdout.writeText('\n');
  return 0;
}

Future<int> _amRetry(
  AppletIo io,
  GitRepository repo,
  List<({String key, String value})> config,
  GitInvocation parsed,
) async {
  if (!await _amRebaseApplyExists(repo)) {
    io.stderr.writeText('fatal: No patch am in progress\n');
    return 128;
  }
  final patchText = await _amReadRebaseApplyFile(repo, 'patch');
  if (patchText == null) {
    await _amClearRebaseApply(repo);
    io.stderr.writeText('fatal: patch state corrupted\n');
    return 128;
  }
  final message = await _amReadRebaseApplyFile(repo, '0001');
  if (message == null) {
    await _amClearRebaseApply(repo);
    io.stderr.writeText('fatal: patch state corrupted\n');
    return 128;
  }
  return _amApplyParsedMessage(
    io,
    repo,
    config,
    parsed,
    message,
    patchText,
    resumeAfterConflict: true,
  );
}

Future<int> _amSkip(AppletIo io, GitRepository repo) async {
  if (!await _amRebaseApplyExists(repo)) {
    io.stderr.writeText('fatal: No patch am in progress\n');
    return 128;
  }
  await _amClearRebaseApply(repo);
  final orig = File(repo.origHeadFilePath);
  if (await orig.exists()) await orig.delete();
  return 0;
}

Future<int> _amContinue(
  AppletIo io,
  GitRepository repo,
  List<({String key, String value})> config,
  GitInvocation parsed,
) async {
  if (!await _amRebaseApplyExists(repo)) {
    io.stderr.writeText('fatal: No patch am in progress\n');
    return 128;
  }
  final resume = await _AmResumeState.load(repo);
  if (resume == null) {
    await _amClearRebaseApply(repo);
    io.stderr.writeText('fatal: patch state corrupted\n');
    return 128;
  }
  final opts = _AmEffectiveOptions(parsed: parsed, resume: resume);
  final invalidQuotedContinue = _amValidateQuotedCr(opts.quotedCrEffective);
  if (invalidQuotedContinue != null) {
    io.stderr.writeText(invalidQuotedContinue);
    return 128;
  }
  final wsRawContinue = opts.wsPolicyRaw;
  if (wsRawContinue != null && wsRawContinue.trim().isNotEmpty) {
    if (parseWhitespacePolicy(wsRawContinue.trim()) == null) {
      io.stderr.writeText('fatal: Invalid whitespace option: $wsRawContinue\n');
      return 128;
    }
  }

  final patchText = await _amReadRebaseApplyFile(repo, 'patch');
  final message = await _amReadRebaseApplyFile(repo, '0001');
  if (patchText == null || message == null) {
    await _amClearRebaseApply(repo);
    io.stderr.writeText('fatal: patch state corrupted\n');
    return 128;
  }
  final diffStart = patchText.indexOf('diff --git ');
  final patchBody = diffStart >= 0 ? patchText.substring(diffStart) : patchText;
  if (!_amPatchHasApplicableHunks(patchBody)) {
    final subjectLine =
        await _amReadRebaseApplyFile(repo, 'final-commit') ??
        _amExtractSubjectFromMbox(message);
    io.stderr.writeText(
      'hint: When you have resolved this problem, run "git am --continue".\n',
    );
    io.stderr.writeText(
      'hint: If you prefer to skip this patch, run "git am --skip" instead.\n',
    );
    io.stderr.writeText(
      'hint: To restore the original branch and stop patching, run "git am --abort".\n',
    );
    io.stderr.writeText(
      'hint: Disable this message with "git config set advice.mergeConflict false"\n',
    );
    io.stderr.writeText('Applying: $subjectLine\n');
    io.stderr.writeText("No changes - did you forget to use 'git add'?\n");
    io.stderr.writeText(
      'If there is nothing left to stage, chances are that something else\n',
    );
    io.stderr.writeText(
      'already introduced the same changes; you might want to skip this patch.\n',
    );
    return 128;
  }
  final apply = await repo.applyPatch(
    patchBody,
    threeWay: opts.threeway,
    reject: opts.reject,
    stripPathSegments: opts.stripPathSegments,
    whitespaceMode: opts.applyWhitespaceMode,
    whitespacePolicy: opts.applyWhitespacePolicy,
    includePaths: _amPathSet(parsed, 'include'),
    excludePaths: _amPathSet(parsed, 'exclude'),
    applyContextLines: opts.applyContextLines,
    applyDirectoryPrefix: opts.applyDirectoryPrefix,
    patchFileLabel: _amPatchFileLabel(),
  );
  _amEmitApplyStderr(io, apply, quiet: opts.quiet);
  if (!apply.success) {
    if (apply.whitespaceBlocked) {
      await _amPersistRebaseApplyForFailure(
        io,
        repo,
        config,
        fullMessage: message,
        subjectLine:
            await _amReadRebaseApplyFile(repo, 'final-commit') ??
            _amExtractSubjectFromMbox(message),
        opts: opts,
      );
      _amPrintStandardAmHints(io);
      final subjectLine =
          await _amReadRebaseApplyFile(repo, 'final-commit') ??
          _amExtractSubjectFromMbox(message);
      if (!opts.quiet) {
        io.stderr.writeText('Applying: $subjectLine\n');
        io.stderr.writeText(
          "${parsed.value('resolvemsg') ?? 'Patch failed at 0001 $subjectLine'}\n",
        );
      }
      return 128;
    }
    if (apply.hasConflicts) {
      final conflictPath = apply.files
          .firstWhere((f) => f.conflict, orElse: () => apply.files.first)
          .path;
      if (!opts.quiet) {
        io.stderr.writeText('error: patch failed: $conflictPath\n');
        io.stderr.writeText('error: $conflictPath: patch does not apply\n');
      }
      _amPrintStandardAmHints(io);
      final subjectLine =
          await _amReadRebaseApplyFile(repo, 'final-commit') ??
          _amExtractSubjectFromMbox(message);
      if (!opts.quiet) {
        io.stderr.writeText('Applying: $subjectLine\n');
        io.stderr.writeText(
          "${parsed.value('resolvemsg') ?? 'Patch failed at 0001 $subjectLine'}\n",
        );
      }
      return 128;
    }
    return 128;
  }
  final paths = _amPathsFromPatch(patchBody);
  if (paths.isNotEmpty) await repo.add(paths);

  final subjectLine =
      await _amReadRebaseApplyFile(repo, 'final-commit') ??
      _amExtractSubjectFromMbox(message);
  var bodyText = _amMessageBodyAfterSubject(message, subjectLine);
  bodyText = applyScissorsToBody(bodyText, scissors: opts.scissors);
  bodyText = _stripAmDiffFooter(bodyText);
  if (opts.signoff) {
    final signer = _signature(io, config);
    bodyText = _amAppendSignoff(bodyText, signer);
  }
  final headers = parseMailHeaders(message);
  final msg = _amBuildCommitMessage(
    subjectLine: subjectLine,
    bodyText: bodyText,
    headers: headers,
    opts: opts,
  );
  final author = await _amAuthorFromScript(repo) ?? _signature(io, config);
  final committer = _amCommitterFromEffectiveOptions(
    io,
    config,
    opts,
    authorFallback: author,
  );
  await repo.commit(
    author: author,
    committer: committer,
    message: msg,
    allowEmpty: false,
  );
  if (!opts.quiet) {
    io.stdout.writeText('Applying: $subjectLine\n');
  }
  await _amClearRebaseApply(repo);
  final orig = File(repo.origHeadFilePath);
  if (await orig.exists()) await orig.delete();
  return 0;
}

Set<String>? _amPathSet(GitInvocation parsed, String name) {
  final values = parsed.valuesOf(name);
  if (values.isEmpty) return null;
  return values.toSet();
}

List<String> _amPathsFromPatch(String patchBody) {
  final paths = <String>[];
  final seen = <String>{};
  for (final match in RegExp(
    r'^diff --git a/(.+?) b/(.+?)$',
    multiLine: true,
  ).allMatches(patchBody)) {
    final path = match.group(2)!;
    if (seen.add(path)) paths.add(path);
  }
  return paths;
}

/// Каталог патча в состоянии `am` — как у git в сообщениях про пробелы.
String _amPatchFileLabel() => '.git/rebase-apply/patch';

GitApplyWhitespaceMode _amWhitespaceModeForFlags({
  required bool ignoreSpaceChange,
  required bool ignoreWhitespace,
}) {
  if (ignoreWhitespace) {
    return GitApplyWhitespaceMode.ignoreAllWhitespace;
  }
  if (ignoreSpaceChange) {
    return GitApplyWhitespaceMode.ignoreSpaceChange;
  }
  return GitApplyWhitespaceMode.exact;
}

void _amEmitApplyStderr(
  AppletIo io,
  GitApplyResult apply, {
  required bool quiet,
}) {
  if (quiet || apply.stderrLines.isEmpty) return;
  for (final line in apply.stderrLines) {
    io.stderr.writeText('$line\n');
  }
}

/// Флаги `git am`, сохранённые в `.git/rebase-apply` для `--continue` / `--retry`.
final class _AmResumeState {
  const _AmResumeState({
    required this.quiet,
    required this.signoff,
    required this.utf8,
    required this.threeway,
    required this.scissors,
    required this.keep,
    required this.messageId,
    required this.keepNonPatch,
    required this.allowEmpty,
    required this.committerDateIsAuthorDate,
    required this.ignoreDate,
    required this.ignoreSpaceChange,
    required this.ignoreWhitespace,
    required this.wsPolicyRaw,
    required this.reject,
    required this.quotedCr,
  });

  final bool quiet;
  final bool signoff;
  final bool utf8;
  final bool threeway;
  final bool scissors;
  final bool keep;
  final bool messageId;
  final bool keepNonPatch;
  final bool allowEmpty;
  final bool committerDateIsAuthorDate;
  final bool ignoreDate;
  final bool ignoreSpaceChange;
  final bool ignoreWhitespace;
  final String wsPolicyRaw;
  final bool reject;
  final String quotedCr;

  static Future<_AmResumeState?> load(GitRepository repo) async {
    final quiet = await _amReadRebaseApplyFile(repo, 'quiet');
    if (quiet == null) return null;
    Future<bool> flag(String name) async =>
        (await _amReadRebaseApplyFile(repo, name))?.trim() == 't';
    return _AmResumeState(
      quiet: quiet.trim() == 't',
      signoff: await flag('sign'),
      utf8: await flag('utf8'),
      threeway: await flag('threeway'),
      scissors: await flag('scissors'),
      keep: await flag('keep'),
      messageId: await flag('messageid'),
      keepNonPatch: await flag('keep-non-patch'),
      allowEmpty: await flag('allow-empty'),
      committerDateIsAuthorDate: await flag('cda'),
      ignoreDate: await flag('idate'),
      ignoreSpaceChange: await flag('isc'),
      ignoreWhitespace: await flag('iw'),
      wsPolicyRaw:
          (await _amReadRebaseApplyFile(repo, 'ws-policy'))?.trim() ?? 'warn',
      reject: await flag('reject'),
      quotedCr: (await _amReadRebaseApplyFile(repo, 'qc'))?.trim() ?? 'warn',
    );
  }
}

/// Эффективные опции: CLI при `am` заново, иначе значения из [resume] (как у git).
final class _AmEffectiveOptions {
  _AmEffectiveOptions({required GitInvocation parsed, _AmResumeState? resume})
    : _p = parsed,
      _r = resume;

  final GitInvocation _p;
  final _AmResumeState? _r;

  bool get quiet => _p.has('quiet') || (_r?.quiet ?? false);

  bool get signoff => _p.has('signoff') || (_r?.signoff ?? false);

  bool get utf8 => _p.has('utf8') || (_r?.utf8 ?? false);

  bool get threeway => _p.has('3way') || (_r?.threeway ?? false);

  bool get scissors => _p.has('scissors') || (_r?.scissors ?? false);

  bool get keep => _p.has('keep') || (_r?.keep ?? false);

  bool get messageId => _p.has('message-id') || (_r?.messageId ?? false);

  bool get keepNonPatch =>
      _p.has('keep-non-patch') || (_r?.keepNonPatch ?? false);

  bool get allowEmpty => _p.has('allow-empty') || (_r?.allowEmpty ?? false);

  bool get committerDateIsAuthorDate =>
      _p.has('committer-date-is-author-date') ||
      (_r?.committerDateIsAuthorDate ?? false);

  bool get ignoreDate => _p.has('ignore-date') || (_r?.ignoreDate ?? false);

  bool get ignoreSpaceChange =>
      _p.has('ignore-space-change') || (_r?.ignoreSpaceChange ?? false);

  bool get ignoreWhitespace =>
      _p.has('ignore-whitespace') || (_r?.ignoreWhitespace ?? false);

  String? get wsPolicyRaw => _p.value('whitespace') ?? _r?.wsPolicyRaw;

  bool get reject => _p.has('reject') || (_r?.reject ?? false);

  String? get quotedCr => _p.value('quoted-cr') ?? _r?.quotedCr;

  /// Эффективное значение `--quoted-cr` (git по умолчанию предупреждает).
  String get quotedCrEffective {
    final raw = quotedCr;
    if (raw == null || raw.trim().isEmpty) return 'warn';
    return raw.trim();
  }

  int get stripPathSegments => int.tryParse(_p.value('p') ?? '0') ?? 0;

  int get applyContextLines => int.tryParse(_p.value('C') ?? '3') ?? 3;

  String? get applyDirectoryPrefix => _p.value('directory');

  GitApplyWhitespaceMode get applyWhitespaceMode => _amWhitespaceModeForFlags(
    ignoreSpaceChange: ignoreSpaceChange,
    ignoreWhitespace: ignoreWhitespace,
  );

  GitApplyWhitespacePolicy get applyWhitespacePolicy {
    final raw = wsPolicyRaw;
    return parseWhitespacePolicy(raw) ?? GitApplyWhitespacePolicy.warn;
  }
}

/// Сохраняет флаги в `.git/rebase-apply` по эффективным опциям (CLI ∪ resume).
Future<void> _amWriteRebaseApplyAmFlags(
  GitRepository repo,
  _AmEffectiveOptions o,
) async {
  await _amWriteRebaseApplyFile(repo, 'quiet', o.quiet ? 't\n' : 'f\n');
  await _amWriteRebaseApplyFile(repo, 'sign', o.signoff ? 't\n' : 'f\n');
  await _amWriteRebaseApplyFile(repo, 'utf8', o.utf8 ? 't\n' : 'f\n');
  await _amWriteRebaseApplyFile(repo, 'threeway', o.threeway ? 't\n' : 'f\n');
  await _amWriteRebaseApplyFile(repo, 'scissors', o.scissors ? 't\n' : 'f\n');
  await _amWriteRebaseApplyFile(repo, 'keep', o.keep ? 't\n' : 'f\n');
  await _amWriteRebaseApplyFile(repo, 'messageid', o.messageId ? 't\n' : 'f\n');
  await _amWriteRebaseApplyFile(
    repo,
    'keep-non-patch',
    o.keepNonPatch ? 't\n' : 'f\n',
  );
  await _amWriteRebaseApplyFile(
    repo,
    'allow-empty',
    o.allowEmpty ? 't\n' : 'f\n',
  );
  await _amWriteRebaseApplyFile(
    repo,
    'cda',
    o.committerDateIsAuthorDate ? 't\n' : 'f\n',
  );
  await _amWriteRebaseApplyFile(repo, 'idate', o.ignoreDate ? 't\n' : 'f\n');
  await _amWriteRebaseApplyFile(
    repo,
    'isc',
    o.ignoreSpaceChange ? 't\n' : 'f\n',
  );
  await _amWriteRebaseApplyFile(repo, 'iw', o.ignoreWhitespace ? 't\n' : 'f\n');
  await _amWriteRebaseApplyFile(
    repo,
    'ws-policy',
    '${o.wsPolicyRaw ?? 'warn'}\n',
  );
  await _amWriteRebaseApplyFile(repo, 'reject', o.reject ? 't\n' : 'f\n');
  await _amWriteRebaseApplyFile(repo, 'qc', '${o.quotedCrEffective}\n');
}

/// Патч пригоден для `git apply`: есть блоки `@@` или нулевой размер при
/// добавлении файла (как у системного git: «пустой» новый файл без `@@` — ок).
bool _amPatchHasApplicableHunks(String patchBody) {
  if (patchBody.trim().isEmpty) return false;
  final List<GitDiffEntry> entries;
  try {
    entries = const GitDiffCodec().decode(patchBody);
  } on FormatException {
    return false;
  }
  if (entries.isEmpty) return false;
  for (final entry in entries) {
    if (entry.hunks.isNotEmpty) return true;
    if (entry.changeType == GitDiffChangeType.added) return true;
  }
  return false;
}

Future<GitCommitSignature?> _amAuthorFromScript(GitRepository repo) async {
  final script = await _amReadRebaseApplyFile(repo, 'author-script');
  if (script == null) return null;
  String? name;
  String? email;
  String? dateRaw;
  for (final line in script.split('\n')) {
    if (line.startsWith("GIT_AUTHOR_NAME='")) {
      name = line.substring("GIT_AUTHOR_NAME='".length, line.length - 1);
    } else if (line.startsWith("GIT_AUTHOR_EMAIL='")) {
      email = line.substring("GIT_AUTHOR_EMAIL='".length, line.length - 1);
    } else if (line.startsWith("GIT_AUTHOR_DATE='")) {
      dateRaw = line.substring("GIT_AUTHOR_DATE='".length, line.length - 1);
    }
  }
  if (name == null || email == null) return null;
  if (dateRaw != null) {
    final parts = dateRaw.split(' ');
    final seconds = int.tryParse(parts.first);
    if (seconds != null) {
      return GitCommitSignature(
        name: name,
        email: email,
        timestampSeconds: seconds,
        timezoneOffset: parts.length > 1 ? parts[1] : '+0000',
      );
    }
  }
  return GitCommitSignature(
    name: name,
    email: email,
    timestampSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    timezoneOffset: '+0000',
  );
}

GitCommitSignature _amCommitterFromEffectiveOptions(
  AppletIo io,
  List<({String key, String value})> config,
  _AmEffectiveOptions opts, {
  required GitCommitSignature authorFallback,
}) {
  if (opts.committerDateIsAuthorDate) {
    final base = _committer(io, config);
    return GitCommitSignature(
      name: base.name,
      email: base.email,
      timestampSeconds: authorFallback.timestampSeconds,
      timezoneOffset: authorFallback.timezoneOffset,
    );
  }
  if (opts.ignoreDate) {
    return _committer(io, config);
  }
  return _committer(io, config);
}

String _amAppendSignoff(String body, GitCommitSignature signer) {
  final trailer = 'Signed-off-by: ${signer.name} <${signer.email}>\n';
  if (body.trim().isEmpty) return trailer;
  if (!body.endsWith('\n')) return '$body\n\n$trailer';
  return '$body\n$trailer';
}

String _stripAmDiffFooter(String body) {
  const marker = '\ndiff --git ';
  final index = body.indexOf(marker);
  if (index < 0) return body;
  return body.substring(0, index).trimRight();
}

/// Префикс до тела письма (заголовки и пустая строка), как после первого `\n\n`.
String _amMailHeadersPrefix(String message) {
  final idx = message.indexOf('\n\n');
  if (idx < 0) return '';
  return message.substring(0, idx + 2);
}

String _amMessageBodyAfterSubject(String message, String subjectLine) {
  final lines = message.split('\n');
  var i = 0;
  while (i < lines.length && lines[i].trim().isNotEmpty) {
    if (lines[i].toLowerCase().startsWith('subject:')) {
      final rest = lines[i].substring(lines[i].indexOf(':') + 1).trim();
      final stripped = rest.startsWith('[PATCH]')
          ? rest.substring('[PATCH]'.length).trim()
          : rest;
      if (stripped == subjectLine) {
        i++;
        while (i < lines.length && lines[i].trim().isNotEmpty) {
          i++;
        }
        if (i < lines.length && lines[i].trim().isEmpty) i++;
        return lines.sublist(i).join('\n');
      }
    }
    i++;
  }
  final hdrEnd = message.indexOf('\n\n');
  return hdrEnd < 0 ? message : message.substring(hdrEnd + 2);
}

Future<int> _amApplyOneMailboxMessage(
  AppletIo io,
  GitRepository repo,
  List<({String key, String value})> config,
  GitInvocation parsed,
  String rawMessage, {
  required String emptyMode,
}) async {
  final opts = _AmEffectiveOptions(parsed: parsed);
  final invalidQuoted = _amValidateQuotedCr(opts.quotedCrEffective);
  if (invalidQuoted != null) {
    io.stderr.writeText(invalidQuoted);
    return 128;
  }
  final wsRaw = opts.wsPolicyRaw;
  if (wsRaw != null && wsRaw.trim().isNotEmpty) {
    if (parseWhitespacePolicy(wsRaw.trim()) == null) {
      io.stderr.writeText('fatal: Invalid whitespace option: $wsRaw\n');
      return 128;
    }
  }

  var message = rawMessage;
  if (opts.keep) {
    message = stripMboxGreaterThanBody(message);
  }
  message = normalizeMboxNewlines(message, keepCr: parsed.has('keep-cr'));
  final headers = parseMailHeaders(message);
  var body = mailBodyAfterHeaders(message);
  body = applyScissorsToBody(body, scissors: opts.scissors);

  final patchStart = body.indexOf('diff --git ');
  var preamble = patchStart < 0 ? body : body.substring(0, patchStart);
  final patchTail = patchStart < 0 ? '' : body.substring(patchStart);
  final quotedCr = applyQuotedCrToBody(
    preamble,
    action: opts.quotedCrEffective,
  );
  preamble = quotedCr.body;
  if (quotedCr.warnCount > 0 &&
      opts.quotedCrEffective == 'warn' &&
      !opts.quiet) {
    io.stderr.writeText(
      'warning: quoted-printable CRLF in body; see git-mailinfo(1)\n',
    );
  }
  body = patchTail.isEmpty ? preamble : '$preamble$patchTail';

  final patchStartAfterQuoted = body.indexOf('diff --git ');
  final patchText = patchStartAfterQuoted < 0
      ? ''
      : body.substring(patchStartAfterQuoted);

  if (patchText.isEmpty) {
    if (emptyMode == 'drop') {
      return 0;
    }
    if (emptyMode == 'keep') {
      final rawSubject = headers['subject'] ?? '';
      final subjectLine = mailinfoSubjectLine(
        rawSubject,
        keepSubject: opts.keep,
        keepNonPatchBrackets: opts.keepNonPatch,
      );
      var bodyText = preamble.trim();
      bodyText = _stripAmDiffFooter(bodyText);
      if (opts.signoff) {
        bodyText = _amAppendSignoff(bodyText, _signature(io, config));
      }
      final msg = _amBuildCommitMessage(
        subjectLine: subjectLine,
        bodyText: bodyText,
        headers: headers,
        opts: opts,
      );
      await repo.commit(
        author: _amAuthorFromMailHeaders(headers) ?? _signature(io, config),
        committer: _amCommitterFromEffectiveOptions(
          io,
          config,
          opts,
          authorFallback:
              _amAuthorFromMailHeaders(headers) ?? _signature(io, config),
        ),
        message: msg,
        allowEmpty: true,
      );
      if (!opts.quiet) {
        io.stdout.writeText('Applying: $subjectLine\n');
      }
      return 0;
    }
    io.stderr.writeText('Patch is empty.\n');
    return 128;
  }

  final prefix = _amMailHeadersPrefix(message);
  final fullMessageForAm = prefix.isEmpty ? patchText : '$prefix$body';

  return _amApplyParsedMessage(
    io,
    repo,
    config,
    parsed,
    fullMessageForAm,
    patchText,
    resumeAfterConflict: false,
  );
}

String _amExtractSubjectFromMbox(String message) =>
    _amSubjectFromHeaders(parseMailHeaders(message), message);

String _amSubjectFromHeaders(Map<String, String> headers, String message) {
  final subjectHeader = headers['subject'];
  if (subjectHeader != null) {
    var s = subjectHeader.trim();
    if (s.toLowerCase().startsWith('[patch]')) {
      s = s.substring('[patch]'.length).trim();
    }
    return s;
  }
  final match = RegExp(
    r'^Subject:\s*(?:\[PATCH\]\s*)?(.+)$',
    multiLine: true,
  ).firstMatch(message);
  return match?.group(1)?.trim() ?? 'am';
}

GitCommitSignature? _amAuthorFromMailHeaders(Map<String, String> headers) {
  final from = headers['from'];
  if (from == null) return null;
  final parsedFrom = parseFromHeader(from);
  final date = parseDateHeader(headers['date']);
  if (date != null) {
    return GitCommitSignature(
      name: parsedFrom.name,
      email: parsedFrom.email,
      timestampSeconds: date.seconds,
      timezoneOffset: date.tz,
    );
  }
  return GitCommitSignature(
    name: parsedFrom.name,
    email: parsedFrom.email,
    timestampSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    timezoneOffset: '+0000',
  );
}

String? _amValidateQuotedCr(String action) {
  switch (action) {
    case 'nowarn':
    case 'warn':
    case 'strip':
      return null;
    default:
      return 'fatal: invalid quoted-cr action: $action\n';
  }
}

void _amPrintStandardAmHints(AppletIo io) {
  io.stderr.writeText(
    "hint: Use 'git am --show-current-patch=diff' to see the failed patch\n",
  );
  io.stderr.writeText(
    'hint: When you have resolved this problem, run "git am --continue".\n',
  );
  io.stderr.writeText(
    'hint: If you prefer to skip this patch, run "git am --skip" instead.\n',
  );
  io.stderr.writeText(
    'hint: To restore the original branch and stop patching, run "git am --abort".\n',
  );
  io.stderr.writeText(
    'hint: Disable this message with "git config set advice.mergeConflict false"\n',
  );
}

String _amMailinfoSubjectFromHeaders(
  Map<String, String> headers,
  _AmEffectiveOptions opts,
) {
  final raw = headers['subject'];
  if (raw == null || raw.trim().isEmpty) return 'am';
  return mailinfoSubjectLine(
    raw,
    keepSubject: opts.keep,
    keepNonPatchBrackets: opts.keepNonPatch,
  );
}

String _amBuildCommitMessage({
  required String subjectLine,
  required String bodyText,
  required Map<String, String> headers,
  required _AmEffectiveOptions opts,
}) {
  var body = bodyText;
  if (opts.messageId) {
    final trailer = messageIdTrailer(headers);
    if (trailer != null) {
      if (body.trim().isEmpty) {
        body = trailer;
      } else {
        if (!body.endsWith('\n')) body = '$body\n';
        body = '$body\n$trailer';
      }
    }
  }
  final combined = '$subjectLine\n\n$body'.trim();
  return combined.endsWith('\n') ? combined : '$combined\n';
}

Future<void> _amPersistRebaseApplyForFailure(
  AppletIo io,
  GitRepository repo,
  List<({String key, String value})> config, {
  required String fullMessage,
  required String subjectLine,
  required _AmEffectiveOptions opts,
}) async {
  await Directory(_amRebaseApplyDir(repo)).create(recursive: true);
  final headNow = await repo.revParse('HEAD');
  if (headNow != null) {
    await _amWriteRebaseApplyFile(repo, 'abort-safety', headNow.hex);
  }
  await _amWriteRebaseApplyFile(repo, 'patch', fullMessage);
  await _amWriteRebaseApplyFile(repo, '0001', fullMessage);
  await _amWriteRebaseApplyFile(repo, 'final-commit', subjectLine);
  final author =
      _amAuthorFromMailHeaders(parseMailHeaders(fullMessage)) ??
      _signature(io, config);
  await _amWriteAuthorScript(repo, author);
  await _amWriteRebaseApplyFile(repo, 'last', '1\n');
  await _amWriteRebaseApplyFile(repo, 'next', '1\n');
  await _amWriteRebaseApplyAmFlags(repo, opts);
}

Future<int> _amApplyParsedMessage(
  AppletIo io,
  GitRepository repo,
  List<({String key, String value})> config,
  GitInvocation parsed,
  String fullMessage,
  String patchBody, {
  required bool resumeAfterConflict,
}) async {
  final resume = resumeAfterConflict ? await _AmResumeState.load(repo) : null;
  final opts = _AmEffectiveOptions(parsed: parsed, resume: resume);

  final invalidQuoted = _amValidateQuotedCr(opts.quotedCrEffective);
  if (invalidQuoted != null) {
    io.stderr.writeText(invalidQuoted);
    return 128;
  }

  final wsRaw = opts.wsPolicyRaw;
  if (wsRaw != null && wsRaw.trim().isNotEmpty) {
    if (parseWhitespacePolicy(wsRaw.trim()) == null) {
      io.stderr.writeText('fatal: Invalid whitespace option: $wsRaw\n');
      return 128;
    }
  }

  final headers = parseMailHeaders(fullMessage);
  final subjectLine = _amMailinfoSubjectFromHeaders(headers, opts);

  if (!resumeAfterConflict) {
    final head = await repo.revParse('HEAD');
    if (head != null) {
      await File(repo.origHeadFilePath).writeAsString('${head.hex}\n');
    }
  }

  final diffStart = patchBody.indexOf('diff --git ');
  final applyBody = diffStart >= 0 ? patchBody.substring(diffStart) : '';
  if (!_amPatchHasApplicableHunks(applyBody)) {
    if (!opts.quiet) {
      io.stderr.writeText(
        'error: No valid patches in input (allow with "--allow-empty")\n',
      );
      _amPrintStandardAmHints(io);
      io.stderr.writeText('Applying: $subjectLine\n');
      io.stderr.writeText(
        '${parsed.value('resolvemsg') ?? 'Patch failed at 0001 $subjectLine'}\n',
      );
    }
    await _amPersistRebaseApplyForFailure(
      io,
      repo,
      config,
      fullMessage: fullMessage,
      subjectLine: subjectLine,
      opts: opts,
    );
    return 128;
  }

  final apply = await repo.applyPatch(
    applyBody,
    threeWay: opts.threeway,
    reject: opts.reject,
    stripPathSegments: opts.stripPathSegments,
    whitespaceMode: opts.applyWhitespaceMode,
    whitespacePolicy: opts.applyWhitespacePolicy,
    includePaths: _amPathSet(parsed, 'include'),
    excludePaths: _amPathSet(parsed, 'exclude'),
    applyContextLines: opts.applyContextLines,
    applyDirectoryPrefix: opts.applyDirectoryPrefix,
    patchFileLabel: _amPatchFileLabel(),
  );
  _amEmitApplyStderr(io, apply, quiet: opts.quiet);

  if (!apply.success) {
    final resolveMsg =
        parsed.value('resolvemsg') ?? 'Patch failed at 0001 $subjectLine';
    if (!opts.quiet) {
      if (!apply.whitespaceBlocked && apply.hasConflicts) {
        final conflictPath = apply.files
            .firstWhere((f) => f.conflict, orElse: () => apply.files.first)
            .path;
        io.stderr.writeText('error: patch failed: $conflictPath\n');
        io.stderr.writeText('error: $conflictPath: patch does not apply\n');
        _amPrintStandardAmHints(io);
      }
      io.stderr.writeText('Applying: $subjectLine\n');
      io.stderr.writeText('$resolveMsg\n');
    }
    await _amPersistRebaseApplyForFailure(
      io,
      repo,
      config,
      fullMessage: fullMessage,
      subjectLine: subjectLine,
      opts: opts,
    );
    return 128;
  }

  final paths = _amPathsFromPatch(applyBody);
  if (paths.isNotEmpty) await repo.add(paths);

  var bodyText = _amMessageBodyAfterSubject(fullMessage, subjectLine);
  bodyText = applyScissorsToBody(bodyText, scissors: opts.scissors);
  bodyText = _stripAmDiffFooter(bodyText);
  if (opts.signoff) {
    bodyText = _amAppendSignoff(bodyText, _signature(io, config));
  }
  final msg = _amBuildCommitMessage(
    subjectLine: subjectLine,
    bodyText: bodyText,
    headers: headers,
    opts: opts,
  );

  final author = _amAuthorFromMailHeaders(headers) ?? _signature(io, config);
  final committer = _amCommitterFromEffectiveOptions(
    io,
    config,
    opts,
    authorFallback: author,
  );
  await repo.commit(
    author: author,
    committer: committer,
    message: msg,
    allowEmpty: opts.allowEmpty,
  );

  if (!opts.quiet) {
    io.stdout.writeText('Applying: $subjectLine\n');
  }

  await _amClearRebaseApply(repo);
  final orig = File(repo.origHeadFilePath);
  if (await orig.exists()) await orig.delete();
  return 0;
}

Future<void> _amWriteAuthorScript(
  GitRepository repo,
  GitCommitSignature author,
) async {
  final date = '${author.timestampSeconds} ${author.timezoneOffset}';
  await _amWriteRebaseApplyFile(
    repo,
    'author-script',
    "GIT_AUTHOR_NAME='${author.name}'\n"
        "GIT_AUTHOR_EMAIL='${author.email}'\n"
        "GIT_AUTHOR_DATE='$date'\n",
  );
}

Future<int> _fsck(AppletIo io) async {
  final repo = await _repo(io);
  final problems = await repo.fsck();
  for (final problem in problems) {
    io.stderr.writeText('missing $problem\n');
  }
  return problems.isEmpty ? 0 : 1;
}

Future<int> _prune(AppletIo io) async {
  final repo = await _repo(io);
  final removed = await repo.pruneUnreachable();
  io.stdout.writeText('removed $removed unreachable objects\n');
  return 0;
}

Future<int> _gc(AppletIo io) async {
  await _prune(io);
  return 0;
}

Future<int> _submodule(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(
    args,
    const [],
    usage: 'usage: git submodule add <url> <path>',
  );
  if (parsed.operands.isEmpty ||
      parsed.operands.first != 'add' ||
      parsed.operands.length != 3) {
    throw const GitUsage('usage: git submodule add <url> <path>\n');
  }
  final repo = await _repo(io);
  final url = parsed.operands[1];
  final path = parsed.operands[2];
  final destination = '${repo.path}/$path';
  final cloned = await GitRepository.clone(url, destination);
  final id = cloned.objectId;
  var index = await repo.readIndex() ?? const GitIndex();
  index = index.withEntry(
    GitIndexEntry(
      ctimeSeconds: 0,
      ctimeNanoseconds: 0,
      mtimeSeconds: 0,
      mtimeNanoseconds: 0,
      device: 0,
      inode: 0,
      mode: GitIndexEntry.gitLinkMode,
      userId: 0,
      groupId: 0,
      fileSize: 0,
      objectId: id,
      path: path,
    ),
  );
  await repo.writeIndex(index);
  final modules = File(repo.resolveWorkTreePath('.gitmodules'));
  final previous = await modules.exists() ? await modules.readAsString() : '';
  await modules.writeAsString(
    '$previous[submodule "$path"]\n\tpath = $path\n\turl = $url\n',
  );
  io.stdout.writeText('Cloning into \'$path\'...\n');
  return 0;
}

Future<int> _sparse(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(
    args,
    const [],
    usage: 'usage: git sparse-checkout init|set|list',
  );
  final repo = await _repo(io);
  final file = File('${repo.commonDirectoryPath}/info/sparse-checkout');
  final action = parsed.operands.isEmpty ? 'list' : parsed.operands.first;
  switch (action) {
    case 'init':
      await file.parent.create(recursive: true);
      if (!await file.exists()) await file.writeAsString('/*\n');
      return 0;
    case 'set':
      await file.parent.create(recursive: true);
      final body = StringBuffer();
      for (final pattern in parsed.operands.sublist(1)) {
        body.write('$pattern\n');
      }
      await file.writeAsString(body.toString());
      return 0;
    case 'list':
      if (await file.exists()) io.stdout.writeText(await file.readAsString());
      return 0;
    default:
      throw const GitUsage('usage: git sparse-checkout init|set|list\n');
  }
}

Future<int> _lfs(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(
    args,
    const [],
    usage: 'usage: git lfs track|pointer|ls-files',
  );
  final repo = await _repo(io);
  if (parsed.operands.isEmpty) {
    throw const GitUsage('usage: git lfs track|pointer\n');
  }
  switch (parsed.operands.first) {
    case 'track':
      if (parsed.operands.length != 2) {
        throw const GitUsage('usage: git lfs track <pattern>\n');
      }
      final attributes = File(repo.resolveWorkTreePath('.gitattributes'));
      final previous = await attributes.exists()
          ? await attributes.readAsString()
          : '';
      await attributes.writeAsString(
        '$previous${parsed.operands[1]} filter=lfs diff=lfs merge=lfs -text\n',
      );
      io.stdout.writeText('Tracking "${parsed.operands[1]}"\n');
      return 0;
    case 'pointer':
      final path = parsed.operands.length > 1 ? parsed.operands[1] : null;
      if (path == null) throw const GitUsage('usage: git lfs pointer <file>\n');
      final bytes = await File(repo.resolveWorkTreePath(path)).readAsBytes();
      final oid = GitObjectId.compute(
        bytes,
        algorithm: GitHashAlgorithm.sha256,
      ).hex;
      io.stdout.writeText(
        'version https://git-lfs.github.com/spec/v1\noid sha256:$oid\nsize ${bytes.length}\n',
      );
      return 0;
    case 'ls-files':
      final directory = Directory('${repo.commonDirectoryPath}/lfs/objects');
      if (!await directory.exists()) return 0;
      await for (final bucket in directory.list()) {
        if (bucket is! Directory) continue;
        await for (final object in bucket.list()) {
          io.stdout.writeText(
            '${bucket.path.split('/').last}${object.path.split('/').last}\n',
          );
        }
      }
      return 0;
    default:
      throw const GitUsage('usage: git lfs track|pointer|ls-files\n');
  }
}

Future<int> _revList(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(args, const [
    GitOption('objects'),
  ], usage: 'usage: git rev-list <commit>');
  final repo = await _repo(io);
  final revision = parsed.operands.isEmpty ? 'HEAD' : parsed.operands.first;
  final history = await repo.log(revision);
  for (final entry in history) {
    io.stdout.writeText('${entry.objectId.hex}\n');
    if (!parsed.has('objects')) continue;
    io.stdout.writeText('${entry.commit.tree.hex}\n');
    final rows = await repo.listTree(entry.objectId.hex, recursive: true);
    for (final row in rows) {
      io.stdout.writeText('${row.entry.objectId.hex} ${row.path}\n');
    }
  }
  return 0;
}

Future<int> _hashObject(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(args, const [
    GitOption('write', short: 'w'),
  ], usage: 'usage: git hash-object [-w] <file>');
  if (parsed.operands.length != 1) {
    throw const GitUsage('usage: git hash-object <file>\n');
  }
  final repo = await _repo(io);
  final path = parsed.operands.single.startsWith('/')
      ? parsed.operands.single
      : '${io.cwd}/${parsed.operands.single}';
  final bytes = await io.fs.readBytes(path);
  final object = GitObject.blob(bytes);
  final id = parsed.has('write')
      ? await repo.writeLooseObject(object)
      : object.id(algorithm: repo.hashAlgorithm);
  io.stdout.writeText('${id.hex}\n');
  return 0;
}

Future<int> _updateRef(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(args, const [
    GitOption('delete', short: 'd'),
  ], usage: 'usage: git update-ref <ref> <newvalue>');
  final repo = await _repo(io);
  if (parsed.has('delete')) {
    if (parsed.operands.length != 1) {
      throw const GitUsage('usage: git update-ref -d <ref>\n');
    }
    await repo.deleteReference(parsed.operands.single);
    return 0;
  }
  if (parsed.operands.length < 2) {
    throw const GitUsage('usage: git update-ref <ref> <newvalue>\n');
  }
  final id = await repo.revParse(parsed.operands[1]);
  if (id == null) return 128;
  await repo.writeReference(GitReference.direct(parsed.operands.first, id));
  return 0;
}

Future<int> _symbolicRef(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(
    args,
    const [],
    usage: 'usage: git symbolic-ref <name> [<ref>]',
  );
  final repo = await _repo(io);
  if (parsed.operands.isEmpty) {
    throw const GitUsage('usage: git symbolic-ref <name>\n');
  }
  if (parsed.operands.length == 1) {
    final reference = await repo.readReference(parsed.operands.single);
    final target = reference?.targetReferenceName;
    if (target == null) return 1;
    io.stdout.writeText('$target\n');
    return 0;
  }
  await repo.writeReference(
    GitReference.symbolic(parsed.operands.first, parsed.operands[1]),
  );
  return 0;
}

Future<int> _commitTree(
  AppletIo io,
  List<String> args,
  List<({String key, String value})> config,
) async {
  final parsed = parseGitArgs(args, const [
    GitOption('parent', short: 'p', valued: true),
    GitOption('message', short: 'm', valued: true),
  ], usage: 'usage: git commit-tree <tree>');
  if (parsed.operands.length != 1) {
    throw const GitUsage('usage: git commit-tree <tree>\n');
  }
  final repo = await _repo(io);
  final tree = await repo.revParse(parsed.operands.single);
  if (tree == null) return 128;
  final parents = <GitObjectId>[];
  for (final parent in parsed.valuesOf('parent')) {
    final id = await repo.revParse(parent);
    if (id != null) parents.add(id);
  }
  final id = await repo.writeCommitFromTree(
    tree,
    author: _signature(io, config),
    message: '${parsed.value('message') ?? ''}\n',
    parents: parents,
  );
  io.stdout.writeText('${id.hex}\n');
  return 0;
}

Future<int> _writeTree(AppletIo io) async {
  final repo = await _repo(io);
  final index = await repo.readIndex() ?? const GitIndex();
  final id = await repo.writeTreeFromIndex(index);
  io.stdout.writeText('${id.hex}\n');
  return 0;
}

Future<int> _mergeFile(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(
    args,
    const [],
    usage: 'usage: git merge-file <current> <base> <other>',
  );
  if (parsed.operands.length != 3) {
    throw const GitUsage('usage: git merge-file <current> <base> <other>\n');
  }
  Future<List<String>> lines(String path) async {
    final absolute = path.startsWith('/') ? path : '${io.cwd}/$path';
    return const LineSplitter().convert(
      utf8.decode(await io.fs.readBytes(absolute), allowMalformed: true),
    );
  }

  final current = await lines(parsed.operands.first);
  final base = await lines(parsed.operands[1]);
  final other = await lines(parsed.operands[2]);
  final merged = <String>[];
  final length = [
    current.length,
    base.length,
    other.length,
  ].reduce((a, b) => a > b ? a : b);
  var conflicts = 0;
  for (var index = 0; index < length; index++) {
    final left = index < current.length ? current[index] : null;
    final middle = index < base.length ? base[index] : null;
    final right = index < other.length ? other[index] : null;
    if (left == right || right == middle) {
      if (left != null) merged.add(left);
    } else if (left == middle) {
      if (right != null) merged.add(right);
    } else {
      conflicts++;
      merged.add('<<<<<<<');
      if (left != null) merged.add(left);
      merged.add('=======');
      if (right != null) merged.add(right);
      merged.add('>>>>>>>');
    }
  }
  final absolute = parsed.operands.first.startsWith('/')
      ? parsed.operands.first
      : '${io.cwd}/${parsed.operands.first}';
  await io.fs.writeBytes(
    absolute,
    Uint8List.fromList(utf8.encode('${merged.join('\n')}\n')),
  );
  return conflicts == 0 ? 0 : 1;
}

Future<int> _mergeTree(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(
    args,
    const [],
    usage: 'usage: git merge-tree <base> <branch>',
  );
  if (parsed.operands.length != 2) {
    throw const GitUsage('usage: git merge-tree <base> <branch>\n');
  }
  final repo = await _repo(io);
  final entries = await repo.diffRevisions(
    parsed.operands.first,
    parsed.operands[1],
  );
  io.stdout.writeText(const GitDiffCodec().encode(entries));
  return 0;
}

Future<int> _shortlog(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(args, const [
    GitOption('summary', short: 's'),
  ], usage: 'usage: git shortlog');
  final repo = await _repo(io);
  final history = await repo.log(
    parsed.operands.isEmpty ? 'HEAD' : parsed.operands.first,
  );
  final counts = <String, int>{};
  for (final entry in history) {
    final name = entry.commit.author.name;
    counts[name] = (counts[name] ?? 0) + 1;
  }
  final names = counts.keys.toList()..sort();
  for (final name in names) {
    io.stdout.writeText('     ${counts[name]}\t$name\n');
  }
  return 0;
}

Future<int> _nameRev(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(
    args,
    const [],
    usage: 'usage: git name-rev <commit>',
  );
  if (parsed.operands.length != 1) {
    throw const GitUsage('usage: git name-rev <commit>\n');
  }
  final repo = await _repo(io);
  final id = await repo.revParse(parsed.operands.single);
  if (id == null) return 128;
  final refs = await repo.references();
  for (final ref in refs) {
    if (ref.objectId == id) {
      io.stdout.writeText('${id.hex} ${ref.name}\n');
      return 0;
    }
  }
  io.stdout.writeText('${id.hex} undefined\n');
  return 0;
}

Future<int> _rangeDiff(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(
    args,
    const [],
    usage: 'usage: git range-diff <A> <B> <C> <D>',
  );
  if (parsed.operands.length != 2 && parsed.operands.length != 4) {
    throw const GitUsage('usage: git range-diff <range1> <range2>\n');
  }
  final repo = await _repo(io);
  final left = await repo.log(parsed.operands.first);
  final right = await repo.log(parsed.operands.last);
  final count = left.length > right.length ? left.length : right.length;
  for (var index = 0; index < count; index++) {
    final a = index < left.length ? _abbr(left[index].objectId.hex) : '-';
    final b = index < right.length ? _abbr(right[index].objectId.hex) : '-';
    io.stdout.writeText('$a -> $b\n');
  }
  return 0;
}

Future<int> _checkAttr(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(
    args,
    const [],
    usage: 'usage: git check-attr <attr> <path>',
  );
  if (parsed.operands.length < 2) {
    throw const GitUsage('usage: git check-attr <attr> <path>\n');
  }
  final repo = await _repo(io);
  final file = File(repo.resolveWorkTreePath('.gitattributes'));
  final text = await file.exists() ? await file.readAsString() : '';
  final attribute = parsed.operands.first;
  for (final path in parsed.operands.sublist(1)) {
    var value = 'unspecified';
    for (final line in const LineSplitter().convert(text)) {
      if (!line.contains(path) && !line.startsWith('*')) continue;
      final match = RegExp('$attribute(?:=(\\S+))?').firstMatch(line);
      if (match != null) value = match.group(1) ?? 'set';
    }
    io.stdout.writeText('$path: $attribute: $value\n');
  }
  return 0;
}

Future<int> _checkMailmap(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(
    args,
    const [],
    usage: 'usage: git check-mailmap <contact>',
  );
  if (parsed.operands.isEmpty) {
    throw const GitUsage('usage: git check-mailmap <contact>\n');
  }
  final repo = await _repo(io);
  final file = File(repo.resolveWorkTreePath('.mailmap'));
  final contact = parsed.operands.join(' ');
  if (!await file.exists()) {
    io.stdout.writeText('$contact\n');
    return 0;
  }
  for (final line in const LineSplitter().convert(await file.readAsString())) {
    if (line.trim().isEmpty || line.startsWith('#')) continue;
    if (contact.contains(line.split('<').last.replaceAll('>', '').trim()) ||
        line.contains(contact)) {
      io.stdout.writeText('$line\n');
      return 0;
    }
  }
  io.stdout.writeText('$contact\n');
  return 0;
}

String _joinCwd(AppletIo io, String path) => path.startsWith('/')
    ? VfsPath.normalize(path)
    : VfsPath.normalize('${io.cwd}/$path');

Map<String, String> _httpExtraHeaders(AppletIo io) {
  final line = io.env['GIT_HTTP_EXTRA_HEADER'];
  if (line == null || line.isEmpty) return const {};
  final separator = line.indexOf(':');
  if (separator <= 0) return const {};
  final name = line.substring(0, separator).trim();
  final value = line.substring(separator + 1).trim();
  if (name.isEmpty) return const {};
  return {name: value};
}

Future<int> _backfill(AppletIo io, List<String> args) async {
  final parsed = parseGitArgs(args, const [
    GitOption('min-batch-size', valued: true),
    GitOption('sparse'),
  ], usage: 'usage: git backfill');
  final batchRaw = parsed.value('min-batch-size');
  final batch = batchRaw == null ? 1 : int.tryParse(batchRaw);
  if (batchRaw != null && (batch == null || batch < 1)) {
    throw const GitUsage('fatal: invalid --min-batch-size\n', exitCode: 128);
  }
  final repo = await _repo(io);
  await repo.backfillMissingObjects(
    minBatchSize: batch ?? 1,
    restrictToSparseCheckout: parsed.has('sparse'),
    httpHeaders: _httpExtraHeaders(io),
  );
  return 0;
}

Future<int> _maintenance(AppletIo io, List<String> args) async {
  if (args.isEmpty) {
    throw const GitUsage('usage: git maintenance <subcommand>\n');
  }
  final action = args.first;
  final tail = args.sublist(1);
  await _repo(io);
  switch (action) {
    case 'run':
      parseGitArgs(tail, const [
        GitOption('auto'),
        GitOption('detach'),
        GitOption('schedule', valued: true),
        GitOption('quiet'),
        GitOption('task', valued: true),
      ], usage: 'usage: git maintenance run');
      return 0;
    case 'is-needed':
      parseGitArgs(tail, const [
        GitOption('auto'),
        GitOption('task', valued: true),
      ], usage: 'usage: git maintenance is-needed');
      return 0;
    case 'start':
      parseGitArgs(tail, const [
        GitOption('scheduler', valued: true),
      ], usage: 'usage: git maintenance start');
      return 0;
    case 'stop':
      parseGitArgs(tail, const [], usage: 'usage: git maintenance stop');
      return 0;
    case 'register':
      parseGitArgs(tail, const [
        GitOption('config-file', valued: true),
      ], usage: 'usage: git maintenance register');
      return 0;
    case 'unregister':
      parseGitArgs(tail, const [
        GitOption('config-file', valued: true),
      ], usage: 'usage: git maintenance unregister');
      return 0;
    default:
      throw const GitUsage('usage: git maintenance <subcommand>\n');
  }
}

Future<int> _scalar(
  AppletIo io,
  List<String> args,
  List<({String key, String value})> _,
) async {
  final global = parseScalarGlobals(
    args,
    cwd: io.cwd,
    resolve: (cwd, path) => path.startsWith('/')
        ? VfsPath.normalize(path)
        : VfsPath.normalize('$cwd/$path'),
  );
  final commandIo = io.copyWith(cwd: global.cwd);
  if (global.args.isEmpty) {
    io.stderr.writeText(
      'usage: scalar [-C <directory>] [-c <key>=<value>] <command> [<options>]\n',
    );
    return 129;
  }
  final sub = global.args.first;
  final rest = global.args.sublist(1);
  switch (sub) {
    case 'clone':
      final parsed = parseGitArgs(rest, const [
        GitOption('branch', valued: true),
        GitOption('full-clone'),
        GitOption('single-branch'),
        GitOption('src', valued: true),
        GitOption('tags'),
        GitOption('maintenance'),
      ], usage: 'usage: scalar clone');
      if (parsed.operands.isEmpty || parsed.operands.length > 2) {
        throw const GitUsage('usage: scalar clone <url> [<dir>]\n');
      }
      final url = parsed.operands.first;
      final rawDir = parsed.operands.length == 2
          ? parsed.operands[1]
          : _cloneDirName(url);
      final path = _joinCwd(commandIo, rawDir);
      final branch = parsed.value('branch');
      await GitRepository.clone(
        url,
        path,
        remoteName: 'origin',
        branchName: branch,
        depth: null,
        filter: parsed.has('full-clone') ? null : 'blob:none',
        httpHeaders: _httpExtraHeaders(commandIo),
      );
      if (parsed.has('maintenance')) {
        final r = await GitRepository.discover(path);
        if (r != null) await r.runMaintenanceTask('gc');
      }
      return 0;
    case 'register':
      final parsed = parseGitArgs(rest, const [
        GitOption('maintenance', valued: true, optional: true),
      ], usage: 'usage: scalar register');
      if (parsed.operands.isEmpty) {
        throw const GitUsage('usage: scalar register <path>\n');
      }
      final path = _joinCwd(commandIo, parsed.operands.first);
      await _initEmptyRepoFs(commandIo.fs, path, branch: 'main');
      final url = parsed.operands.length > 1
          ? parsed.operands[1]
          : 'http://localhost/';
      final repo = (await GitRepository.discover(path))!;
      await repo.setRemote(GitRemote(name: 'origin', url: url));
      return 0;
    case 'run':
      final parsed = parseGitArgs(rest, const [
        GitOption('all'),
        GitOption('maintenance', valued: true),
      ], usage: 'usage: scalar run');
      if (parsed.has('maintenance')) {
        final enlistment = parsed.operands.isEmpty
            ? commandIo.cwd
            : _joinCwd(commandIo, parsed.operands.first);
        final r = await GitRepository.discover(enlistment);
        if (r != null) {
          await r.runMaintenanceTask(parsed.value('maintenance') ?? 'gc');
        }
      }
      return 0;
    case 'reconfigure':
      final parsed = parseGitArgs(rest, const [
        GitOption('all', short: 'a'),
        GitOption('maintenance', valued: true, optional: true),
      ], usage: 'usage: scalar reconfigure');
      if (!parsed.has('all') && parsed.operands.isEmpty) {
        throw const GitUsage('usage: scalar reconfigure <enlistment>\n');
      }
      return 0;
    case 'list' || 'unregister' || 'delete' || 'diagnose' || 'help':
      parseGitArgs(rest, const [], usage: 'usage: scalar $sub');
      return 0;
    case 'version':
      parseGitArgs(rest, const [], usage: 'usage: scalar version');
      io.stdout.writeText('scalar 0.1.0\n');
      return 0;
    default:
      io.stderr.writeText('scalar: unknown command $sub\n');
      return 129;
  }
}

String _cloneDirName(String url) {
  var trimmed = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  final slash = trimmed.lastIndexOf('/');
  final colon = trimmed.lastIndexOf(':');
  final cut = slash > colon ? slash : colon;
  final name = cut < 0 ? trimmed : trimmed.substring(cut + 1);
  return name.endsWith('.git') ? name.substring(0, name.length - 4) : name;
}

Future<void> _initEmptyRepoFs(
  VirtualFs fs,
  String workTreePath, {
  required String branch,
}) async {
  final gitDir = '$workTreePath/.git';
  await fs.mkdir('$gitDir/objects', recursive: true);
  await fs.mkdir('$gitDir/refs', recursive: true);
  await fs.mkdir('$gitDir/info', recursive: true);
  await fs.writeBytes(
    '$gitDir/HEAD',
    Uint8List.fromList(utf8.encode('ref: refs/heads/$branch\n')),
  );
  await fs.writeBytes(
    '$gitDir/config',
    Uint8List.fromList(
      utf8.encode(
        '[core]\n'
        '\trepositoryformatversion = 0\n'
        '\tfilemode = true\n'
        '\tbare = false\n'
        '\tlogallrefupdates = true\n',
      ),
    ),
  );
}

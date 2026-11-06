// ignore_for_file: avoid-substring
// Причина: короткие хеши и fanout LFS режутся по фиксированной длине, как в git.
/// Команды, которых не было в первом разборе апплета.
/// Каждая опирается на публичные методы репозитория и пишет текст git.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:virtual_git/src/git_cli.dart';
import 'package:virtual_git/src/git_commit.dart';
import 'package:virtual_git/src/git_diff_codec.dart';
import 'package:virtual_git/src/git_hash_algorithm.dart';
import 'package:virtual_git/src/git_host_io.dart';
import 'package:virtual_git/src/git_index.dart';
import 'package:virtual_git/src/git_object.dart';
import 'package:virtual_git/src/git_object_id.dart';
import 'package:virtual_git/src/git_object_type.dart';
import 'package:virtual_git/src/git_reference.dart';
import 'package:virtual_git/src/git_repository.dart';
import 'package:virtual_host/virtual_host.dart';

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
  final parsed = parseGitArgs(args, const [
    GitOption('stdout'),
  ], usage: 'usage: git format-patch <revision>');
  final repo = await _repo(io);
  final revision = parsed.operands.isEmpty ? 'HEAD' : parsed.operands.first;
  final history = await repo.log(revision, maxCount: 1);
  if (history.isEmpty) return 128;
  final entry = history.first;
  final parent = entry.commit.parents.isEmpty
      ? null
      : entry.commit.parents.first.hex;
  final patch = parent == null
      ? ''
      : const GitDiffCodec().encode(
          await repo.diffRevisions(parent, entry.objectId.hex),
        );
  final text =
      'From ${entry.objectId.hex} Mon Sep 17 00:00:00 2001\n'
      'From: ${entry.commit.author.name} <${entry.commit.author.email}>\n'
      'Subject: [PATCH] ${_subject(entry.commit.message)}\n\n'
      '${entry.commit.message}\n$patch';
  if (parsed.has('stdout')) {
    io.stdout.writeText(text);
  } else {
    await io.fs.writeBytes(
      '${io.cwd}/0001-${_subject(entry.commit.message)}.patch',
      Uint8List.fromList(utf8.encode(text)),
    );
  }
  return 0;
}

Future<int> _am(
  AppletIo io,
  List<String> args,
  List<({String key, String value})> config,
) async {
  final parsed = parseGitArgs(args, const [], usage: 'usage: git am <mbox>');
  if (parsed.operands.length != 1) {
    throw const GitUsage('usage: git am <mbox>\n');
  }
  final repo = await _repo(io);
  final path = parsed.operands.single.startsWith('/')
      ? parsed.operands.single
      : '${io.cwd}/${parsed.operands.single}';
  final text = utf8.decode(await io.fs.readBytes(path), allowMalformed: true);
  final subject = RegExp(
    r'^Subject: \[PATCH\] (.+)$',
    multiLine: true,
  ).firstMatch(text);
  final diffStart = text.indexOf('diff --git');
  if (diffStart >= 0) {
    await repo.applyPatch(text.substring(diffStart));
    final files = RegExp(r'^diff --git a/(.+?) b/', multiLine: true);
    final paths = [for (final match in files.allMatches(text)) match.group(1)!];
    if (paths.isNotEmpty) await repo.add(paths);
  }
  final id = await repo.commit(
    author: _signature(io, config),
    committer: _signature(io, config),
    message: '${subject?.group(1) ?? 'am'}\n',
    allowEmpty: true,
  );
  io.stdout.writeText('Applying: ${subject?.group(1) ?? 'am'}\n');
  io.stdout.writeText('[${_abbr(id.hex)}] ${subject?.group(1) ?? 'am'}\n');
  return 0;
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

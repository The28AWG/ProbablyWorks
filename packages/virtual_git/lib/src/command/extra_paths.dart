// ignore_for_file: avoid-substring
// Причина: короткие хеши и fanout LFS режутся по фиксированной длине, как в git.
part of '../git_extra_commands.dart';

/// Локальные команды: reflog, ignore, worktree, rm, mv, clean.
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

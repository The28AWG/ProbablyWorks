// ignore_for_file: avoid-substring
// Причина: короткие хеши и fanout LFS режутся по фиксированной длине, как в git.
part of '../git_extra_commands.dart';

/// Обслуживание репозитория: gc, maintenance, scalar, sparse, lfs.
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

/// `git gc` без флагов: тот же проход, что и prune.
///
/// Аргументы разбираются, хотя ни один флаг справки не реализован.
/// Иначе `--quiet` и прочие опции молча завершались бы успехом, и отчёт
/// паритета считал бы их поддержанными.
Future<int> _gc(AppletIo io, List<String> args) async {
  const usage = 'usage: git gc [<options>]';
  final parsed = parseGitArgs(args, const [], usage: usage);
  if (parsed.operands.isNotEmpty) {
    throw const GitUsage('$usage\n');
  }
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

Future<int> _rangeDiff(AppletIo io, List<String> args) =>
    runRangeDiff(io, args);

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

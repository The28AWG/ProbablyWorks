// ignore_for_file: avoid-substring
// Причина: короткие хеши и fanout LFS режутся по фиксированной длине, как в git.
part of '../git_extra_commands.dart';

/// Чтение объектов и служебные команды: ls-tree, cat-file, bundle.
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

Future<int> _grep(AppletIo io, List<String> args) => gitGrep(io, args);

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

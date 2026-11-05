import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:virtual_host/src/shell/applets/applet.dart';
import 'package:virtual_host/src/shell/applets/applet_args.dart';
import 'package:virtual_host/src/shell/shell_io.dart';
import 'package:virtual_host/src/vfs_path.dart';
import 'package:virtual_host/src/vfs_store.dart';
import 'package:virtual_host/src/virtual_fs.dart';

/// Сжатие и архивы: `gzip` и `tar`. Кодеки берутся из пакета `archive` (чистый Dart, проверен через
/// Sonatype). Архив живёт в виртуальной ФС, поэтому пути архива и файлов разрешаются в ней же.
final List<Applet> archiveApplets = [const _Gzip(), const _Tar()];

/// Сжимает или распаковывает байты. Null — данные не в формате gzip.
Uint8List? _convert(Uint8List bytes, {required bool decompress}) {
  try {
    return decompress
        ? const GZipDecoder().decodeBytes(bytes)
        : const GZipEncoder().encodeBytes(bytes);
  } on Exception {
    return null;
  }
}

/// `gzip [-cdk] [FILE...]`: файл заменяется на `FILE.gz`, если не задано `-k` или `-c`. Без операндов
/// сжимается stdin в stdout. `-d` распаковывает `FILE.gz` в `FILE`. Существующий целевой файл не
/// перезаписывается, как у GNU без подтверждения.
final class _Gzip implements Applet {
  const _Gzip();

  @override
  String get name => 'gzip';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, flags: 'cdk');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    final decompress = parsed.has('d');
    final toStdout = parsed.has('c');
    final keep = parsed.has('k') || toStdout;

    if (parsed.operands.isEmpty) {
      final out = _convert(io.stdin, decompress: decompress);
      if (out == null) {
        io.stderr.writeText('$name: stdin: not in gzip format\n');
        return 1;
      }
      io.stdout.write(out);
      return 0;
    }

    var status = 0;
    for (final operand in parsed.operands) {
      final bytes = await readSource(io, name, operand);
      if (bytes == null) {
        status = 1;
        continue;
      }
      if (decompress && !operand.endsWith('.gz')) {
        io.stderr.writeText('$name: $operand: unknown suffix -- ignored\n');
        status = 2;
        continue;
      }
      final target = decompress
          ? sliceText(operand, 0, operand.length - 3)
          : '$operand.gz';
      final out = _convert(bytes, decompress: decompress);
      if (out == null) {
        io.stderr.writeText('$name: $operand: not in gzip format\n');
        status = 1;
        continue;
      }
      if (toStdout) {
        io.stdout.write(out);
        continue;
      }
      if (await io.fs.stat(target, cwd: io.cwd) != null) {
        io.stderr.writeText('$name: $target already exists; not overwritten\n');
        status = 1;
        continue;
      }
      try {
        await io.fs.writeBytes(target, out, cwd: io.cwd);
        if (!keep) await io.fs.remove(operand, cwd: io.cwd);
      } on VfsException catch (error) {
        io.stderr.writeText('$name: $operand: ${error.message}\n');
        status = 1;
      }
    }
    return status;
  }
}

/// `tar -c|-x|-t [-z] [-v] -f ARCHIVE [-C DIR] [FILE...]`. Создание добавляет каталоги рекурсивно,
/// символические ссылки сохраняются как ссылки. Распаковка создаёт недостающие каталоги и не перезаписывает
/// ссылки. `-f -` читает или пишет stdout/stdin. Права файлов сохраняются. Вывод `-v` — имена в stdout.
final class _Tar implements Applet {
  const _Tar();

  @override
  String get name => 'tar';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, flags: 'cxtzv', valued: 'fC');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    final modes = ['c', 'x', 't'].where(parsed.has).toList();
    if (modes.length != 1) {
      return usageError(io, name, "You must specify one of the '-cxt' options");
    }
    final archivePath = parsed.value('f');
    if (archivePath == null) {
      io.stderr.writeText('tar: no archive specified: use -f ARCHIVE\n');
      return 2;
    }
    final base = VfsPath.normalize(parsed.value('C') ?? io.cwd, cwd: io.cwd);
    final gzipped = parsed.has('z');
    final verbose = parsed.has('v');

    if (modes.single == 'c') {
      return _create(io, parsed.operands, archivePath, base, gzipped, verbose);
    }
    final raw = archivePath == '-'
        ? io.stdin
        : await _readArchive(io, archivePath);
    if (raw == null) return 2;
    final Archive archive;
    try {
      final tar = gzipped ? const GZipDecoder().decodeBytes(raw) : raw;
      archive = TarDecoder().decodeBytes(tar);
    } on Exception {
      io.stderr.writeText('tar: This does not look like a tar archive\n');
      return 2;
    }
    if (modes.single == 't') {
      for (final file in archive.files) {
        io.stdout.writeText('${file.name}\n');
      }
      return 0;
    }
    return _extract(io, archive, base, verbose);
  }

  Future<Uint8List?> _readArchive(AppletIo io, String path) async {
    try {
      return await io.fs.readBytes(path, cwd: io.cwd);
    } on VfsException catch (error) {
      io.stderr.writeText('tar: $path: ${error.message}\n');
      return null;
    }
  }

  Future<int> _create(
    AppletIo io,
    List<String> operands,
    String archivePath,
    String base,
    bool gzipped,
    bool verbose,
  ) async {
    if (operands.isEmpty) {
      io.stderr.writeText(
        'tar: Cowardly refusing to create an empty archive\n',
      );
      return 2;
    }
    final archive = Archive();
    var status = 0;
    for (final operand in operands) {
      final node = await io.fs.stat(operand, cwd: base, followLast: false);
      if (node == null) {
        io.stderr.writeText(
          'tar: $operand: Cannot stat: No such file or directory\n',
        );
        status = 2;
        continue;
      }
      try {
        await _add(io, archive, node, trimSlashes(operand), verbose);
      } on VfsException catch (error) {
        io.stderr.writeText('tar: $operand: ${error.message}\n');
        status = 2;
      }
    }
    final tar = Uint8List.fromList(TarEncoder().encodeBytes(archive));
    final data = gzipped ? const GZipEncoder().encodeBytes(tar) : tar;
    if (archivePath == '-') {
      io.stdout.write(data);
      return status;
    }
    try {
      await io.fs.writeBytes(archivePath, data, cwd: io.cwd);
    } on VfsException catch (error) {
      io.stderr.writeText('tar: $archivePath: ${error.message}\n');
      return 2;
    }
    return status;
  }

  /// Добавляет узел под именем [entry] и, для каталога, рекурсивно его содержимое. Имена каталогов
  /// заканчиваются `/`, как в tar.
  Future<void> _add(
    AppletIo io,
    Archive archive,
    VfsNode node,
    String entry,
    bool verbose,
  ) async {
    if (verbose) io.stdout.writeText('$entry\n');
    switch (node.kind) {
      case VfsNodeKind.file:
        final bytes = await io.fs.readBytes(node.path);
        archive.addFile(ArchiveFile.bytes(entry, bytes)..mode = node.mode);
      case VfsNodeKind.symlink:
        archive.addFile(ArchiveFile.symlink(entry, node.target ?? ''));
      case VfsNodeKind.dir:
        archive.addFile(ArchiveFile.directory('$entry/')..mode = node.mode);
        for (final child in await io.fs.list(node.path)) {
          await _add(
            io,
            archive,
            child,
            '$entry/${VfsPath.name(child.path)}',
            verbose,
          );
        }
    }
  }

  Future<int> _extract(
    AppletIo io,
    Archive archive,
    String base,
    bool verbose,
  ) async {
    var status = 0;
    for (final file in archive.files) {
      final target = VfsPath.normalize(file.name, cwd: base);
      try {
        await io.fs.mkdir(VfsPath.parent(target), recursive: true);
        if (file.isDirectory) {
          await io.fs.mkdir(target, recursive: true);
        } else if (file.isSymbolicLink) {
          await io.fs.symlink(file.symbolicLink ?? '', target);
        } else {
          await io.fs.writeBytes(target, file.content, mode: file.mode & 0x1ff);
        }
        if (verbose) io.stdout.writeText('${file.name}\n');
      } on VfsException catch (error) {
        io.stderr.writeText('tar: ${file.name}: ${error.message}\n');
        status = 2;
      }
    }
    return status;
  }
}

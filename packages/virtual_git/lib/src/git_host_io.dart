import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:virtual_git/src/git_http.dart';
import 'package:virtual_host/virtual_host.dart';

export 'package:virtual_git/src/git_http.dart'
    show GitHttp, GitHttpResponse, HttpStatus, PackageGitHttp, gitHttpBodyText;

/// Привязка скопированного git к виртуальной ФС.
///
/// Референс вызывает `File(path)` и `Directory.current` без объекта ФС.
/// Пока идёт команда или тест, путь читается отсюда, а не с диска машины.

// Состояние вызова: скопированный git пишет File(path) без ссылки на ФС.
VirtualFs? _gitFs;
String _gitCwd = '/';
GitHttp? _gitHttp;
Map<String, String> _gitEnv = const {};
int _gitTempSerial = 0;

/// ФС текущей команды. Нет привязки — ошибка, а не тихий уход на диск.
VirtualFs get gitFs {
  final bound = _gitFs;
  if (bound == null) {
    throw StateError('Git is not bound to a virtual filesystem.');
  }
  return bound;
}

/// Текущий каталог для относительных путей и `Directory.current`.
String get gitIoCwd => _gitCwd;

/// Транспорт HTTP. В приложении это [PackageGitHttp], в тестах — подмена.
GitHttp? get gitHttp => _gitHttp;

/// Включает ФС и, если задан, транспорт на время последующих вызовов git.
void bindGitIo(
  VirtualFs fs, {
  String cwd = '/',
  GitHttp? http,
  Map<String, String> environment = const {},
}) {
  _gitFs = fs;
  _gitCwd = '/';
  _gitCwd = _absolute(cwd);
  _gitHttp = http;
  _gitEnv = environment;
  _gitTempSerial = 0;
}

/// Подменяет только транспорт, не сбрасывая каталог и счётчик временных путей.
void attachGitHttp(GitHttp? http) {
  if (_gitFs == null) {
    throw StateError('Git is not bound to a virtual filesystem.');
  }
  _gitHttp = http;
}

/// Снимает привязку. Следующий вызов без [bindGitIo] падает, а не пишет в чужую ФС.
void clearGitIo() {
  _gitFs = null;
  _gitCwd = '/';
  _gitHttp = null;
  _gitEnv = const {};
}

String _absolute(String path) {
  final base = path.startsWith('/') ? path : '$_gitCwd/$path';
  return VfsPath.normalize(base);
}

/// zlib для loose-объектов. Пакет `archive` на web не тянет `dart:io`.
final zlib = _GitZlib();

final class _GitZlib {
  // Уровень 1 даёт заголовок zlib 78 01, как loose-объекты git.
  List<int> encode(List<int> bytes) =>
      const ZLibEncoder().encode(bytes, level: 1);

  List<int> decode(List<int> bytes) => const ZLibDecoder().decodeBytes(bytes);
}

/// Ошибка файловой операции в том виде, в каком её ждёт скопированный git.
final class FileSystemException implements Exception {
  FileSystemException(this.message, [this.path]);

  final String message;
  final String? path;

  @override
  String toString() => path == null ? message : '$message: $path';
}

/// Тип узла для `FileSystemEntity.type`. Только то, что различает репозиторий.
enum FileSystemEntityType { file, directory, link, notFound }

/// Режим записи reflog: дописать строку, не затереть журнал.
enum FileMode { write, writeOnlyAppend, append }

/// `stat` без устройства и inode: у виртуальной ФС их нет, git читает права и время.
final class FileStat {
  FileStat({
    required this.mode,
    required this.size,
    required this.changed,
    required this.modified,
  });

  static Future<FileStat> stat(String path) async {
    final node = await _statFollow(path);
    if (node == null) {
      throw FileSystemException('No such file or directory', _absolute(path));
    }
    final time = DateTime.fromMillisecondsSinceEpoch(node.mtime * 1000);
    return FileStat(
      mode: node.mode,
      size: node.size,
      changed: time,
      modified: time,
    );
  }

  final int mode;
  final int size;
  final DateTime changed;
  final DateTime modified;
}

/// Общий предок `File`, `Directory` и `Link`.
abstract base class FileSystemEntity {
  FileSystemEntity(String path) : path = _absolute(path);

  final String path;

  static Future<FileSystemEntityType> type(
    String path, {
    bool followLinks = true,
  }) async {
    final node = await gitFs.stat(_absolute(path), followLast: followLinks);
    if (node == null) return FileSystemEntityType.notFound;
    return switch (node.kind) {
      VfsNodeKind.file => FileSystemEntityType.file,
      VfsNodeKind.dir => FileSystemEntityType.directory,
      VfsNodeKind.symlink => FileSystemEntityType.link,
    };
  }

  Future<bool> exists();

  Future<void> delete({bool recursive = false});
}

/// Файл виртуальной ФС.
final class File extends FileSystemEntity {
  File(super.path);

  Directory get parent => Directory(VfsPath.parent(path));

  @override
  Future<bool> exists() async =>
      await FileSystemEntity.type(path) == FileSystemEntityType.file;

  @override
  Future<void> delete({bool recursive = false}) async {
    if (recursive) {
      throw FileSystemException('Cannot recursively delete a file', path);
    }
    final kind = await FileSystemEntity.type(path, followLinks: false);
    if (kind != FileSystemEntityType.file) {
      throw FileSystemException('Not a file', path);
    }
    await _guard(() => gitFs.remove(path));
  }

  Future<Uint8List> readAsBytes() => _guard(() => gitFs.readBytes(path));

  Future<String> readAsString() async => utf8.decode(await readAsBytes());

  Future<List<String>> readAsLines() async =>
      const LineSplitter().convert(await readAsString());

  // flush совпадает с dart:io: виртуальная ФС не буферизует, параметр только в сигнатуре.
  // ignore: avoid-unused-parameters, запись сразу попадает в ФС
  Future<void> writeAsBytes(List<int> bytes, {bool flush = false}) =>
      _guard(() => _writeLimited(path, bytes));

  Future<void> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    // ignore: avoid-unused-parameters, запись сразу попадает в ФС
    bool flush = false,
  }) async {
    final encoded = utf8.encode(contents);
    if (mode == FileMode.write || !await exists()) {
      await writeAsBytes(encoded);
      return;
    }
    final previous = await readAsBytes();
    await writeAsBytes([...previous, ...encoded]);
  }
}

/// Каталог виртуальной ФС.
final class Directory extends FileSystemEntity {
  Directory(super.path);

  // ignore: prefer_constructors_over_static_methods, имя совпадает с dart:io Directory.current
  static Directory get current => Directory(_gitCwd);

  // ignore: prefer_constructors_over_static_methods, имя совпадает с dart:io Directory.systemTemp
  static Directory get systemTemp => Directory('/tmp');

  @override
  Future<bool> exists() async =>
      await FileSystemEntity.type(path) == FileSystemEntityType.directory;

  Future<Directory> create({bool recursive = false}) async {
    await _guard(() => gitFs.mkdir(path, recursive: recursive || path == '/'));
    return this;
  }

  Future<Directory> createTemp([String prefix = '']) async {
    _gitTempSerial += 1;
    final child = path == '/'
        ? '/$prefix$_gitTempSerial'
        : '$path/$prefix$_gitTempSerial';
    final directory = Directory(child);
    await directory.create(recursive: true);
    return directory;
  }

  @override
  Future<void> delete({bool recursive = false}) async {
    final kind = await FileSystemEntity.type(path, followLinks: false);
    if (kind == FileSystemEntityType.notFound) {
      throw FileSystemException('No such file or directory', path);
    }
    if (kind != FileSystemEntityType.directory) {
      throw FileSystemException('Not a directory', path);
    }
    if (!recursive) {
      final children = await gitFs.list(path);
      if (children.isNotEmpty) {
        throw FileSystemException('Directory not empty', path);
      }
    }
    await _guard(() => gitFs.remove(path, recursive: true));
  }

  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) async* {
    final kind = await FileSystemEntity.type(path, followLinks: followLinks);
    if (kind != FileSystemEntityType.directory) {
      throw FileSystemException('Not a directory', path);
    }
    final nodes = recursive ? await gitFs.walk(path) : await gitFs.list(path);
    for (final node in nodes) {
      if (!followLinks && node.kind == VfsNodeKind.symlink) {
        yield Link(node.path);
        continue;
      }
      yield switch (node.kind) {
        VfsNodeKind.file => File(node.path),
        VfsNodeKind.dir => Directory(node.path),
        VfsNodeKind.symlink => Link(node.path),
      };
    }
  }
}

/// Симлинк. Цель хранится как записана, без канонизации.
final class Link extends FileSystemEntity {
  Link(super.path);

  @override
  Future<bool> exists() async =>
      await FileSystemEntity.type(path, followLinks: false) ==
      FileSystemEntityType.link;

  Future<void> create(String target) =>
      _guard(() => gitFs.symlink(target, path));

  Future<String> target() async {
    final node = await gitFs.stat(path, followLast: false);
    final link = node?.target;
    if (node?.kind != VfsNodeKind.symlink || link == null) {
      throw FileSystemException('Not a link', path);
    }
    return link;
  }

  @override
  Future<void> delete({bool recursive = false}) async {
    if (!await exists()) {
      throw FileSystemException('No such file or directory', path);
    }
    await _guard(() => gitFs.remove(path));
  }
}

/// Заглушка `Platform` для веток, которые ещё читают ОС в скопированном коде.
///
/// Виртуальный хост не Windows. Сюда попадает окружение команды, не переменные машины.
// ignore: avoid_classes_with_only_static_members, имя Platform нужно скопированному git
abstract final class Platform {
  static const isWindows = false;
  static Map<String, String> get environment => _gitEnv;
}

Future<VfsNode?> _statFollow(String path) => gitFs.stat(_absolute(path));

Future<void> _writeLimited(String path, List<int> bytes) async {
  if (bytes.length > gitFs.limits.maxFileBytes) {
    throw FileSystemException('File too large for the virtual host', path);
  }
  await gitFs.writeBytes(path, Uint8List.fromList(bytes));
}

Future<T> _guard<T>(Future<T> Function() body) async {
  try {
    return await body();
  } on VfsException catch (error, stack) {
    Error.throwWithStackTrace(FileSystemException(error.message), stack);
  }
}

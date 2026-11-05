import 'dart:typed_data';

import 'package:virtual_host/src/os_snapshot.dart';
import 'package:virtual_host/src/vfs_access.dart';
import 'package:virtual_host/src/vfs_path.dart';
import 'package:virtual_host/src/vfs_store.dart';
import 'package:virtual_host/src/virtual_limits.dart';

/// Ошибка операции над виртуальной ФС. [message] — текст в стиле POSIX (`No such file or directory`),
/// его показывают модели без перевода, поэтому он совпадает с тем, что выводит настоящий shell.
final class VfsException implements Exception {
  const VfsException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Режим `/tmp`: `1777`. Запись разрешена остальным, sticky-бит хранится и не проверяется:
/// пользователь у хоста один, чужие файлы удалять некому.
const vfsTmpMode = 1023;

/// Файловая система Host: правила POSIX для путей, симлинков, каталогов, прав и квоты.
///
/// Постоянные файлы лежат в [VfsStore]. Поверх него два необязательных слоя: [snapshot] (системные
/// каталоги только для чтения) и [temporary] (`/tmp` в памяти процесса). Правила одни, поэтому тесты
/// без слоёв и приложение со слоями проходят через одни и те же операции. Вызовы принимают относительные
/// пути: их разрешают от [cwd] (по умолчанию корень).
final class VirtualFs {
  VirtualFs(
    this._store, {
    this.snapshot,
    this.temporary,
    this.limits = const VirtualLimits(),
    int Function()? clock,
  }) : _clock = clock ?? _unixNow;

  final VfsStore _store;

  /// Системные каталоги. Нет снимка — эти пути читаются и пишутся как обычное хранилище.
  final OsSnapshot? snapshot;

  /// Память `/tmp` на время процесса. Нет слоя — `/tmp` хранится вместе с остальными файлами.
  final VfsStore? temporary;

  final VirtualLimits limits;
  final int Function() _clock;

  static const _defaultFileMode = 420; // 0644
  static const _defaultDirMode = 493; // 0755
  static const _symlinkMode = 511; // 0777

  static int _unixNow() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Метаданные пути. [followLast] = false ведёт себя как `lstat`: последний симлинк возвращается сам.
  /// Нет пути (в том числе висячий симлинк) — null.
  Future<VfsNode?> stat(
    String path, {
    String cwd = VfsPath.root,
    bool followLast = true,
  }) async {
    final resolved = await _resolve(path, cwd: cwd, followLast: followLast);
    return _node(resolved);
  }

  /// Прямые потомки каталога. Не каталог — ошибка.
  Future<List<VfsNode>> list(String path, {String cwd = VfsPath.root}) async {
    final dir = await _resolve(path, cwd: cwd);
    await _requireDir(dir);
    return _children(dir);
  }

  /// Все потомки каталога на любой глубине (без самого каталога). Не каталог — ошибка.
  Future<List<VfsNode>> walk(String path, {String cwd = VfsPath.root}) async {
    final dir = await _resolve(path, cwd: cwd);
    await _requireDir(dir);
    return _descendants(dir);
  }

  /// Содержимое файла. Нет пути — ошибка, каталог — ошибка.
  Future<Uint8List> readBytes(String path, {String cwd = VfsPath.root}) async {
    final resolved = await _resolve(path, cwd: cwd);
    final node = await _node(resolved);
    if (node == null) {
      throw const VfsException('No such file or directory');
    }
    if (node.kind == VfsNodeKind.dir) {
      throw const VfsException('Is a directory');
    }
    if (!vfsAllows(node, VfsAccess.read)) {
      throw const VfsException('Permission denied');
    }
    return await _content(resolved) ?? Uint8List(0);
  }

  /// Создаёт или перезаписывает файл. Писать через симлинк означает писать в его цель, как в shell.
  /// Существующий файл сохраняет права, если [mode] не задан. Превышение лимитов — ошибка.
  Future<void> writeBytes(
    String path,
    Uint8List bytes, {
    String cwd = VfsPath.root,
    int? mode,
  }) async {
    final target = await _resolve(path, cwd: cwd);
    _rejectSnapshot(target);
    if (bytes.length > limits.maxFileBytes) {
      throw const VfsException('File too large for the virtual host');
    }
    await _requireDir(VfsPath.parent(target));
    final existing = await _node(target);
    if (existing?.kind == VfsNodeKind.dir) {
      throw const VfsException('Is a directory');
    }
    final used = await usedBytes();
    if (used - (existing?.size ?? 0) + bytes.length > limits.quotaBytes) {
      throw const VfsException('No space left on device');
    }
    await _put(
      VfsNode(
        path: target,
        kind: VfsNodeKind.file,
        mode: mode ?? existing?.mode ?? _defaultFileMode,
        mtime: _clock(),
        size: bytes.length,
        uid: existing?.uid ?? vfsAgentUid,
        gid: existing?.gid ?? vfsAgentGid,
      ),
      content: bytes,
    );
  }

  /// Создаёт каталог. С [recursive] создаёт недостающих предков и не падает, если каталог уже есть.
  Future<void> mkdir(
    String path, {
    String cwd = VfsPath.root,
    bool recursive = false,
  }) async {
    final canonical = await _resolve(path, cwd: cwd);
    if (!recursive) {
      if (canonical == VfsPath.root || await _node(canonical) != null) {
        throw const VfsException('File exists');
      }
      _rejectSnapshot(canonical);
      await _requireDir(VfsPath.parent(canonical));
      await _putDir(canonical);
      return;
    }
    await _transaction(() async {
      var current = VfsPath.root;
      for (final segment in VfsPath.segments(canonical)) {
        current = VfsPath.join(current, segment);
        final node = await _node(current);
        if (node == null) {
          _rejectSnapshot(current);
          await _putDir(current);
        } else if (node.kind != VfsNodeKind.dir) {
          throw const VfsException('File exists');
        }
      }
    });
  }

  /// Удаляет файл, симлинк или каталог. Каталог без [recursive] не удаляется. Сам симлинк не разворачивается.
  Future<void> remove(
    String path, {
    String cwd = VfsPath.root,
    bool recursive = false,
  }) async {
    final canonical = await _resolveEntry(path, cwd: cwd);
    if (canonical == VfsPath.root) {
      throw const VfsException('Operation not permitted');
    }
    final node = await _node(canonical);
    if (node == null) {
      throw const VfsException('No such file or directory');
    }
    _rejectSnapshot(canonical);
    if (node.kind != VfsNodeKind.dir) {
      await _delete(canonical);
      return;
    }
    if (!recursive) {
      throw const VfsException('Is a directory');
    }
    await _transaction(() async {
      for (final inner in await _descendants(canonical)) {
        await _delete(inner.path);
      }
      await _delete(canonical);
    });
  }

  /// Переименовывает или переносит узел (вместе с потомками каталога). Существующая цель заменяется
  /// по правилам [_checkReplaceable]. Перенос каталога в себя — ошибка. Выбор «переместить внутрь
  /// каталога» принимает апплет `mv`, а не эта операция: здесь цель — полный новый путь.
  Future<void> rename(
    String from,
    String to, {
    String cwd = VfsPath.root,
  }) async {
    final source = await _resolveEntry(from, cwd: cwd);
    if (source == VfsPath.root) {
      throw const VfsException('Operation not permitted');
    }
    final destination = await _resolveEntry(to, cwd: cwd);
    final node = await _node(source);
    if (node == null) {
      throw const VfsException('No such file or directory');
    }
    if (source == destination) {
      return;
    }
    if (destination.startsWith('$source/')) {
      throw const VfsException('Invalid argument');
    }
    _rejectSnapshot(source);
    _rejectSnapshot(destination);
    await _requireDir(VfsPath.parent(destination));
    final existing = await _node(destination);
    if (existing != null) {
      await _checkReplaceable(node, existing, destination);
    }
    final moved = node.kind == VfsNodeKind.dir
        ? await _descendants(source)
        : const <VfsNode>[];
    // Содержимое читаем до удаления: в транзакции оно должно быть доступно для записи на новом пути.
    final contents = <String, Uint8List?>{
      for (final n in [node, ...moved])
        n.path: n.kind == VfsNodeKind.file ? await _content(n.path) : null,
    };
    await _transaction(() async {
      if (existing != null) {
        await _delete(destination);
      }
      for (final n in [...moved, node]) {
        await _delete(n.path);
      }
      for (final n in [node, ...moved]) {
        await _put(
          _relocate(n, source, destination),
          content: contents[n.path],
        );
      }
    });
  }

  /// Копирует файл, симлинк или каталог на полный путь [to]. Каталог требует [recursive]. Симлинки внутри
  /// каталога копируются как симлинки (поведение `cp -R`). Существующая цель проверяется по правилам
  /// [_checkReplaceable]; «скопировать внутрь каталога» решает апплет `cp`.
  Future<void> copy(
    String from,
    String to, {
    String cwd = VfsPath.root,
    bool recursive = false,
  }) async {
    final source = await _resolve(from, cwd: cwd, followLast: false);
    if (source == VfsPath.root) {
      throw const VfsException('Operation not permitted');
    }
    final node = await _node(source);
    if (node == null) {
      throw const VfsException('No such file or directory');
    }
    final destination = await _resolveEntry(to, cwd: cwd);
    if (node.kind == VfsNodeKind.dir) {
      if (!recursive) {
        throw const VfsException('-r not specified; omitting directory');
      }
      if (destination == source || destination.startsWith('$source/')) {
        throw const VfsException('Invalid argument');
      }
    }
    _rejectSnapshot(destination);
    await _requireDir(VfsPath.parent(destination));
    final existing = await _node(destination);
    if (existing != null) {
      await _checkReplaceable(node, existing, destination);
    }
    final subtree = node.kind == VfsNodeKind.dir
        ? await _descendants(source)
        : const <VfsNode>[];
    final contents = <String, Uint8List?>{};
    for (final n in [node, ...subtree]) {
      if (n.kind != VfsNodeKind.file) {
        contents[n.path] = null;
        continue;
      }
      if (!vfsAllows(n, VfsAccess.read)) {
        throw const VfsException('Permission denied');
      }
      contents[n.path] = await _content(n.path);
    }
    final used = await usedBytes();
    final added = [node, ...subtree]
        .where((n) => n.kind == VfsNodeKind.file)
        .fold<int>(0, (sum, n) => sum + n.size);
    if (used - (existing?.size ?? 0) + added > limits.quotaBytes) {
      throw const VfsException('No space left on device');
    }
    await _transaction(() async {
      for (final n in [node, ...subtree]) {
        await _put(
          _relocate(n, source, destination, mtime: _clock(), asAgent: true),
          content: contents[n.path],
        );
      }
    });
  }

  /// Создаёт симлинк [path] с целью [target] (как записана, не разворачивается).
  Future<void> symlink(
    String target,
    String path, {
    String cwd = VfsPath.root,
  }) async {
    final entry = await _resolveEntry(path, cwd: cwd);
    if (await _node(entry) != null) {
      throw const VfsException('File exists');
    }
    _rejectSnapshot(entry);
    await _requireDir(VfsPath.parent(entry));
    await _put(
      VfsNode(
        path: entry,
        kind: VfsNodeKind.symlink,
        mode: _symlinkMode,
        mtime: _clock(),
        size: 0,
        target: target,
      ),
    );
  }

  /// `touch`: создаёт пустой файл или обновляет время изменения существующего узла. Содержимое и права
  /// не меняются. Каталог тоже обновляется; у симлинка обновляется цель, как у `touch` по умолчанию.
  Future<void> touch(String path, {String cwd = VfsPath.root}) async {
    final resolved = await _resolve(path, cwd: cwd);
    final node = await _node(resolved);
    if (node == null) {
      await writeBytes(resolved, Uint8List(0));
      return;
    }
    _rejectSnapshot(resolved);
    await _put(
      VfsNode(
        path: resolved,
        kind: node.kind,
        mode: node.mode,
        mtime: _clock(),
        size: node.size,
        uid: node.uid,
        gid: node.gid,
        target: node.target,
      ),
    );
  }

  /// Меняет права узла. Содержимое и mtime не меняются (как у `chmod`).
  Future<void> chmod(String path, int mode, {String cwd = VfsPath.root}) async {
    final resolved = await _resolve(path, cwd: cwd);
    final node = await _node(resolved);
    if (node == null) {
      throw const VfsException('No such file or directory');
    }
    _rejectSnapshot(resolved);
    await _put(
      VfsNode(
        path: node.path,
        kind: node.kind,
        mode: mode,
        mtime: node.mtime,
        size: node.size,
        uid: node.uid,
        gid: node.gid,
        target: node.target,
      ),
    );
  }

  /// Канонический путь с раскрытыми симлинками, как у `readlink -f`. Хвост, которого нет, допустим:
  /// так получается путь для записи в новый файл через симлинк. Цикл симлинков — ошибка.
  Future<String> realpath(String path, {String cwd = VfsPath.root}) =>
      _resolve(path, cwd: cwd);

  /// Текущее время в секундах Unix: то же, что пишется в mtime новых узлов.
  int now() => _clock();

  /// Суммарный размер файлов Host в байтах. Снимок не входит: это не данные агента.
  /// `/tmp` входит, иначе временные файлы обошли бы квоту.
  Future<int> usedBytes() async {
    final persisted = await _store.totalBytes();
    final scratch = temporary == null ? 0 : await temporary!.totalBytes();
    return persisted + scratch;
  }

  /// Метаданные узла по каноническому пути без разворачивания симлинка в конце.
  /// Корень существует всегда, даже если в хранилище его нет. Путь снимка не смотрит в базу.
  Future<VfsNode?> _node(String canonical) async {
    if (canonical == VfsPath.root) {
      return VfsNode(
        path: VfsPath.root,
        kind: VfsNodeKind.dir,
        mode: _defaultDirMode,
        mtime: _clock(),
        size: 0,
      );
    }
    final image = snapshot;
    if (image != null && image.owns(canonical)) {
      return image.node(canonical, now: _clock());
    }
    if (_isTmp(canonical)) {
      await _ensureTmp();
      return temporary!.get(canonical);
    }
    return _store.get(canonical);
  }

  /// Правила замены существующей цели при rename и copy (как у POSIX `rename(2)`):
  /// каталог заменяет только пустой каталог, файл не заменяет каталог, каталог не заменяет файл.
  Future<void> _checkReplaceable(
    VfsNode source,
    VfsNode existing,
    String destination,
  ) async {
    final sourceIsDir = source.kind == VfsNodeKind.dir;
    if (existing.kind != VfsNodeKind.dir) {
      if (sourceIsDir) {
        throw const VfsException('Not a directory');
      }
      return;
    }
    if (!sourceIsDir) {
      throw const VfsException('Is a directory');
    }
    if ((await _children(destination)).isNotEmpty) {
      throw const VfsException('Directory not empty');
    }
  }

  Future<void> _requireDir(String canonical) async {
    final node = await _node(canonical);
    if (node == null) {
      throw const VfsException('No such file or directory');
    }
    if (node.kind != VfsNodeKind.dir) {
      throw const VfsException('Not a directory');
    }
  }

  Future<void> _putDir(String canonical) => _put(
    VfsNode(
      path: canonical,
      kind: VfsNodeKind.dir,
      mode: _defaultDirMode,
      mtime: _clock(),
      size: 0,
    ),
  );

  /// Канонический путь с раскрытыми симлинками. Симлинк в середине пути раскрывается всегда,
  /// в конце — только при [followLast]. Цикл или слишком длинная цепочка — ошибка, как `ELOOP`.
  Future<String> _resolve(
    String path, {
    String cwd = VfsPath.root,
    bool followLast = true,
    int hops = 0,
  }) async {
    final canonical = VfsPath.normalize(path, cwd: cwd);
    final parts = VfsPath.segments(canonical);
    var current = VfsPath.root;
    for (var i = 0; i < parts.length; i++) {
      final next = VfsPath.join(current, parts[i]);
      final isLast = i == parts.length - 1;
      if (!isLast || followLast) {
        final node = await _node(next);
        if (node?.kind == VfsNodeKind.symlink) {
          if (hops >= limits.maxSymlinkHops) {
            throw const VfsException('Too many levels of symbolic links');
          }
          final targetPath = VfsPath.normalize(
            node!.target ?? '',
            cwd: current,
          );
          final rest = parts.sublist(i + 1).join('/');
          return _resolve(
            rest.isEmpty ? targetPath : '$targetPath/$rest',
            followLast: followLast,
            hops: hops + 1,
          );
        }
      }
      current = next;
    }
    return current;
  }

  /// Путь нового или существующего узла: родитель раскрывается, последний компонент — нет.
  Future<String> _resolveEntry(String path, {required String cwd}) async {
    final canonical = VfsPath.normalize(path, cwd: cwd);
    if (canonical == VfsPath.root) return VfsPath.root;
    final parent = await _resolve(VfsPath.parent(canonical));
    return VfsPath.join(parent, VfsPath.name(canonical));
  }

  /// Копия узла на новом пути: префикс [source] заменяется на [destination].
  VfsNode _relocate(
    VfsNode node,
    String source,
    String destination, {
    int? mtime,
    bool asAgent = false,
  }) {
    // Путь узла начинается с [source] (он либо сам, либо его потомок), поэтому замена первого вхождения точна.
    final path = node.path.replaceFirst(source, destination);
    return VfsNode(
      path: path,
      kind: node.kind,
      mode: node.mode,
      mtime: mtime ?? node.mtime,
      size: node.size,
      uid: asAgent ? vfsAgentUid : node.uid,
      gid: asAgent ? vfsAgentGid : node.gid,
      target: node.target,
    );
  }

  /// Снимок закрыт целиком. Проверка идёт до хранилища, чтобы запись не создала тень в базе.
  void _rejectSnapshot(String canonical) {
    if (snapshot?.owns(canonical) ?? false) {
      throw const VfsException('Read-only file system');
    }
  }

  bool _isTmp(String canonical) =>
      temporary != null &&
      (canonical == '/tmp' || canonical.startsWith('/tmp/'));

  /// Узел базы под снимком или `/tmp` не показывается: эти префиксы принадлежат другим слоям.
  bool _hiddenFromStore(String path) =>
      (snapshot?.owns(path) ?? false) || _isTmp(path);

  VfsStore _layer(String canonical) => _isTmp(canonical) ? temporary! : _store;

  /// Транзакция памяти снаружи транзакции базы: ошибка базы откатывает и уже изменённый `/tmp`.
  Future<T> _transaction<T>(Future<T> Function() action) {
    final scratch = temporary;
    if (scratch == null) return _store.transaction(action);
    return scratch.transaction(() => _store.transaction(action));
  }

  Future<void> _ensureTmp() async {
    final scratch = temporary;
    if (scratch == null || await scratch.get('/tmp') != null) return;
    await scratch.put(
      VfsNode(
        path: '/tmp',
        kind: VfsNodeKind.dir,
        mode: vfsTmpMode,
        mtime: _clock(),
        size: 0,
        uid: vfsRootUid,
        gid: vfsRootGid,
      ),
    );
  }

  Future<void> _put(VfsNode node, {Uint8List? content}) {
    _rejectSnapshot(node.path);
    return _layer(node.path).put(node, content: content);
  }

  Future<void> _delete(String path) {
    _rejectSnapshot(path);
    return _layer(path).delete(path);
  }

  Future<Uint8List?> _content(String path) {
    final image = snapshot;
    if (image != null && image.owns(path)) {
      return Future.value(image.content(path, now: _clock()));
    }
    if (_isTmp(path)) return temporary!.content(path);
    return _store.content(path);
  }

  Future<List<VfsNode>> _children(String dir) async {
    final image = snapshot;
    if (image != null && image.owns(dir)) {
      return image.children(dir, now: _clock());
    }
    if (_isTmp(dir)) {
      await _ensureTmp();
      return temporary!.children(dir);
    }
    if (dir != VfsPath.root) return _store.children(dir);
    await _ensureTmp();
    final byPath = <String, VfsNode>{
      for (final node in await _store.children(dir))
        if (!_hiddenFromStore(node.path)) node.path: node,
    };
    if (image != null) {
      for (final node in image.children(dir, now: _clock())) {
        byPath[node.path] = node;
      }
    }
    if (temporary != null) {
      final tmp = await temporary!.get('/tmp');
      if (tmp != null) byPath[tmp.path] = tmp;
    }
    return _sorted(byPath.values);
  }

  Future<List<VfsNode>> _descendants(String dir) async {
    final image = snapshot;
    if (image != null && image.owns(dir)) {
      return image.descendants(dir, now: _clock());
    }
    if (_isTmp(dir)) {
      await _ensureTmp();
      return temporary!.descendants(dir);
    }
    if (dir != VfsPath.root) return _store.descendants(dir);
    await _ensureTmp();
    final nodes = [
      for (final node in await _store.descendants(dir))
        if (!_hiddenFromStore(node.path)) node,
      if (image != null) ...image.descendants(dir, now: _clock()),
    ];
    if (temporary != null) {
      final tmp = await temporary!.get('/tmp');
      if (tmp != null) nodes.add(tmp);
      nodes.addAll(await temporary!.descendants('/tmp'));
    }
    return _sorted(nodes);
  }

  static List<VfsNode> _sorted(Iterable<VfsNode> nodes) =>
      nodes.toList()..sort((a, b) => a.path.compareTo(b.path));
}

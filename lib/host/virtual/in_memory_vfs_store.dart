import 'dart:typed_data';

import 'package:probably_works/host/virtual/vfs_path.dart';
import 'package:probably_works/host/virtual/vfs_store.dart';

/// Хранилище узлов в памяти. Нужно тестам и паритет-проверкам: поведение совпадает с базой,
/// потому что правила живут в [VirtualFs], а не здесь.
final class InMemoryVfsStore implements VfsStore {
  final Map<String, VfsNode> _nodes = {};
  final Map<String, Uint8List> _contents = {};

  @override
  Future<VfsNode?> get(String path) async => _nodes[path];

  @override
  Future<List<VfsNode>> children(String dir) async => _sorted(
    _nodes.values.where((n) => n.path != VfsPath.root && n.parentPath == dir),
  );

  @override
  Future<List<VfsNode>> descendants(String dir) async {
    final prefix = dir == VfsPath.root ? '/' : '$dir/';
    return _sorted(
      _nodes.values.where((n) => n.path != dir && n.path.startsWith(prefix)),
    );
  }

  @override
  Future<Uint8List?> content(String path) async => _contents[path];

  @override
  Future<void> put(VfsNode node, {Uint8List? content}) async {
    _nodes[node.path] = node;
    if (node.kind != VfsNodeKind.file) {
      _contents.remove(node.path);
    } else if (content != null) {
      _contents[node.path] = Uint8List.fromList(content);
    }
  }

  @override
  Future<void> delete(String path) async {
    _nodes.remove(path);
    _contents.remove(path);
  }

  @override
  Future<int> totalBytes() async => _nodes.values
      .where((n) => n.kind == VfsNodeKind.file)
      .fold<int>(0, (sum, n) => sum + n.size);

  /// Откат при исключении: состояние возвращается к снимку, как у транзакции базы.
  @override
  Future<T> transaction<T>(Future<T> Function() action) async {
    final nodes = Map.of(_nodes);
    final contents = Map.of(_contents);
    try {
      return await action();
    } on Object {
      _nodes
        ..clear()
        ..addAll(nodes);
      _contents
        ..clear()
        ..addAll(contents);
      rethrow;
    }
  }

  static List<VfsNode> _sorted(Iterable<VfsNode> nodes) =>
      nodes.toList()..sort((a, b) => a.path.compareTo(b.path));
}

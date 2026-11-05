import 'package:drift/drift.dart';
import 'package:probably_works/core/db/app_database.dart';
import 'package:virtual_host/virtual_host.dart';

/// Хранилище файлов одного виртуального Host в базе приложения. Правила POSIX — в `VirtualFs`.
///
/// Листинг и `stat` читают только метаданные: содержимое тянется отдельным запросом, когда оно нужно.
/// Поддерево выбирается диапазоном по ключу, а не LIKE: так не нужно экранировать `%` и `_` в именах.
final class VirtualFsRepository implements VfsStore {
  VirtualFsRepository(this._db, this._hostId);

  final AppDatabase _db;
  final String _hostId;

  $VirtualFsNodesTable get _table => _db.virtualFsNodes;

  /// Колонки без содержимого: для `stat`, листинга и обхода.
  List<Expression> get _metaColumns => [
    _table.path,
    _table.kind,
    _table.mode,
    _table.mtime,
    _table.size,
    _table.target,
  ];

  @override
  Future<VfsNode?> get(String path) async {
    final query = _db.selectOnly(_table)
      ..addColumns(_metaColumns)
      ..where(_table.hostId.equals(_hostId) & _table.path.equals(path));
    final row = await query.getSingleOrNull();
    return row == null ? null : _toNode(row);
  }

  @override
  Future<List<VfsNode>> children(String dir) async {
    final query = _db.selectOnly(_table)
      ..addColumns(_metaColumns)
      ..where(_table.hostId.equals(_hostId) & _table.parentPath.equals(dir))
      ..orderBy([OrderingTerm.asc(_table.path)]);
    return (await query.get()).map(_toNode).toList();
  }

  @override
  Future<List<VfsNode>> descendants(String dir) async {
    // Все пути поддерева лежат между «dir/» (включительно) и «dir0» (исключая): «0» следует сразу за «/».
    final low = dir == VfsPath.root ? '/' : '$dir/';
    final high = dir == VfsPath.root ? '0' : '${dir}0';
    final query = _db.selectOnly(_table)
      ..addColumns(_metaColumns)
      ..where(
        _table.hostId.equals(_hostId) &
            _table.path.isBiggerOrEqualValue(low) &
            _table.path.isSmallerThanValue(high),
      )
      ..orderBy([OrderingTerm.asc(_table.path)]);
    return (await query.get()).map(_toNode).toList();
  }

  @override
  Future<Uint8List?> content(String path) async {
    final query = _db.selectOnly(_table)
      ..addColumns([_table.content])
      ..where(_table.hostId.equals(_hostId) & _table.path.equals(path));
    final row = await query.getSingleOrNull();
    return row?.read(_table.content);
  }

  /// Записывает узел. Для файла без [content] существующее содержимое сохраняется (так работает chmod),
  /// для каталога и симлинка содержимое всегда сбрасывается. Строка заменяется целиком.
  @override
  Future<void> put(VfsNode node, {Uint8List? content}) async {
    final keepsContent = node.kind == VfsNodeKind.file && content == null;
    if (keepsContent) {
      final updated = await (_db.update(_table)..where(_rowOf(node.path)))
          .write(_companionFor(node, withContent: false));
      if (updated > 0) return;
    }
    await _db
        .into(_table)
        .insertOnConflictUpdate(
          _companionFor(
            node,
            content: node.kind == VfsNodeKind.file ? content : null,
          ),
        );
  }

  @override
  Future<void> delete(String path) =>
      (_db.delete(_table)..where(_rowOf(path))).go();

  @override
  Future<int> totalBytes() async {
    final total = _table.size.sum();
    final query = _db.selectOnly(_table)
      ..addColumns([total])
      ..where(
        _table.hostId.equals(_hostId) &
            _table.kind.equals(VfsNodeKind.file.name),
      );
    final row = await query.getSingle();
    return row.read(total) ?? 0;
  }

  @override
  Future<T> transaction<T>(Future<T> Function() action) =>
      _db.transaction(action);

  /// Фильтр строки для update/delete: их `where` принимает функцию от таблицы.
  Expression<bool> Function($VirtualFsNodesTable) _rowOf(String path) =>
      (t) => t.hostId.equals(_hostId) & t.path.equals(path);

  /// [withContent] false оставляет колонку содержимого нетронутой (колонка absent, а не null).
  VirtualFsNodesCompanion _companionFor(
    VfsNode node, {
    Uint8List? content,
    bool withContent = true,
  }) => VirtualFsNodesCompanion(
    hostId: Value(_hostId),
    path: Value(node.path),
    parentPath: Value(node.parentPath),
    kind: Value(node.kind.name),
    mode: Value(node.mode),
    mtime: Value(node.mtime),
    size: Value(node.size),
    target: Value(node.target),
    content: withContent ? Value(content) : const Value.absent(),
  );

  VfsNode _toNode(TypedResult row) => VfsNode(
    path: row.read(_table.path)!,
    kind: VfsNodeKind.values.byName(row.read(_table.kind)!),
    mode: row.read(_table.mode)!,
    mtime: row.read(_table.mtime)!,
    size: row.read(_table.size)!,
    target: row.read(_table.target),
  );
}

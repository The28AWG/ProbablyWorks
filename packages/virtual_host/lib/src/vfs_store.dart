import 'dart:typed_data';

import 'package:virtual_host/src/vfs_path.dart';

/// Тип узла виртуальной файловой системы.
enum VfsNodeKind { file, dir, symlink }

/// Пользователь и группа агента. Один агент на хост, root ему не выдаётся.
const vfsAgentUid = 1000;
const vfsAgentGid = 1000;

/// Владелец узлов снимка и каталога `/tmp`.
const vfsRootUid = 0;
const vfsRootGid = 0;

/// Имя учётной записи root в `ls` и `stat`.
const vfsRootName = 'root';

/// Метаданные узла. Содержимое файла хранится отдельно и читается только по запросу,
/// чтобы `ls` и `stat` не тянули мегабайты из базы.
final class VfsNode {
  const VfsNode({
    required this.path,
    required this.kind,
    required this.mode,
    required this.mtime,
    required this.size,
    this.uid = vfsAgentUid,
    this.gid = vfsAgentGid,
    this.target,
  });

  /// Канонический путь ([VfsPath]).
  final String path;
  final VfsNodeKind kind;

  /// Права в восьмеричной записи как число (например, 0644 = 420).
  final int mode;

  /// Время изменения в секундах Unix. Совпадает по единице с `stat -c %Y`.
  final int mtime;

  /// Владелец. Узлы базы — [vfsAgentUid], снимок и `/tmp` — [vfsRootUid]. Колонки в базе нет:
  /// сохранённые файлы всегда принадлежат агенту, поэтому значение живёт только в памяти узла.
  final int uid;

  /// Группа. Совпадает с правилом [uid]: агент или root.
  final int gid;

  /// Размер содержимого в байтах; для каталога и симлинка 0 (для симлинка см. [target]).
  final int size;

  /// Цель симлинка как записана; для остальных узлов null.
  final String? target;

  String get name => VfsPath.name(path);

  String get parentPath => VfsPath.parent(path);
}

/// Хранилище узлов одного Host. Реализации: память (тесты) и база приложения. Правила POSIX здесь не
/// живут: их задаёт [VirtualFs], поэтому обе реализации ведут себя одинаково.
abstract interface class VfsStore {
  /// Метаданные узла по каноническому пути, без содержимого. Нет узла — null.
  Future<VfsNode?> get(String path);

  /// Прямые потомки каталога, отсортированные по пути.
  Future<List<VfsNode>> children(String dir);

  /// Все потомки каталога на любой глубине, без самого каталога, отсортированные по пути.
  Future<List<VfsNode>> descendants(String dir);

  /// Содержимое файла. Нет файла или узел не файл — null.
  Future<Uint8List?> content(String path);

  /// Вставляет или заменяет узел. [content] null означает «не менять содержимое» у существующего файла
  /// (нужно для chmod). Для каталога и симлинка содержимое всегда пустое.
  Future<void> put(VfsNode node, {Uint8List? content});

  /// Удаляет один узел (без потомков; потомки удаляет вызывающий).
  Future<void> delete(String path);

  /// Сумма размеров всех файлов. Для квоты.
  Future<int> totalBytes();

  /// Выполняет [action] атомарно: при исключении все изменения откатываются.
  Future<T> transaction<T>(Future<T> Function() action);
}

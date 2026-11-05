import 'package:probably_works/host/virtual/vfs_store.dart';

/// Какое действие агент пытается совершить с узлом.
enum VfsAccess { read, write, execute }

/// Имя владельца или группы для `ls` и `stat`. Root — фиксированное имя, любой другой номер
/// показывается как агент: других учётных записей у хоста нет.
String vfsAccountName(int id, String agentName) =>
    id == vfsRootUid ? vfsRootName : agentName;

/// Разрешено ли агенту [kind] для [node].
///
/// Агент — [vfsAgentUid] и не входит в группу root, поэтому свой узел проверяется битами владельца,
/// а чужой — битами «остальных». Иначе каталог root с режимом `0755` выглядел бы записываемым:
/// бит записи есть только у владельца.
bool vfsAllows(VfsNode node, VfsAccess kind) {
  final other = switch (kind) {
    VfsAccess.read => 4,
    VfsAccess.write => 2,
    VfsAccess.execute => 1,
  };
  final bit = node.uid == vfsAgentUid ? other << 6 : other;
  return node.mode & bit != 0;
}

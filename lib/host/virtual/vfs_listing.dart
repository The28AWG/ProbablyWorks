import 'package:probably_works/host/virtual/vfs_store.dart';

/// Форматирование метаданных узла как у GNU `ls -l` в локали C. Общее для типизированной операции
/// `ls` и апплета `ls`, чтобы оба выводили одно и то же.
///
/// Время — UTC: у виртуального Host нет часового пояса пользователя. Размер каталога и симлинка
/// фиксированы (4096 и длина цели), как на ext4.
abstract final class VfsListing {
  const VfsListing._();

  /// Размер для колонки размера: каталог — 4096, симлинк — длина цели, файл — содержимое.
  static int sizeOf(VfsNode node) => switch (node.kind) {
    VfsNodeKind.dir => 4096,
    VfsNodeKind.symlink => node.target?.length ?? 0,
    VfsNodeKind.file => node.size,
  };

  /// Блоки по 1 КиБ для строки `total`: каталог и файл округляются вверх до 4 КиБ, как на ext4.
  static int blocksOf(VfsNode node) => switch (node.kind) {
    VfsNodeKind.dir => 4,
    VfsNodeKind.symlink => 0,
    VfsNodeKind.file => ((node.size + 4095) ~/ 4096) * 4,
  };

  /// Строка `ls -l` для [node] с именем [name]. [width] — ширина колонки размера, [owner] — пользователь,
  /// которого показывают как владельца и группу.
  static String longLine(
    VfsNode node,
    String name, {
    required int width,
    required int now,
    required String owner,
  }) {
    final links = node.kind == VfsNodeKind.dir ? 2 : 1;
    final shown = node.kind == VfsNodeKind.symlink
        ? '$name -> ${node.target}'
        : name;
    final size = sizeOf(node).toString().padLeft(width);
    return '${permissions(node)} $links $owner $owner '
        '$size ${lsDate(node.mtime, now)} $shown';
  }

  static const _rwx = ['r', 'w', 'x'];

  /// Строка прав `-rwxr-xr-x` из типа и битов [VfsNode.mode].
  static String permissions(VfsNode node) {
    final type = switch (node.kind) {
      VfsNodeKind.dir => 'd',
      VfsNodeKind.symlink => 'l',
      VfsNodeKind.file => '-',
    };
    final bits = StringBuffer(type);
    for (var shift = 8; shift >= 0; shift--) {
      final set = (node.mode >> shift) & 1 == 1;
      bits.write(set ? _rwx[(8 - shift) % 3] : '-');
    }
    return bits.toString();
  }

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  /// Дата как у GNU ls: время за последние полгода, старше — год. Время в UTC.
  static String lsDate(int mtime, int now) {
    final t = DateTime.fromMillisecondsSinceEpoch(mtime * 1000, isUtc: true);
    final day = t.day.toString().padLeft(2);
    final month = _months[t.month - 1];
    const halfYear = 15778476;
    if ((now - mtime).abs() < halfYear) {
      final hh = t.hour.toString().padLeft(2, '0');
      final mm = t.minute.toString().padLeft(2, '0');
      return '$month $day $hh:$mm';
    }
    return '$month $day  ${t.year}';
  }
}

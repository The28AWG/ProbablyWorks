import 'dart:convert';
import 'dart:math' show max;
import 'dart:typed_data';

import 'package:probably_works/host/virtual/vfs_path.dart';
import 'package:probably_works/host/virtual/vfs_store.dart';
import 'package:probably_works/host/virtual/virtual_profile.dart';

/// Корни, которые целиком принадлежат снимку. Запись под ними отвергается до хранилища.
const osSnapshotRoots = ['/bin', '/usr', '/etc', '/proc', '/root'];

/// Режим каталога снимка: `0755`. Агент может войти и прочитать список, но не создать файл.
const _dirMode = 493;

/// Режим служебного файла: `0644`. Агент читает, владелец root мог бы писать.
const _textMode = 420;

/// Режим команды: `0711`. У владельца есть чтение, у агента — только выполнение.
const _execMode = 457;

/// Режим симлинка, как у остальных симлинков виртуальной ФС.
const _linkMode = 511;

/// Картинка памяти виртуальной машины: 256 МиБ. Процессы не учитываются, поэтому свободно столько же.
/// Это не оперативная память компьютера, где запущено приложение, и не дисковая квота.
const _memTotalKib = 256 * 1024;

/// Stateless-снимок системных каталогов одного Host.
///
/// Узлы не пишутся в базу и не входят в квоту. Имена команд берутся из реестра апплетов плюс `/bin/sh`:
/// оболочка запускает апплет по имени, а файл нужен, чтобы `ls` и `test -x` видели ту же команду.
/// Текст `/etc` и `/proc` считается в момент чтения из профиля и часов.
final class OsSnapshot {
  OsSnapshot({required this.profile, required Iterable<String> names})
    : commandNames = _commands(names);

  final VirtualProfile profile;

  /// Имена в `/bin` и `/usr/bin`, включая `sh`, по возрастанию.
  final List<String> commandNames;

  /// Путь лежит в зарезервированном корне. Совпадения по префиксу без слэша нет: `/binary` — не `/bin`.
  bool owns(String canonical) {
    for (final root in osSnapshotRoots) {
      if (canonical == root || canonical.startsWith('$root/')) return true;
    }
    return false;
  }

  /// Узел по каноническому пути. Нет такого имени внутри снимка — null, даже если путь в зарезервированном
  /// корне: база под этим корнем не подменяет снимок.
  VfsNode? node(String canonical, {required int now}) {
    if (!owns(canonical)) return null;
    for (final candidate in _all(now)) {
      if (candidate.path == canonical) return candidate;
    }
    return null;
  }

  /// Прямые потомки каталога снимка, отсортированные по пути.
  List<VfsNode> children(String dir, {required int now}) =>
      _sorted(_all(now).where((node) => node.parentPath == dir));

  /// Все потомки каталога на любой глубине, без самого каталога.
  List<VfsNode> descendants(String dir, {required int now}) {
    final prefix = dir == VfsPath.root ? '/' : '$dir/';
    return _sorted(
      _all(now)
          .where((node) => node.path != dir && node.path.startsWith(prefix)),
    );
  }

  /// Байты файла. Каталог, симлинк и команда без текста — пусто. Размер узла равен длине этих байтов.
  Uint8List content(String canonical, {required int now}) {
    final text = _text(canonical, now);
    if (text == null) return Uint8List(0);
    return Uint8List.fromList(utf8.encode(text));
  }

  static List<String> _commands(Iterable<String> names) {
    final unique = {...names, 'sh'};
    return unique.toList()..sort();
  }

  List<VfsNode> _all(int now) {
    final nodes = <VfsNode>[
      for (final path in const [
        '/bin',
        '/usr',
        '/usr/bin',
        '/usr/local',
        '/usr/local/bin',
        '/etc',
        '/proc',
        '/root',
      ])
        _dir(path),
      for (final name in commandNames) ...[
        _file('/bin/$name', mode: _execMode, size: 0),
        _link('/usr/bin/$name', '/bin/$name'),
      ],
    ];
    for (final path in const [
      '/etc/passwd',
      '/etc/group',
      '/etc/hostname',
      '/etc/os-release',
      '/proc/version',
      '/proc/uptime',
      '/proc/loadavg',
      '/proc/meminfo',
      '/proc/cpuinfo',
    ]) {
      final bytes = content(path, now: now);
      nodes.add(
        _file(
          path,
          mode: _textMode,
          size: bytes.length,
          mtime: path.startsWith('/proc/') ? now : profile.bootedAt,
        ),
      );
    }
    return nodes;
  }

  VfsNode _dir(String path) => VfsNode(
    path: path,
    kind: VfsNodeKind.dir,
    mode: _dirMode,
    mtime: profile.bootedAt,
    size: 0,
    uid: vfsRootUid,
    gid: vfsRootGid,
  );

  VfsNode _file(
    String path, {
    required int mode,
    required int size,
    int? mtime,
  }) => VfsNode(
    path: path,
    kind: VfsNodeKind.file,
    mode: mode,
    mtime: mtime ?? profile.bootedAt,
    size: size,
    uid: vfsRootUid,
    gid: vfsRootGid,
  );

  VfsNode _link(String path, String target) => VfsNode(
    path: path,
    kind: VfsNodeKind.symlink,
    mode: _linkMode,
    mtime: profile.bootedAt,
    size: 0,
    uid: vfsRootUid,
    gid: vfsRootGid,
    target: target,
  );

  /// Текст служебного файла. Команды и каталоги текста не имеют: их размер остаётся нулём.
  String? _text(String path, int now) {
    final user = profile.user;
    final home = profile.home;
    final shell = profile.shell;
    return switch (path) {
      '/etc/passwd' =>
        'root:x:0:0:root:/root:$shell\n'
            '$user:x:$vfsAgentUid:$vfsAgentGid:$user:$home:$shell\n',
      '/etc/group' =>
        'root:x:0:\n'
            '$user:x:$vfsAgentGid:\n',
      '/etc/hostname' => '${profile.hostname}\n',
      '/etc/os-release' =>
        'NAME="Probably"\n'
            'ID=probably\n'
            'VERSION="6.1.0-virtual"\n'
            'PRETTY_NAME="Probably Works virtual host"\n',
      '/proc/version' =>
        'Linux version 6.1.0-virtual (root@${profile.hostname}) '
            '#1 SMP x86_64 GNU/Linux\n',
      '/proc/uptime' => _uptime(now),
      '/proc/loadavg' => '0.00 0.00 0.00 1/1 1\n',
      '/proc/meminfo' =>
        'MemTotal:       $_memTotalKib kB\n'
            'MemFree:        $_memTotalKib kB\n'
            'MemAvailable:   $_memTotalKib kB\n'
            'Buffers:             0 kB\n'
            'Cached:              0 kB\n',
      '/proc/cpuinfo' =>
        'processor\t: 0\n'
            'vendor_id\t: Virtual\n'
            'model name\t: Virtual CPU\n'
            'cpu cores\t: 1\n',
      _ => null,
    };
  }

  /// Секунды с запуска и простой. Простой всегда ноль: нагрузки у виртуального Host нет.
  /// Ноль в [VirtualProfile.bootedAt] означает, что момент запуска неизвестен.
  String _uptime(int now) {
    final boot = profile.bootedAt;
    final elapsed = boot == 0 ? 0 : max(0, now - boot);
    return '$elapsed.00 0.00\n';
  }

  static List<VfsNode> _sorted(Iterable<VfsNode> nodes) =>
      nodes.toList()..sort((a, b) => a.path.compareTo(b.path));
}

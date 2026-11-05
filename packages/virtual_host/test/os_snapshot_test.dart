import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:virtual_host/src/in_memory_vfs_store.dart';
import 'package:virtual_host/src/os_snapshot.dart';
import 'package:virtual_host/src/shell/applets/standard_applets.dart';
import 'package:virtual_host/src/shell/shell_interpreter.dart';
import 'package:virtual_host/src/shell/shell_io.dart';
import 'package:virtual_host/src/vfs_store.dart';
import 'package:virtual_host/src/virtual_fs.dart';
import 'package:virtual_host/src/virtual_host_seeder.dart';
import 'package:virtual_host/src/virtual_profile.dart';

const _profile = VirtualProfile(hostname: 'box', bootedAt: 1700000000);

OsSnapshot _image() =>
    OsSnapshot(profile: _profile, names: standardApplets.names);

VirtualFs _layered({
  required VfsStore persisted,
  required VfsStore scratch,
  OsSnapshot? snapshot,
}) => VirtualFs(
  persisted,
  snapshot: snapshot ?? _image(),
  temporary: scratch,
  clock: () => 1700001000,
);

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

/// Хранилище, которое по флагу отказывает в записи. Нужно проверить откат `/tmp` вместе с базой.
final class _FailingStore implements VfsStore {
  _FailingStore(this.inner);

  final InMemoryVfsStore inner;
  var failPut = false;

  @override
  Future<VfsNode?> get(String path) => inner.get(path);

  @override
  Future<List<VfsNode>> children(String dir) => inner.children(dir);

  @override
  Future<List<VfsNode>> descendants(String dir) => inner.descendants(dir);

  @override
  Future<Uint8List?> content(String path) => inner.content(path);

  @override
  Future<void> put(VfsNode node, {Uint8List? content}) {
    if (failPut) throw const VfsException('disk');
    return inner.put(node, content: content);
  }

  @override
  Future<void> delete(String path) => inner.delete(path);

  @override
  Future<int> totalBytes() => inner.totalBytes();

  @override
  Future<T> transaction<T>(Future<T> Function() action) =>
      inner.transaction(action);
}

void main() {
  test('ls /bin показывает команды реестра и sh от root', () async {
    final fs = _layered(
      persisted: InMemoryVfsStore(),
      scratch: InMemoryVfsStore(),
    );
    final shell = ShellInterpreter(
      fs: fs,
      applets: standardApplets,
      profile: _profile,
    );

    final listed = await shell.run('ls /bin').toList();
    final names = utf8.decode(_stdout(listed)).split('\n');
    expect(names, containsAll(['ls', 'sh', 'cat']));

    final line = utf8.decode(
      _stdout(await shell.run('ls -l /bin/ls').toList()),
    );
    expect(line, contains('root'));
    expect(line, contains('-rwx--x--x'));
    expect((await fs.stat('/bin/ls'))?.size, 0);
  });

  test(
    'команду можно выполнить и нельзя прочитать или изменить каталог',
    () async {
      final fs = _layered(
        persisted: InMemoryVfsStore(),
        scratch: InMemoryVfsStore(),
      );
      final shell = ShellInterpreter(
        fs: fs,
        applets: standardApplets,
        profile: _profile,
      );

      expect(_code(await shell.run('[[ -x /bin/ls ]]').toList()), 0);
      expect(_code(await shell.run('[[ -r /bin/ls ]]').toList()), 1);
      expect(_code(await shell.run('[[ -w /bin ]]').toList()), 1);

      final denied = await shell.run('cat /bin/ls').toList();
      expect(utf8.decode(_stderr(denied)), contains('Permission denied'));
      expect(_code(denied), isNot(0));
    },
  );

  test('/etc и /proc читаются, снимок не пишется', () async {
    final fs = _layered(
      persisted: InMemoryVfsStore(),
      scratch: InMemoryVfsStore(),
    );
    final shell = ShellInterpreter(
      fs: fs,
      applets: standardApplets,
      profile: _profile,
    );

    expect(
      utf8.decode(_stdout(await shell.run('cat /etc/hostname').toList())),
      'box\n',
    );
    expect(
      utf8.decode(_stdout(await shell.run('cat /proc/uptime').toList())),
      '1000.00 0.00\n',
    );
    for (final command in [
      'rm /etc/hostname',
      'chmod 644 /etc/hostname',
      'mv /etc/hostname /tmp/hostname',
    ]) {
      final events = await shell.run(command).toList();
      expect(utf8.decode(_stderr(events)), contains('Read-only file system'));
      expect(_code(events), isNot(0));
    }
    expect(await fs.usedBytes(), 0);
  });

  test('/tmp живёт в памяти процесса и входит в квоту', () async {
    final persisted = InMemoryVfsStore();
    final scratch = InMemoryVfsStore();
    final fs = _layered(persisted: persisted, scratch: scratch);
    await seedVirtualHost(fs, _profile);
    await fs.writeBytes('/tmp/f', _bytes('x'));

    final again = _layered(persisted: persisted, scratch: scratch);
    expect(utf8.decode(await again.readBytes('/tmp/f')), 'x');
    expect(await VirtualFs(persisted).stat('/tmp/f'), isNull);
    expect(await fs.usedBytes(), 1);
    expect(await VirtualFs(persisted).usedBytes(), 0);

    final fresh = InMemoryVfsStore();
    final emptied = _layered(persisted: persisted, scratch: fresh);
    expect(await emptied.stat('/tmp/f'), isNull);
    expect((await emptied.stat('/tmp'))?.mode, vfsTmpMode);
  });

  test(
    'mv из /tmp в дом переносит файл, ошибка записи откатывает оба слоя',
    () async {
      final persisted = _FailingStore(InMemoryVfsStore());
      final scratch = InMemoryVfsStore();
      final fs = _layered(persisted: persisted, scratch: scratch);
      await seedVirtualHost(fs, _profile);
      await fs.writeBytes('/tmp/f', _bytes('hi'));
      await fs.rename('/tmp/f', '/home/agent/f');

      expect(await fs.stat('/tmp/f'), isNull);
      expect(
        utf8.decode(await VirtualFs(persisted).readBytes('/home/agent/f')),
        'hi',
      );

      await fs.writeBytes('/tmp/g', _bytes('go'));
      persisted.failPut = true;
      expect(
        () => fs.rename('/tmp/g', '/home/agent/g'),
        throwsA(isA<VfsException>()),
      );
      expect(utf8.decode(await fs.readBytes('/tmp/g')), 'go');
      expect(await VirtualFs(persisted).stat('/home/agent/g'), isNull);
    },
  );

  test('симлинк /usr/bin раскрывается в /bin', () async {
    final fs = _layered(
      persisted: InMemoryVfsStore(),
      scratch: InMemoryVfsStore(),
    );
    final link = await fs.stat('/usr/bin/cat', followLast: false);
    expect(link?.kind, VfsNodeKind.symlink);
    expect(link?.target, '/bin/cat');
    expect((await fs.stat('/usr/bin/cat'))?.path, '/bin/cat');
  });
}

List<int> _stdout(List<ShellEvent> events) => [
  for (final event in events)
    if (event is ShellStdout) ...event.bytes,
];

List<int> _stderr(List<ShellEvent> events) => [
  for (final event in events)
    if (event is ShellStderr) ...event.bytes,
];

int _code(List<ShellEvent> events) =>
    events.whereType<ShellDone>().last.exitCode ?? -1;

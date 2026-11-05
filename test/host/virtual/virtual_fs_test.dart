import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/data/host_repository.dart';
import 'package:probably_works/core/data/virtual_fs_repository.dart';
import 'package:probably_works/core/db/app_database.dart';
import 'package:probably_works/core/db/db_connection.dart';
import 'package:probably_works/host/virtual/in_memory_vfs_store.dart';
import 'package:probably_works/host/virtual/vfs_store.dart';
import 'package:probably_works/host/virtual/virtual_fs.dart';
import 'package:probably_works/host/virtual/virtual_limits.dart';

/// Ожидание ошибки POSIX с точным текстом: модель видит этот текст, поэтому он часть контракта.
Matcher _vfsError(String message) =>
    throwsA(isA<VfsException>().having((e) => e.message, 'message', message));

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

String _text(Uint8List bytes) => utf8.decode(bytes);

VirtualFs _fs(VfsStore store, {VirtualLimits limits = const VirtualLimits()}) =>
    VirtualFs(store, limits: limits, clock: () => 1700000000);

/// Одни и те же сценарии выполняются против памяти и против базы: правила живут в [VirtualFs],
/// поэтому результаты обязаны совпадать.
void _suite(Future<VfsStore> Function() openStore) {
  late VfsStore store;

  setUp(() async => store = await openStore());

  test('корень существует всегда и является каталогом', () async {
    final root = await _fs(store).stat('/');
    expect(root?.kind, VfsNodeKind.dir);
    expect(await _fs(store).stat('/missing'), isNull);
  });

  test('запись создаёт файл с правами 0644 и временем из часов', () async {
    final fs = _fs(store);
    await fs.writeBytes('/hello.txt', _bytes('hi'));

    final node = await fs.stat('/hello.txt');
    expect(node?.kind, VfsNodeKind.file);
    expect(node?.mode, 420);
    expect(node?.mtime, 1700000000);
    expect(node?.size, 2);
    expect(_text(await fs.readBytes('/hello.txt')), 'hi');
  });

  test('перезапись сохраняет права существующего файла', () async {
    final fs = _fs(store);
    await fs.writeBytes('/run.sh', _bytes('a'), mode: 493);
    await fs.writeBytes('/run.sh', _bytes('bb'));

    final node = await fs.stat('/run.sh');
    expect(node?.mode, 493);
    expect(_text(await fs.readBytes('/run.sh')), 'bb');
  });

  test(
    'запись в несуществующий каталог и в файл как в каталог — разные ошибки',
    () async {
      final fs = _fs(store);
      await fs.writeBytes('/f', _bytes('x'));
      await expectLater(
        fs.writeBytes('/no/such', _bytes('x')),
        _vfsError('No such file or directory'),
      );
      await expectLater(
        fs.writeBytes('/f/child', _bytes('x')),
        _vfsError('Not a directory'),
      );
    },
  );

  test('чтение каталога и отсутствующего пути — ошибки POSIX', () async {
    final fs = _fs(store);
    await fs.mkdir('/d');
    await expectLater(fs.readBytes('/d'), _vfsError('Is a directory'));
    await expectLater(
      fs.readBytes('/none'),
      _vfsError('No such file or directory'),
    );
  });

  test(
    'относительный путь разрешается от cwd, а `..` не выходит за корень',
    () async {
      final fs = _fs(store);
      await fs.mkdir('/work/src', recursive: true);
      await fs.writeBytes('a.txt', _bytes('A'), cwd: '/work/src');

      expect(_text(await fs.readBytes('src/a.txt', cwd: '/work')), 'A');
      expect(
        _text(await fs.readBytes('../../../work/src/a.txt', cwd: '/work/src')),
        'A',
      );
    },
  );

  test('list возвращает прямых потомков по возрастанию пути', () async {
    final fs = _fs(store);
    await fs.mkdir('/d/sub', recursive: true);
    await fs.writeBytes('/d/b.txt', _bytes('b'));
    await fs.writeBytes('/d/a.txt', _bytes('a'));

    final names = (await fs.list('/d')).map((n) => n.name).toList();
    expect(names, ['a.txt', 'b.txt', 'sub']);
    await expectLater(fs.list('/d/a.txt'), _vfsError('Not a directory'));
  });

  test(
    'walk отдаёт поддерево и не захватывает соседей с общим префиксом',
    () async {
      final fs = _fs(store);
      await fs.mkdir('/a/inner', recursive: true);
      await fs.writeBytes('/a/inner/x', _bytes('x'));
      await fs.writeBytes('/ab', _bytes('other'));

      final paths = (await fs.walk('/a')).map((n) => n.path).toList();
      expect(paths, ['/a/inner', '/a/inner/x']);
      final all = (await fs.walk('/')).map((n) => n.path).toList();
      expect(all, containsAll(['/a', '/ab', '/a/inner/x']));
    },
  );

  test('mkdir без recursive падает на существующем пути', () async {
    final fs = _fs(store);
    await fs.mkdir('/d');
    await expectLater(fs.mkdir('/d'), _vfsError('File exists'));
  });

  test('mkdir -p создаёт предков и не падает на существующих', () async {
    final fs = _fs(store);
    await fs.mkdir('/x/y/z', recursive: true);
    await fs.mkdir('/x/y/z', recursive: true);
    expect((await fs.stat('/x/y/z'))?.kind, VfsNodeKind.dir);
  });

  test('mkdir -p поверх файла даёт File exists', () async {
    final fs = _fs(store);
    await fs.writeBytes('/f', _bytes('x'));
    await expectLater(
      fs.mkdir('/f/x', recursive: true),
      _vfsError('File exists'),
    );
  });

  test('transaction откатывает все изменения при исключении', () async {
    final node = VfsNode(
      path: '/t',
      kind: VfsNodeKind.file,
      mode: 420,
      mtime: 1,
      size: 1,
    );
    await expectLater(
      store.transaction<void>(() async {
        await store.put(node, content: Uint8List.fromList([1]));
        throw StateError('boom');
      }),
      throwsStateError,
    );
    expect(await store.get('/t'), isNull);
    expect(await store.content('/t'), isNull);
  });

  test('remove удаляет файл, каталог без recursive не удаляет', () async {
    final fs = _fs(store);
    await fs.writeBytes('/f', _bytes('x'));
    await fs.mkdir('/d/e', recursive: true);

    await expectLater(fs.remove('/d'), _vfsError('Is a directory'));
    await fs.remove('/f');
    expect(await fs.stat('/f'), isNull);
    await fs.remove('/d', recursive: true);
    expect(await fs.stat('/d/e'), isNull);
    expect(await fs.stat('/d'), isNull);
  });

  test('корень нельзя переместить и скопировать', () async {
    final fs = _fs(store);
    await fs.writeBytes('/x', _bytes('x'));
    await expectLater(
      fs.rename('/', '/r'),
      _vfsError('Operation not permitted'),
    );
    await expectLater(
      fs.copy('/', '/r', recursive: true),
      _vfsError('Operation not permitted'),
    );
    expect(_text(await fs.readBytes('/x')), 'x');
  });

  test('корень нельзя удалить и нельзя удалить несуществующее', () async {
    final fs = _fs(store);
    await expectLater(
      fs.remove('/', recursive: true),
      _vfsError('Operation not permitted'),
    );
    await expectLater(
      fs.remove('/none'),
      _vfsError('No such file or directory'),
    );
  });

  test('rename переносит файл и заменяет существующий файл', () async {
    final fs = _fs(store);
    await fs.writeBytes('/a', _bytes('A'));
    await fs.writeBytes('/b', _bytes('B'));
    await fs.rename('/a', '/b');

    expect(await fs.stat('/a'), isNull);
    expect(_text(await fs.readBytes('/b')), 'A');
  });

  test(
    'rename каталога переносит потомков и запрещает перенос в себя',
    () async {
      final fs = _fs(store);
      await fs.mkdir('/src/deep', recursive: true);
      await fs.writeBytes('/src/deep/f', _bytes('deep'));
      await fs.rename('/src', '/dst');

      expect(_text(await fs.readBytes('/dst/deep/f')), 'deep');
      expect(await fs.stat('/src'), isNull);
      await expectLater(
        fs.rename('/dst', '/dst/inside'),
        _vfsError('Invalid argument'),
      );
    },
  );

  test(
    'rename файла поверх каталога и каталога поверх файла — ошибки',
    () async {
      final fs = _fs(store);
      await fs.mkdir('/d');
      await fs.writeBytes('/f', _bytes('x'));
      await expectLater(fs.rename('/f', '/d'), _vfsError('Is a directory'));
      await expectLater(fs.rename('/d', '/f'), _vfsError('Not a directory'));
    },
  );

  test('каталог заменяет только пустой каталог', () async {
    final fs = _fs(store);
    await fs.mkdir('/src');
    await fs.mkdir('/busy/inner', recursive: true);
    await fs.mkdir('/empty');
    await expectLater(
      fs.rename('/src', '/busy'),
      _vfsError('Directory not empty'),
    );
    await fs.rename('/src', '/empty');
    expect(await fs.stat('/src'), isNull);
    expect((await fs.stat('/empty'))?.kind, VfsNodeKind.dir);
  });

  test(
    'copy файла дублирует содержимое, copy каталога без recursive запрещён',
    () async {
      final fs = _fs(store);
      await fs.writeBytes('/f', _bytes('x'));
      await fs.copy('/f', '/g');
      expect(_text(await fs.readBytes('/g')), 'x');

      await fs.mkdir('/d/e', recursive: true);
      await expectLater(
        fs.copy('/d', '/d2'),
        _vfsError('-r not specified; omitting directory'),
      );
      await fs.copy('/d', '/d2', recursive: true);
      expect((await fs.stat('/d2/e'))?.kind, VfsNodeKind.dir);
    },
  );

  test('copy сохраняет симлинки внутри каталога как симлинки', () async {
    final fs = _fs(store);
    await fs.mkdir('/d');
    await fs.writeBytes('/t', _bytes('t'));
    await fs.symlink('/t', '/d/link');
    await fs.copy('/d', '/d2', recursive: true);

    final link = await fs.stat('/d2/link', followLast: false);
    expect(link?.kind, VfsNodeKind.symlink);
    expect(link?.target, '/t');
  });

  test(
    'симлинк прозрачен для чтения и записи, цикл даёт ELOOP-подобную ошибку',
    () async {
      final fs = _fs(store);
      await fs.writeBytes('/real', _bytes('old'));
      await fs.symlink('/real', '/link');

      expect(_text(await fs.readBytes('/link')), 'old');
      await fs.writeBytes('/link', _bytes('new'));
      expect(_text(await fs.readBytes('/real')), 'new');

      await fs.symlink('/loop2', '/loop1');
      await fs.symlink('/loop1', '/loop2');
      await expectLater(
        fs.readBytes('/loop1'),
        _vfsError('Too many levels of symbolic links'),
      );
    },
  );

  test(
    'висячий симлинк: stat с разворачиванием — null, lstat — сам симлинк',
    () async {
      final fs = _fs(store);
      await fs.symlink('/none', '/dangle');

      expect(await fs.stat('/dangle'), isNull);
      final link = await fs.stat('/dangle', followLast: false);
      expect(link?.kind, VfsNodeKind.symlink);
      expect(link?.target, '/none');
    },
  );

  test('симлинк в середине пути раскрывается, даже если последний компонент не раскрывается', () async {
    final fs = _fs(store);
    await fs.mkdir('/real/dir', recursive: true);
    await fs.writeBytes('/real/dir/f', _bytes('ok'));
    await fs.symlink('/real', '/alias');

    expect(_text(await fs.readBytes('/alias/dir/f')), 'ok');
    expect((await fs.list('/alias/dir')).single.name, 'f');
  });

  test('chmod меняет права и не трогает содержимое', () async {
    final fs = _fs(store);
    await fs.writeBytes('/f', _bytes('keep'));
    await fs.chmod('/f', 384); // 0600

    expect((await fs.stat('/f'))?.mode, 384);
    expect(_text(await fs.readBytes('/f')), 'keep');
  });

  test('размер файла сверх maxFileBytes отклоняется', () async {
    final fs = _fs(store, limits: const VirtualLimits(maxFileBytes: 3));
    await fs.writeBytes('/ok', _bytes('abc'));
    await expectLater(
      fs.writeBytes('/big', _bytes('abcd')),
      _vfsError('File too large for the virtual host'),
    );
  });

  test('квота считает сумму файлов и учитывает перезапись', () async {
    final fs = _fs(store, limits: const VirtualLimits(quotaBytes: 10));
    await fs.writeBytes('/a', _bytes('123456'));
    await expectLater(
      fs.writeBytes('/b', _bytes('12345')),
      _vfsError('No space left on device'),
    );
    await fs.writeBytes('/a', _bytes('1234567890'));
    expect(await fs.usedBytes(), 10);
  });

  test('copy проверяет квоту до записи', () async {
    final fs = _fs(store, limits: const VirtualLimits(quotaBytes: 5));
    await fs.writeBytes('/a', _bytes('abc'));
    await fs.mkdir('/d');
    await expectLater(
      fs.copy('/a', '/d/b'),
      _vfsError('No space left on device'),
    );
    expect(await fs.stat('/d/b'), isNull);
  });
}

void main() {
  group('InMemoryVfsStore', () => _suite(() async => InMemoryVfsStore()));

  group('VirtualFsRepository', () {
    late AppDatabase db;

    setUp(() async {
      db = openInMemoryDatabase();
      await HostRepository(db).ensureLocalHost(DateTime(2026, 11, 1));
    });

    tearDown(() => db.close());

    _suite(() async => VirtualFsRepository(db, HostRepository.localHostId));
  });
}

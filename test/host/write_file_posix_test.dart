import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/host/host_runtime.dart';
import 'package:pw_agent/host/local_host_runtime.dart';
import 'package:pw_agent/host/shell_adapter.dart';

const _sh = ShellAdapter(HostOs.posix);
final _runtime = LocalHostRuntime(os: HostOs.posix);

typedef _Result = ({int? code, String stdout, String stderr});

/// Запускает команду через настоящий LocalHostRuntime (с обёрткой, как в приложении), со stdin.
Future<_Result> _run(String command, {Uint8List? stdin}) async {
  final out = StringBuffer();
  final err = StringBuffer();
  int? code;
  await for (final event in _runtime.run(command, stdin: stdin)) {
    switch (event) {
      case ExecStarted():
        break;
      case ExecStdout e:
        out.write(utf8.decode(e.bytes));
      case ExecStderr e:
        err.write(utf8.decode(e.bytes));
      case ExecDone e:
        code = e.exitCode;
    }
  }
  return (code: code, stdout: out.toString(), stderr: err.toString());
}

Future<String> _mtime(String path) async =>
    (await _run(_sh.statMtime(path))).stdout.trim();

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pw_write_');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  String p(String name) => '${dir.path}/$name';

  test(
    'новый файл: содержимое приходит со stdin, без предела по размеру',
    () async {
      final payload = utf8.encode('привет мир\n' * 200000); // около 2.4 МБ
      final result = await _run(
        _sh.writeFile(p('big.txt'), backupPath: p('big.txt.bak')),
        stdin: Uint8List.fromList(payload),
      );
      expect(result.code, 0, reason: result.stderr);
      expect(File(p('big.txt')).readAsBytesSync(), payload);
      expect(File(p('big.txt.bak')).existsSync(), isFalse);
    },
  );

  test('создаёт недостающие каталоги', () async {
    final result = await _run(
      _sh.writeFile(p('a/b/c.txt'), backupPath: p('a/b/c.txt.bak')),
      stdin: Uint8List.fromList(utf8.encode('x')),
    );
    expect(result.code, 0, reason: result.stderr);
    expect(File(p('a/b/c.txt')).readAsStringSync(), 'x');
  });

  test(
    'перезапись при совпадающем mtime: старая версия уходит в бэкап',
    () async {
      final file = File(p('f.txt'))..writeAsStringSync('old');
      final expected = await _mtime(file.path);
      final result = await _run(
        _sh.writeFile(
          file.path,
          backupPath: p('f.txt.bak'),
          expectedMtime: expected,
        ),
        stdin: Uint8List.fromList(utf8.encode('new')),
      );
      expect(result.code, 0, reason: result.stderr);
      expect(file.readAsStringSync(), 'new');
      expect(File(p('f.txt.bak')).readAsStringSync(), 'old');
    },
  );

  test(
    'файл изменился после чтения: запись отказана, файл не тронут',
    () async {
      final file = File(p('g.txt'))..writeAsStringSync('mine');
      final expected = await _mtime(file.path);
      // Имитируем правку пользователя во время подтверждения: mtime уже другой.
      file.setLastModifiedSync(DateTime(2001));
      final result = await _run(
        _sh.writeFile(
          file.path,
          backupPath: p('g.txt.bak'),
          expectedMtime: expected,
        ),
        stdin: Uint8List.fromList(utf8.encode('agent')),
      );
      expect(result.code, isNot(0));
      expect(result.stderr, contains('changed after it was read'));
      expect(file.readAsStringSync(), 'mine');
      expect(File(p('g.txt.bak')).existsSync(), isFalse);
    },
  );

  test('ожидался отсутствующий файл, а он появился: запись отказана', () async {
    final file = File(p('h.txt'))..writeAsStringSync('appeared');
    final result = await _run(
      _sh.writeFile(file.path, backupPath: p('h.txt.bak')),
      stdin: Uint8List.fromList(utf8.encode('agent')),
    );
    expect(result.code, isNot(0));
    expect(result.stderr, contains('appeared'));
    expect(file.readAsStringSync(), 'appeared');
  });

  test('бэкап не создался: запись не выполняется (раньше файл перезаписывался молча)', () async {
    final file = File(p('i.txt'))..writeAsStringSync('keep me');
    final expected = await _mtime(file.path);
    final result = await _run(
      _sh.writeFile(
        file.path,
        backupPath: p('missing-dir/i.txt.bak'),
        expectedMtime: expected,
      ),
      stdin: Uint8List.fromList(utf8.encode('agent')),
    );
    expect(result.code, isNot(0));
    expect(result.stderr, contains('backup failed'));
    expect(file.readAsStringSync(), 'keep me');
  });

  test('замена атомарна: новый inode, временных файлов не остаётся', () async {
    final file = File(p('a.txt'))..writeAsStringSync('old');
    final inodeBefore = _inode(file.path);
    final expected = await _mtime(file.path);
    final result = await _run(
      _sh.writeFile(
        file.path,
        backupPath: p('a.txt.bak'),
        expectedMtime: expected,
      ),
      stdin: Uint8List.fromList(utf8.encode('new')),
    );
    expect(result.code, 0, reason: result.stderr);
    expect(file.readAsStringSync(), 'new');
    expect(_inode(file.path), isNot(inodeBefore));
    expect(_leftovers(dir), isEmpty);
  });

  test(
    'симлинк: запись идёт в цель, ссылка остаётся, бэкап берётся с цели',
    () async {
      final real = File(p('real.txt'))..writeAsStringSync('old');
      Link(p('link.txt')).createSync(real.path);
      final expected = await _mtime(p('link.txt'));
      final result = await _run(
        _sh.writeFile(
          p('link.txt'),
          backupPath: p('link.txt.bak'),
          expectedMtime: expected,
        ),
        stdin: Uint8List.fromList(utf8.encode('new')),
      );
      expect(result.code, 0, reason: result.stderr);
      expect(FileSystemEntity.isLinkSync(p('link.txt')), isTrue);
      expect(real.readAsStringSync(), 'new');
      expect(File(p('link.txt.bak')).readAsStringSync(), 'old');
      expect(_leftovers(dir), isEmpty);
    },
  );

  test('права файла сохраняются после атомарной замены', () async {
    final file = File(p('m.txt'))..writeAsStringSync('old');
    expect((await Process.run('chmod', ['640', file.path])).exitCode, 0);
    final expected = await _mtime(file.path);
    final result = await _run(
      _sh.writeFile(
        file.path,
        backupPath: p('m.txt.bak'),
        expectedMtime: expected,
      ),
      stdin: Uint8List.fromList(utf8.encode('new')),
    );
    expect(result.code, 0, reason: result.stderr);
    final mode = await Process.run('stat', ['-c', '%a', file.path]);
    expect(mode.stdout.toString().trim(), '640');
  });

  test('жёсткая ссылка: запись отказана, файл и ссылка не тронуты', () async {
    final file = File(p('hl.txt'))..writeAsStringSync('keep');
    expect((await Process.run('ln', [file.path, p('hl2.txt')])).exitCode, 0);
    final expected = await _mtime(file.path);
    final result = await _run(
      _sh.writeFile(
        file.path,
        backupPath: p('hl.txt.bak'),
        expectedMtime: expected,
      ),
      stdin: Uint8List.fromList(utf8.encode('agent')),
    );
    expect(result.code, isNot(0));
    expect(result.stderr, contains('hard links'));
    expect(file.readAsStringSync(), 'keep');
    expect(File(p('hl2.txt')).readAsStringSync(), 'keep');
    expect(_leftovers(dir), isEmpty);
  });

  test('файл только для чтения: запись отказана (атомарная замена не обходит права)', () async {
    final file = File(p('ro.txt'))..writeAsStringSync('locked');
    expect((await Process.run('chmod', ['444', file.path])).exitCode, 0);
    final expected = await _mtime(file.path);
    final result = await _run(
      _sh.writeFile(
        file.path,
        backupPath: p('ro.txt.bak'),
        expectedMtime: expected,
      ),
      stdin: Uint8List.fromList(utf8.encode('agent')),
    );
    expect(result.code, isNot(0));
    expect(result.stderr, contains('not writable'));
    expect(file.readAsStringSync(), 'locked');
    expect(_leftovers(dir), isEmpty);
    expect(File(p('ro.txt.bak')).existsSync(), isFalse);
  });

  test('сбой mv: исходный файл не тронут, временный файл удалён', () async {
    final file = File(p('mv.txt'))..writeAsStringSync('keep');
    final expected = await _mtime(file.path);
    final fakeBin = Directory(p('bin'))..createSync();
    final fakeMv = File(p('bin/mv'))..writeAsStringSync('#!/bin/sh\nexit 1\n');
    expect((await Process.run('chmod', ['755', fakeMv.path])).exitCode, 0);
    final script = _sh.writeFile(
      file.path,
      backupPath: p('mv.txt.bak'),
      expectedMtime: expected,
    );
    final result = await _run(
      'export PATH="${fakeBin.path}:\$PATH"; $script',
      stdin: Uint8List.fromList(utf8.encode('agent')),
    );
    expect(result.code, isNot(0));
    expect(result.stderr, contains('cannot replace the file'));
    expect(file.readAsStringSync(), 'keep');
    expect(_leftovers(dir), isEmpty);
  });

  test(
    'каталог без права записи: временный файл не создаётся, цель не тронута',
    () async {
      final file = File(p('sub/f.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('keep');
      final expected = await _mtime(file.path);
      expect((await Process.run('chmod', ['555', p('sub')])).exitCode, 0);
      try {
        final result = await _run(
          _sh.writeFile(
            file.path,
            backupPath: p('sub/f.txt.bak'),
            expectedMtime: expected,
          ),
          stdin: Uint8List.fromList(utf8.encode('agent')),
        );
        expect(result.code, isNot(0));
        expect(result.stderr, contains('nothing was written'));
        expect(file.readAsStringSync(), 'keep');
        expect(File(p('sub/f.txt.bak')).existsSync(), isFalse);
      } finally {
        await Process.run('chmod', ['755', p('sub')]);
      }
    },
  );
}

String _inode(String path) =>
    Process.runSync('stat', ['-c', '%i', path]).stdout.toString().trim();

/// Временные файлы записи, оставшиеся в каталоге (должны удаляться всегда).
List<String> _leftovers(Directory dir) => [
  for (final e in dir.listSync())
    if (e.path.contains('.pw-tmp.')) e.path,
];

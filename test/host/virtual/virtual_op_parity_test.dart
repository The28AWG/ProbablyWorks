import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/host/host_capture.dart';
import 'package:probably_works/host/host_op.dart';
import 'package:probably_works/host/local_host_runtime.dart';
import 'package:probably_works/host/virtual/virtual_op_executor.dart';
import 'package:virtual_host/virtual_host.dart';

/// Паритет виртуального исполнителя с реальным POSIX-скриптом [LocalHostRuntime] на Linux.
///
/// Одни и те же файлы кладутся в настоящий временный каталог и в виртуальную ФС под тем же абсолютным
/// путём. Каждая операция выполняется в обоих местах, а код выхода и вывод сравниваются. Так проверяется
/// то, что инструменты реально разбирают: текст, а не внутренняя модель.
///
/// Пропускается вне Linux: скрипты рассчитаны на POSIX-утилиты (awk, cmp, stat -c).
void main() {
  final skip = Platform.isLinux ? false : 'паритет проверяется только на Linux';

  group('паритет с POSIX-скриптами', () {
    late Directory temp;
    late String base;
    late LocalHostRuntime real;
    late VirtualFs fs;
    late VirtualOpExecutor virtual;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('pw_parity');
      base = temp.resolveSymbolicLinksSync();
      real = LocalHostRuntime(os: HostOs.posix);
      fs = VirtualFs(InMemoryVfsStore(), clock: () => 1700000000);
      virtual = VirtualOpExecutor(fs, const VirtualProfile());
    });

    tearDown(() => temp.deleteSync(recursive: true));

    /// Пишет файл и в реальную ФС, и в виртуальную. Mtime реального файла приводится к [_mtime].
    Future<void> file(String relative, List<int> bytes) async {
      final realFile = File('$base/$relative')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes)
        ..setLastModifiedSync(
          DateTime.fromMillisecondsSinceEpoch(_mtime * 1000, isUtc: true),
        );
      await fs.mkdir(realFile.parent.path, recursive: true);
      await fs.writeBytes('$base/$relative', Uint8List.fromList(bytes));
    }

    /// Сравнивает результат реальной команды и виртуальной по коду выхода и обоим потокам.
    /// Возвращает описание расхождения или null, если результаты совпали.
    Future<String?> parityMismatch(
      HostOp op, {
      Uint8List? stdin,
      bool compareStderr = true,
      bool sortLines = false,
    }) async {
      final actual = await captureOp(real, op, cwd: base, stdin: stdin);
      final expected = await virtual.execute(op, cwd: base, stdin: stdin);
      final expectedOut = utf8.decode(expected.stdout, allowMalformed: true);
      final expectedErr = utf8.decode(expected.stderr, allowMalformed: true);
      final differences = [
        if (expected.exitCode != actual.exitCode)
          'код выхода: виртуальный ${expected.exitCode}, реальный ${actual.exitCode}',
        if (sortLines
            ? _sorted(expectedOut) != _sorted(actual.stdout)
            : expectedOut != actual.stdout)
          'вывод: виртуальный «$expectedOut», реальный «${actual.stdout}»',
        if (compareStderr && expectedErr != actual.stderr)
          'stderr: виртуальный «$expectedErr», реальный «${actual.stderr}»',
      ];
      if (differences.isEmpty) return null;
      return '${op.label}: ${differences.join('; ')}';
    }

    test('stat файла, каталога и отсутствующего пути', () async {
      await file('s/f.txt', [1, 2, 3]);
      // Создание файла меняет mtime каталога, поэтому фиксируем его отдельно.
      await Process.run('touch', ['-d', '@$_mtime', '$base/s']);
      expect(await parityMismatch(StatOp('$base/s/f.txt')), isNull);
      expect(await parityMismatch(StatOp('$base/s')), isNull);
      expect(await parityMismatch(StatOp('$base/none')), isNull);
    });

    test('firstFile возвращает первый файл из списка по порядку', () async {
      await file('ff/b.txt', [1]);
      await file('ff/c.txt', [1]);
      expect(
        await parityMismatch(
          FirstFileOp([
            '$base/ff',
            '$base/ff/none',
            '$base/ff/b.txt',
            '$base/ff/c.txt',
          ]),
        ),
        isNull,
      );
      expect(
        await parityMismatch(FirstFileOp(['$base/ff', '$base/ff/none'])),
        isNull,
      );
    });

    test('ls -la: список записей совпадает, тип и имя', () async {
      await file('ls/a.txt', [1]);
      await file('ls/dir/inner.txt', [1, 2]);
      final actual = await captureOp(real, ListDirOp('$base/ls'), cwd: base);
      final expected = await virtual.execute(ListDirOp('$base/ls'), cwd: base);
      expect(expected.exitCode, actual.exitCode);
      expect(
        _lsSignature(utf8.decode(expected.stdout)),
        _lsSignature(actual.stdout),
      );
      final missing = await virtual.execute(ListDirOp('$base/none'), cwd: base);
      expect(missing.exitCode, 2);
    });

    group('read_file', () {
      setUp(() async {
        await file(
          'rf/plain.txt',
          utf8.encode('line one\nline two\nhéllo wörld\n'),
        );
        await file('rf/noeol.txt', utf8.encode('a\nb'));
        await file('rf/empty.txt', const []);
        await file('rf/long.txt', utf8.encode('${'ж' * 20}\nshort\n'));
        await file('rf/bin.dat', [0x41, 0, 0x42, 0x0a]);
      });

      ReadFileOp read(
        String name, {
        int offset = 1,
        int byteOffset = 0,
        int limit = 2000,
        int chunkBytes = 60000,
        int lineBytes = 2000,
      }) => ReadFileOp(
        '$base/rf/$name',
        offset: offset,
        byteOffset: byteOffset,
        limit: limit,
        chunkBytes: chunkBytes,
        lineBytes: lineBytes,
      );

      // Операции строятся внутри теста: [base] задаётся в setUp, а не при описании группы.
      final cases = <(String, ReadFileOp Function())>[
        ('весь файл', () => read('plain.txt')),
        ('файл без перевода строки', () => read('noeol.txt')),
        ('пустой файл', () => read('empty.txt')),
        ('смещение за концом', () => read('plain.txt', offset: 99)),
        ('лимит строк', () => read('plain.txt', limit: 1)),
        ('лимит байтов', () => read('plain.txt', chunkBytes: 10)),
        ('строка режется по lineBytes', () => read('long.txt', lineBytes: 7)),
        (
          'резка внутри многобайтового символа',
          () => read('long.txt', lineBytes: 5),
        ),
        (
          'продолжение с byte_offset',
          () => read('long.txt', byteOffset: 8, lineBytes: 7),
        ),
        (
          'продолжение с середины строки и смещения',
          () => read('long.txt', offset: 1, byteOffset: 30),
        ),
      ];
      for (final (title, op) in cases) {
        test(title, () async => expect(await parityMismatch(op()), isNull));
      }

      test(
        'бинарный файл: одинаковая ошибка',
        () async => expect(await parityMismatch(read('bin.dat')), isNull),
      );
      test(
        'отсутствующий файл: одинаковая ошибка',
        () async => expect(await parityMismatch(read('none.txt')), isNull),
      );
      test(
        'каталог вместо файла: одинаковая ошибка',
        () async => expect(await parityMismatch(read('')), isNull),
      );
    });

    test(
      'cat (ReadRawOp) и head -c (ReadHeadOp) совпадают с реальными',
      () async {
        await file('raw/a.txt', utf8.encode('hello world\n'));
        expect(
          await parityMismatch(
            ReadRawOp('$base/raw/a.txt'),
            compareStderr: false,
          ),
          isNull,
        );
        expect(
          await parityMismatch(
            ReadRawOp('$base/raw/none'),
            compareStderr: false,
          ),
          isNull,
        );
        expect(
          await parityMismatch(
            ReadHeadOp('$base/raw/a.txt', maxBytes: 5),
            compareStderr: false,
          ),
          isNull,
        );
        expect(
          await parityMismatch(
            ReadHeadOp('$base/raw/none', maxBytes: 5),
            compareStderr: false,
          ),
          isNull,
        );
      },
    );

    test('scan skills: порядок, скрытые каталоги и код выхода', () async {
      await file('sk/dir/beta/SKILL.md', utf8.encode('beta body'));
      await file(
        'sk/dir/alpha/SKILL.md',
        utf8.encode('alpha body that is long'),
      );
      await file('sk/dir/.hidden/SKILL.md', utf8.encode('hidden'));
      await file('sk/dir/plain.txt', utf8.encode('not a skill'));
      expect(
        await parityMismatch(ScanSkillsOp(['$base/sk/dir'], maxBytes: 10)),
        isNull,
      );
      expect(
        await parityMismatch(ScanSkillsOp(['$base/sk/missing'], maxBytes: 10)),
        isNull,
      );
      expect(
        await parityMismatch(
          ScanSkillsOp(['$base/sk/dir', '$base/sk/missing'], maxBytes: 10),
        ),
        isNull,
      );
    });

    group('grep', () {
      setUp(() async {
        await file('g/one.txt', utf8.encode('foo bar\nbaz\nfoo\n'));
        await file('g/sub/two.txt', utf8.encode('nothing\nfoo!\nx{2}\n'));
        await file('g/.git/config', utf8.encode('foo in git'));
        await file('g/bin.dat', [0x66, 0x6f, 0x6f, 0, 0x0a]);
      });

      for (final pattern in [
        'foo',
        'fo\\|ba',
        '^b',
        'x{2}',
        'o\\{2\\}',
        '[[:digit:]]',
        'ba.',
      ]) {
        test('каталог, шаблон «$pattern»', () async {
          expect(
            await parityMismatch(GrepOp(pattern, '$base/g'), sortLines: true),
            isNull,
          );
        });
      }

      test('одиночный файл печатается без имени', () async {
        expect(await parityMismatch(GrepOp('foo', '$base/g/one.txt')), isNull);
      });

      test('отсутствующий путь: одинаковый stderr и код', () async {
        expect(await parityMismatch(GrepOp('foo', '$base/none')), isNull);
      });
    });

    group('write_file', () {
      WriteFileOp write(String name, {String? expectedMtime, String? backup}) =>
          WriteFileOp(
            '$base/w/$name',
            backupPath: backup ?? '$base/w/$name.pw-bak',
            expectedMtime: expectedMtime,
          );

      test('новый файл создаётся вместе с каталогами', () async {
        final bytes = Uint8List.fromList(utf8.encode('created\n'));
        expect(
          await parityMismatch(write('deep/new.txt'), stdin: bytes),
          isNull,
        );
        expect(File('$base/w/deep/new.txt').readAsStringSync(), 'created\n');
        expect(
          utf8.decode(await fs.readBytes('$base/w/deep/new.txt')),
          'created\n',
        );
      });

      test('перезапись при совпадении mtime делает backup', () async {
        await file('w/a.txt', utf8.encode('old'));
        final bytes = Uint8List.fromList(utf8.encode('new'));
        expect(
          await parityMismatch(
            write('a.txt', expectedMtime: '$_mtime'),
            stdin: bytes,
          ),
          isNull,
        );
        expect(File('$base/w/a.txt').readAsStringSync(), 'new');
        expect(File('$base/w/a.txt.pw-bak').readAsStringSync(), 'old');
        expect(utf8.decode(await fs.readBytes('$base/w/a.txt.pw-bak')), 'old');
      });

      test('файл изменился после чтения: запись отклоняется', () async {
        await file('w/b.txt', utf8.encode('keep'));
        expect(
          await parityMismatch(
            write('b.txt', expectedMtime: '${_mtime - 1}'),
            stdin: Uint8List.fromList(utf8.encode('lost')),
          ),
          isNull,
        );
        expect(File('$base/w/b.txt').readAsStringSync(), 'keep');
      });

      test('файл появился, а ожидали отсутствие: запись отклоняется', () async {
        await file('w/c.txt', utf8.encode('here'));
        expect(
          await parityMismatch(
            write('c.txt'),
            stdin: Uint8List.fromList(utf8.encode('lost')),
          ),
          isNull,
        );
      });

      test('файл без права записи: запись отклоняется', () async {
        await file('w/ro.txt', utf8.encode('ro'));
        await Process.run('chmod', ['444', '$base/w/ro.txt']);
        await fs.chmod('$base/w/ro.txt', 292); // 0444
        expect(
          await parityMismatch(
            write('ro.txt', expectedMtime: '$_mtime'),
            stdin: Uint8List.fromList(utf8.encode('x')),
          ),
          isNull,
        );
        expect(File('$base/w/ro.txt').readAsStringSync(), 'ro');
      });
    });
  }, skip: skip);

  test(
    'виртуальный исполнитель: which отдаёт только известные апплеты',
    () async {
      final fs = VirtualFs(InMemoryVfsStore(), clock: () => 1700000000);
      final executor = VirtualOpExecutor(
        fs,
        const VirtualProfile(),
        commands: {'echo'},
      );
      final found = await executor.execute(const WhichOp('echo'));
      expect(utf8.decode(found.stdout), '/bin/echo\n');
      final missing = await executor.execute(const WhichOp('nope'));
      expect(missing.exitCode, 1);
      expect(missing.stdout, isEmpty);
    },
  );
}

/// Общий mtime фикстур в секундах Unix. Совпадает с часами [VirtualFs] в тестах.
const _mtime = 1700000000;

/// Отсортированные непустые строки: для поиска по каталогу, где порядок обхода не задан.
String _sorted(String text) {
  final lines = text.split('\n')..removeWhere((line) => line.isEmpty);
  return (lines..sort()).join('\n');
}

/// Сигнатура `ls -la`: тип записи и имя для каждой строки, без `total`, прав, дат и владельцев.
List<String> _lsSignature(String text) {
  final rows = <String>[];
  for (final line in text.split('\n')) {
    if (line.isEmpty || line.startsWith('total')) continue;
    final parts = line.split(RegExp(r'\s+'));
    rows.add('${parts.first[0]} ${parts.last}');
  }
  rows.sort();
  return rows;
}

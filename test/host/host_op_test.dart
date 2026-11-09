import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/host/host_capture.dart';
import 'package:probably_works/host/host_op.dart';
import 'package:probably_works/host/local_host_runtime.dart';
import 'package:probably_works/host/shell_adapter.dart';

void main() {
  group('StatResult.parse', () {
    test('разбирает файл и каталог с mtime без изменений', () {
      final file = StatResult.parse('file 1700000000\n');
      expect(file?.isDir, isFalse);
      expect(file?.mtime, '1700000000');
      expect(StatResult.parse('dir 42')?.isDir, isTrue);
    });

    test('отвергает неизвестный тип и лишние поля', () {
      expect(StatResult.parse(''), isNull);
      expect(StatResult.parse('link 1'), isNull);
      expect(StatResult.parse('file'), isNull);
      expect(StatResult.parse('file 1 2'), isNull);
    });
  });

  group('ShellAdapter.compile', () {
    final ops = <HostOp>[
      const HostInfoOp(),
      const ListDirOp('/tmp'),
      const ReadFileOp(
        '/tmp/a',
        offset: 1,
        byteOffset: 0,
        limit: 10,
        chunkBytes: 1000,
        lineBytes: 100,
      ),
      const ReadRawOp('/tmp/a'),
      const ReadHeadOp('/tmp/a', maxBytes: 10),
      const ScanSkillsOp(['/tmp/skills'], maxBytes: 10),
      const GrepOp('x', '/tmp'),
      const WhichOp('ls'),
      const StatOp('/tmp/a'),
      const RealpathOp('/tmp'),
      const CanonicalPathOp('/tmp/a'),
      const FirstFileOp(['/tmp/a', '/tmp/b']),
      WriteFileOp('/tmp/a', backupPath: '/tmp/a.bak', expectedMtime: '1'),
    ];

    test(
      'каждая операция компилируется в непустую команду для posix и windows',
      () {
        for (final op in ops) {
          expect(
            ShellAdapter(HostOs.posix).compile(op),
            isNotEmpty,
            reason: op.label,
          );
          expect(
            ShellAdapter(HostOs.windows).compile(op),
            isNotEmpty,
            reason: op.label,
          );
        }
      },
    );

    test(
      'StatOp на posix выводит тип и mtime, на windows использует PowerShell',
      () {
        expect(
          ShellAdapter(HostOs.posix).compile(const StatOp('/tmp/a')),
          contains('echo "dir'),
        );
        expect(
          ShellAdapter(HostOs.windows).compile(const StatOp(r'C:\a')),
          startsWith('powershell'),
        );
      },
    );
  });

  group('perform на локальном Host', () {
    late Directory dir;
    late LocalHostRuntime runtime;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('pw_op');
      runtime = LocalHostRuntime(os: HostOs.posix);
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('StatOp отличает файл от каталога', () async {
      File('${dir.path}/a.txt').writeAsStringSync('hi');
      final file = await captureOp(runtime, StatOp('${dir.path}/a.txt'));
      final sub = await captureOp(runtime, StatOp(dir.path));
      expect(file.ok, isTrue);
      expect(StatResult.parse(file.stdout)?.isDir, isFalse);
      expect(StatResult.parse(sub.stdout)?.isDir, isTrue);
    });

    test(
      'StatOp для отсутствующего пути завершается ненулевым кодом',
      () async {
        final run = await captureOp(runtime, StatOp('${dir.path}/none'));
        expect(run.ok, isFalse);
      },
    );

    test(
      'FirstFileOp возвращает первый существующий путь по порядку',
      () async {
        File('${dir.path}/second').writeAsStringSync('x');
        final run = await captureOp(
          runtime,
          FirstFileOp(['${dir.path}/first', '${dir.path}/second']),
        );
        expect(run.stdout.trim(), '${dir.path}/second');
      },
    );

    test('CanonicalPathOp раскрывает симлинк и отсутствующий хвост', () async {
      final real = Directory('${dir.path}/real')..createSync();
      File('${real.path}/a.txt').writeAsStringSync('x');
      Link('${dir.path}/link').createSync(real.path);
      final found = await captureOp(
        runtime,
        CanonicalPathOp('${dir.path}/link/a.txt'),
      );
      expect(found.ok, isTrue, reason: found.stderr);
      expect(found.stdout.trim(), endsWith('/real/a.txt'));
      expect(found.stdout.contains('/link/'), isFalse);

      final missing = await captureOp(
        runtime,
        CanonicalPathOp('${dir.path}/link/new/file.txt'),
      );
      expect(missing.ok, isTrue, reason: missing.stderr);
      expect(missing.stdout.trim(), endsWith('/real/new/file.txt'));
    });

    test('CanonicalPathOp раскрывает тильду в абсолютный путь', () async {
      final home = await captureOp(runtime, const CanonicalPathOp('~'));
      expect(home.ok, isTrue, reason: home.stderr);
      expect(home.stdout.trim(), startsWith('/'));
    });

    test('ReadRawOp возвращает содержимое файла', () async {
      File('${dir.path}/a.txt').writeAsStringSync('payload');
      final run = await captureOp(runtime, ReadRawOp('${dir.path}/a.txt'));
      expect(run.stdout, 'payload');
    });

    test(
      'WriteFileOp пишет содержимое со stdin и сохраняет старую версию',
      () async {
        final path = '${dir.path}/a.txt';
        File(path).writeAsStringSync('old');
        final mtime = StatResult.parse(
          (await captureOp(runtime, StatOp(path))).stdout,
        )!.mtime;
        final run = await captureOp(
          runtime,
          WriteFileOp(path, backupPath: '$path.pw-bak-1', expectedMtime: mtime),
          stdin: Uint8List.fromList(utf8.encode('new')),
        );
        expect(run.ok, isTrue, reason: run.stderr);
        expect(File(path).readAsStringSync(), 'new');
        expect(File('$path.pw-bak-1').readAsStringSync(), 'old');
      },
    );

    test('WriteFileOp не пишет, если mtime изменился после чтения', () async {
      final path = '${dir.path}/a.txt';
      File(path).writeAsStringSync('old');
      final run = await captureOp(
        runtime,
        WriteFileOp(path, backupPath: '$path.pw-bak-2', expectedMtime: '1'),
        stdin: Uint8List.fromList(utf8.encode('new')),
      );
      expect(run.ok, isFalse);
      expect(File(path).readAsStringSync(), 'old');
    });
  });
}

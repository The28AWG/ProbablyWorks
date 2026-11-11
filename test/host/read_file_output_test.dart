import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/host/read_file_output.dart';
import 'package:pw_agent/host/shell_adapter.dart';

const _sh = ShellAdapter(HostOs.posix);

/// Запускает скрипт read_file с `awk`, подменённым через PATH, и возвращает вывод так, как его видит приложение:
/// stdout и stderr вместе (ToolRun.outputText объединяет оба потока).
class _Env {
  _Env(String awkName) {
    dir = Directory.systemTemp.createTempSync('pw_rfo_');
    bin = Directory('${dir.path}/bin')..createSync();
    Link('${bin.path}/awk').createSync('/usr/bin/$awkName');
  }

  late final Directory dir;
  late final Directory bin;

  File write(String name, List<int> bytes) =>
      File('${dir.path}/$name')..writeAsBytesSync(bytes);

  Future<String> output(
    String path, {
    int offset = 1,
    int byteOffset = 0,
    int limit = 200,
    int chunk = 20000,
    int lineBytes = 2000,
  }) async {
    final result = await Process.run(
      'sh',
      [
        '-c',
        _sh.readFile(
          path,
          offset: offset,
          byteOffset: byteOffset,
          limit: limit,
          chunkBytes: chunk,
          lineBytes: lineBytes,
        ),
      ],
      environment: {'PATH': '${bin.path}:${Platform.environment['PATH']}'},
    );
    return '${result.stdout}${result.stderr}';
  }

  void dispose() => dir.deleteSync(recursive: true);
}

void main() {
  for (final awk in ['gawk', 'mawk']) {
    group('parseReadFileOutput на реальном выводе $awk', () {
      late _Env env;

      setUp(() => env = _Env(awk));
      tearDown(() => env.dispose());

      test('файл целиком: строки с номерами и подвал конца файла', () async {
        final file = env.write('a.txt', utf8.encode('alpha\nbeta\ngamma'));
        final parsed = parseReadFileOutput(await env.output(file.path));

        expect(parsed, isA<ReadFileText>());
        final text = parsed! as ReadFileText;
        expect(text.totalLines, 3);
        expect(text.totalBytes, 16);
        expect(
          [for (final l in text.lines) (l.number, l.text)],
          [(1, 'alpha'), (2, 'beta'), (3, 'gamma')],
        );
        expect(text.footer, isA<ReadFileEndOfFile>());
      });

      test('лимит строк: подвал даёт offset следующего вызова', () async {
        final file = env.write('b.txt', utf8.encode('l1\nl2\nl3\nl4\nl5'));
        final parsed = parseReadFileOutput(
          await env.output(file.path, offset: 2, limit: 2),
        ) as ReadFileText;

        expect([for (final l in parsed.lines) l.number], [2, 3]);
        expect(parsed.footer, isA<ReadFileMore>());
        expect((parsed.footer! as ReadFileMore).offset, 4);
      });

      test(
        'разрез длинной строки: подвал и продолжение с byte_offset',
        () async {
          final long = 'abcdefghij' * 10;
          final file = env.write('c.txt', utf8.encode('$long\ntail'));
          final first =
              parseReadFileOutput(await env.output(file.path, lineBytes: 30))!
                  as ReadFileText;

          expect(first.lines.single.text, 'abcdefghij' * 3);
          final cut = first.footer! as ReadFileCut;
          expect(cut.line, 1);
          expect(cut.byte, 30);
          expect(cut.lineBytes, 100);
          expect(cut.offset, 1);
          expect(cut.byteOffset, 30);

          final rest =
              parseReadFileOutput(
                    await env.output(file.path, lineBytes: 30, byteOffset: 30),
                  )!
                  as ReadFileText;
          expect(rest.lines.single.number, 1);
          expect(rest.lines.single.byteOffset, 30);
          expect(rest.lines.single.text, 'abcdefghij' * 3);
        },
      );

      test('offset за концом файла', () async {
        final file = env.write('d.txt', utf8.encode('x\ny\nz'));
        final parsed = parseReadFileOutput(
          await env.output(file.path, offset: 10),
        );

        expect(parsed, isA<ReadFileBeyondEnd>());
        final beyond = parsed! as ReadFileBeyondEnd;
        expect(beyond.offset, 10);
        expect(beyond.totalLines, 3);
      });

      test(
        'пустой файл: awk сообщает о смещении за концом, строк нет',
        () async {
          final file = env.write('empty.txt', const []);
          final parsed = parseReadFileOutput(await env.output(file.path));

          expect(parsed, isA<ReadFileBeyondEnd>());
          expect((parsed! as ReadFileBeyondEnd).totalLines, 0);
        },
      );

      test('бинарный файл: ожидаемая ошибка, а не сырой вывод', () async {
        final file = env.write('bin.dat', [0x41, 0x00, 0x42]);
        final parsed = parseReadFileOutput(await env.output(file.path));

        expect(parsed, isA<ReadFileError>());
        expect((parsed! as ReadFileError).kind, ReadFileErrorKind.binary);
      });

      test('отсутствующий файл: ожидаемая ошибка notReadable', () async {
        final parsed = parseReadFileOutput(
          await env.output('${env.dir.path}/nope.txt'),
        );

        expect(parsed, isA<ReadFileError>());
        expect((parsed! as ReadFileError).kind, ReadFileErrorKind.notReadable);
      });

      test(
        'строка содержимого, похожая на префикс, не путается с номером',
        () async {
          final file = env.write('e.txt', utf8.encode('2: spoof\nreal'));
          final text =
              parseReadFileOutput(await env.output(file.path))! as ReadFileText;

          expect(
            [for (final l in text.lines) (l.number, l.text)],
            [(1, '2: spoof'), (2, 'real')],
          );
        },
      );
    }, skip: !File('/usr/bin/$awk').existsSync());
  }

  group('parseReadFileOutput на готовых строках', () {
    test('нераспознанный текст возвращает null, а не угадывает', () {
      expect(parseReadFileOutput('hello world'), isNull);
      expect(parseReadFileOutput(''), isNull);
    });

    test('число вне диапазона int не роняет разбор', () {
      expect(
        parseReadFileOutput(
          '[file: 99999999999999999999999999 lines, 0 bytes]\n',
        ),
        isNull,
      );
    });

    test('подвал не в конце вывода — формат нарушен, возвращается null', () {
      expect(
        parseReadFileOutput(
          '[file: 2 lines, 4 bytes]\n1: a\n[end of file]\n2: b\n',
        ),
        isNull,
      );
    });

    test('пропуск номера строки — формат нарушен, возвращается null', () {
      expect(
        parseReadFileOutput(
          '[file: 3 lines, 6 bytes]\n1: a\n3: c\n[end of file]\n',
        ),
        isNull,
      );
    });

    test('продолжение строки допускается только у первой строки вызова', () {
      expect(
        parseReadFileOutput(
          '[file: 2 lines, 6 bytes]\n1: a\n2 (from byte 3): b\n[end of file]\n',
        ),
        isNull,
      );
    });

    test('сообщение за концом файла должно быть единственной строкой', () {
      expect(
        parseReadFileOutput(
          '[file: 3 lines, 5 bytes]\n[offset 10 is beyond the end of the file (3 lines)]\n1: x\n',
        ),
        isNull,
      );
    });

    test('текст без заголовка возвращает null', () {
      expect(parseReadFileOutput('1: a\n[end of file]\n'), isNull);
    });

    test('подвал без строк (вызов не уместился): остаётся только подвал', () {
      final parsed =
          parseReadFileOutput(
                '[file: 5 lines, 20 bytes]\n[more: continue with offset=1]\n',
              )!
              as ReadFileText;

      expect(parsed.lines, isEmpty);
      expect((parsed.footer! as ReadFileMore).offset, 1);
    });

    test(
      'строка с \\r сохраняется, очистка от управляющих символов — дело вида',
      () {
        final parsed =
            parseReadFileOutput(
                  '[file: 1 lines, 3 bytes]\n1: a\r\n[end of file]\n',
                )!
                as ReadFileText;

        expect(parsed.lines.single.text, 'a\r');
      },
    );
  });
}

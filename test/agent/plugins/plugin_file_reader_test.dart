import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/agent/plugins/plugin_file_reader.dart';

/// Собирает кусок вывода `read_file` так, как его печатает Host:
/// заголовок, строки тела и подвал.
String _chunk({
  required int totalLines,
  required int totalBytes,
  required List<String> body,
  required String footer,
}) =>
    '[file: $totalLines lines, $totalBytes bytes]\n'
    '${body.map((line) => '$line\n').join()}'
    '$footer\n';

ReadFileChunkLoader _loaderFor(Map<String, String> chunks) =>
    (offset, byteOffset, first) async {
      final text = chunks['$offset/$byteOffset'];
      if (text == null) {
        throw StateError('unexpected cursor $offset/$byteOffset');
      }
      return (text: text, isError: false);
    };

void main() {
  test('assembles a file that ends with a newline', () async {
    final cursor = await ReadFileCursor.open(
      _loaderFor({
        '1/0': _chunk(
          totalLines: 2,
          totalBytes: 4,
          body: ['1: a', '2: b'],
          footer: '[end of file]',
        ),
      }),
    );

    expect(cursor.done, isTrue);
    expect(cursor.isError, isFalse);
    expect(cursor.text, 'a\nb\n');
  });

  test('keeps a missing trailing newline', () async {
    final cursor = await ReadFileCursor.open(
      _loaderFor({
        '1/0': _chunk(
          totalLines: 2,
          totalBytes: 3,
          body: ['1: a', '2: b'],
          footer: '[end of file]',
        ),
      }),
    );

    expect(cursor.text, 'a\nb');
  });

  test('preserves CRLF line endings', () async {
    final cursor = await ReadFileCursor.open(
      _loaderFor({
        '1/0': _chunk(
          totalLines: 2,
          totalBytes: 6,
          body: ['1: a\r', '2: b\r'],
          footer: '[end of file]',
        ),
      }),
    );

    expect(cursor.text, 'a\r\nb\r\n');
  });

  test('reads more chunks until the end', () async {
    var loads = 0;
    final cursor = await ReadFileCursor.open((offset, byteOffset, first) async {
      loads++;
      if (offset == 1) {
        return (
          text: _chunk(
            totalLines: 4,
            totalBytes: 8,
            body: ['1: a', '2: b'],
            footer: '[more: continue with offset=3]',
          ),
          isError: false,
        );
      }
      return (
        text: _chunk(
          totalLines: 4,
          totalBytes: 8,
          body: ['3: c', '4: d'],
          footer: '[end of file]',
        ),
        isError: false,
      );
    });

    expect(cursor.done, isFalse);
    expect(cursor.text, 'a\nb');

    await cursor.next();

    expect(cursor.done, isTrue);
    expect(cursor.text, 'a\nb\nc\nd\n');
    expect(loads, 2);
  });

  test('glues a line cut by the byte limit', () async {
    final cursor = await ReadFileCursor.open((offset, byteOffset, first) async {
      if (byteOffset == 0) {
        return (
          text: _chunk(
            totalLines: 1,
            totalBytes: 10,
            body: ['1: abcde'],
            footer:
                '[line 1 is cut at byte 5 of 10 bytes: '
                'continue with offset=1 byte_offset=5]',
          ),
          isError: false,
        );
      }
      return (
        text: _chunk(
          totalLines: 1,
          totalBytes: 10,
          body: ['1 (from byte 5): fghij'],
          footer: '[end of file]',
        ),
        isError: false,
      );
    });

    expect(cursor.done, isFalse);
    await cursor.next();

    expect(cursor.done, isTrue);
    expect(cursor.text, 'abcdefghij');
  });

  test('a file of one newline is reconstructed', () async {
    final cursor = await ReadFileCursor.open(
      _loaderFor({
        '1/0': _chunk(
          totalLines: 1,
          totalBytes: 1,
          body: ['1: '],
          footer: '[end of file]',
        ),
      }),
    );

    expect(cursor.text, '\n');
  });

  test('an empty file yields empty text', () async {
    final cursor = await ReadFileCursor.open(
      _loaderFor({
        '1/0':
            '[file: 0 lines, 0 bytes]\n'
            '[offset 1 is beyond the end of the file (0 lines)]\n',
      }),
    );

    expect(cursor.done, isTrue);
    expect(cursor.isError, isFalse);
    expect(cursor.text, isEmpty);
  });

  test('reports a read error', () async {
    final cursor = await ReadFileCursor.open(
      (offset, byteOffset, first) async =>
          (text: 'not a readable regular file', isError: false),
    );

    expect(cursor.done, isTrue);
    expect(cursor.isError, isTrue);
    expect(cursor.text, 'not a readable regular file');
  });

  test('reports a loader failure', () async {
    final cursor = await ReadFileCursor.open(
      (offset, byteOffset, first) async =>
          (text: 'host is gone', isError: true),
    );

    expect(cursor.done, isTrue);
    expect(cursor.isError, isTrue);
    expect(cursor.text, 'host is gone');
  });

  test('next after done does nothing', () async {
    var loads = 0;
    final cursor = await ReadFileCursor.open((offset, byteOffset, first) async {
      loads++;
      return (
        text: _chunk(
          totalLines: 1,
          totalBytes: 2,
          body: ['1: x'],
          footer: '[end of file]',
        ),
        isError: false,
      );
    });

    await cursor.next();

    expect(loads, 1);
  });

  test('stops when the cursor does not advance', () async {
    final cursor = await ReadFileCursor.open(
      (offset, byteOffset, first) async => (
        text: _chunk(
          totalLines: 2,
          totalBytes: 4,
          body: ['1: a'],
          footer: '[more: continue with offset=1]',
        ),
        isError: false,
      ),
    );

    var steps = 0;
    while (!cursor.done && steps < 5) {
      await cursor.next();
      steps++;
    }

    expect(cursor.done, isTrue);
    expect(steps, 1);
  });
}

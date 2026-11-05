import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/host/virtual/read_file_pager.dart';

/// Точный текст постраничного вывода. Эталон — awk-скрипт `ReadFileOp` на POSIX, его проверяет паритет.
String _page(
  String text, {
  int offset = 1,
  int byteOffset = 0,
  int limit = 2000,
  int chunkBytes = 60000,
  int lineBytes = 2000,
}) => utf8.decode(
  ReadFilePager.page(
    Uint8List.fromList(utf8.encode(text)),
    offset: offset,
    byteOffset: byteOffset,
    limit: limit,
    chunkBytes: chunkBytes,
    lineBytes: lineBytes,
  ),
);

void main() {
  test('короткий файл целиком и хвост конца файла', () {
    expect(_page('a\n'), '[file: 1 lines, 2 bytes]\n1: a\n[end of file]\n');
  });

  test('лимит строк даёт подсказку продолжения с следующей строки', () {
    expect(
      _page('a\nb\n', limit: 1),
      '[file: 2 lines, 4 bytes]\n1: a\n[more: continue with offset=2]\n',
    );
  });

  test('длинная строка режется по lineBytes и помечает байтовый курсор', () {
    expect(
      _page('abcdef\n', lineBytes: 4),
      '[file: 1 lines, 7 bytes]\n1: abcd\n'
      '[line 1 is cut at byte 4 of 6 bytes: continue with offset=1 byte_offset=4]\n',
    );
  });

  test('смещение за концом файла сообщает об этом', () {
    expect(
      _page('a\nb\n', offset: 5),
      '[file: 2 lines, 4 bytes]\n[offset 5 is beyond the end of the file (2 lines)]\n',
    );
  });

  test('продолжение с byte_offset выдаёт остаток строки с префиксом', () {
    expect(
      _page('abcdef\n', byteOffset: 4),
      '[file: 1 lines, 7 bytes]\n1 (from byte 4): ef\n[end of file]\n',
    );
  });

  test('резка не разрывает многобайтовый символ UTF-8', () {
    // «ж» занимает два байта. Лимит в три байта должен отступить до границы символа.
    final text = utf8.decode(
      ReadFilePager.page(
        Uint8List.fromList(utf8.encode('жж\n')),
        offset: 1,
        byteOffset: 0,
        limit: 10,
        chunkBytes: 60000,
        lineBytes: 3,
      ),
    );
    expect(text, contains('1: ж\n'));
    expect(text, contains('[line 1 is cut at byte 2 of 4 bytes'));
  });
}

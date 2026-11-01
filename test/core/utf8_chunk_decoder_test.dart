import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/util/utf8_chunk_decoder.dart';

void main() {
  test('a multi-byte character split across chunks is decoded whole', () {
    final bytes = utf8.encode('привет, мир ✓');
    final decoder = Utf8ChunkDecoder();
    final out = StringBuffer();
    for (final byte in bytes) {
      out.write(decoder.add([byte]));
    }
    out.write(decoder.close());
    expect(out.toString(), 'привет, мир ✓');
  });

  test('a dangling lead byte becomes a replacement character on close', () {
    final decoder = Utf8ChunkDecoder();
    expect(decoder.add([0xD0]), isEmpty);
    expect(decoder.close(), '\uFFFD');
  });

  test('invalid bytes do not throw and valid text after them survives', () {
    final decoder = Utf8ChunkDecoder();
    final text = decoder.add([0xFF, 0x41]) + decoder.close();
    expect(text, contains('A'));
  });
}

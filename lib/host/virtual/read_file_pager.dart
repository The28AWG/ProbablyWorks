import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Постраничный вывод `read_file` для виртуального Host. Алгоритм и формат совпадают с awk-скриптом
/// из `ShellAdapter.readFile` на POSIX: тот же байтовый курсор, те же хвостовые подсказки.
///
/// Курсор состоит из номера строки [offset] (с 1), байта внутри неё [byteOffset] и лимитов
/// [limit] строк и [chunkBytes] байтов за вызов. Строка длиннее [lineBytes] режется на части, а конец
/// части совпадает с границей символа UTF-8, поэтому курсор всегда указывает на начало символа.
/// Тексты хвоста совпадают с awk построчно: их разбирает `ReadFileOutput`.
abstract final class ReadFilePager {
  const ReadFilePager._();

  /// Формирует вывод для [data]. Содержимое считается текстом без NUL: проверку делает вызывающий код.
  static Uint8List page(
    Uint8List data, {
    required int offset,
    required int byteOffset,
    required int limit,
    required int chunkBytes,
    required int lineBytes,
  }) {
    final body = BytesBuilder(copy: false);
    final size = data.length;
    var nextLine = offset;
    var nextByte = byteOffset;
    var nextLen = 0;
    var used = 0;
    var shown = 0;
    var stop = false;
    var lineNo = 0;
    var pos = 0;

    while (pos < size) {
      final newline = data.indexOf(10, pos);
      final end = newline < 0 ? size : newline;
      final start = pos;
      pos = end + 1;
      lineNo++;
      if (lineNo < offset || stop) continue;

      final len = end - start;
      var b = lineNo == offset ? byteOffset : 0;
      while (b < len && _isContinuation(data[start + b])) {
        b++;
      }
      final rest = len - b;
      var take = 0;
      if (rest > 0) {
        take = min(min(rest, lineBytes), chunkBytes - used);
        if (b + take < len) {
          while (take > 0 && _isContinuation(data[start + b + take])) {
            take--;
          }
        }
        if (take <= 0) {
          stop = true;
          continue;
        }
      }

      body
        ..add(utf8.encode(b == 0 ? '$lineNo: ' : '$lineNo (from byte $b): '))
        ..add(
          take == 0 ? Uint8List(0) : data.sublist(start + b, start + b + take),
        )
        ..addByte(10);
      used += take;
      shown++;
      if (b + take < len) {
        nextLine = lineNo;
        nextByte = b + take;
        nextLen = len;
        stop = true;
      } else {
        nextLine = lineNo + 1;
        nextByte = 0;
        if (shown >= limit || used >= chunkBytes) stop = true;
      }
    }

    final out = BytesBuilder(copy: false)
      ..add(utf8.encode('[file: $lineNo lines, $size bytes]\n'));
    if (offset > lineNo) {
      out.add(
        utf8.encode(
          '[offset $offset is beyond the end of the file ($lineNo lines)]\n',
        ),
      );
    } else {
      out
        ..add(body.takeBytes())
        ..add(utf8.encode(_footer(nextLine, nextByte, nextLen, lineNo)));
    }
    return out.takeBytes();
  }

  static String _footer(int nextLine, int nextByte, int nextLen, int total) {
    if (nextLine > total) return '[end of file]\n';
    if (nextByte == 0) return '[more: continue with offset=$nextLine]\n';
    return '[line $nextLine is cut at byte $nextByte of $nextLen bytes: '
        'continue with offset=$nextLine byte_offset=$nextByte]\n';
  }

  /// Продолжение символа UTF-8: байты 0x80–0xBF.
  static bool _isContinuation(int byte) => byte >= 0x80 && byte < 0xC0;
}

// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'dart:typed_data';

import 'package:archive/archive.dart' as archive;

import 'package:virtual_git/src/git_pack.dart';

const String gitPackSignature = 'PACK';

Uint8List encodeGitUint32(int value) {
  final byteData = ByteData(4)..setUint32(0, value, Endian.big);
  return byteData.buffer.asUint8List();
}

Uint8List encodeGitUint64(int value) {
  final byteData = ByteData(8)..setUint64(0, value, Endian.big);
  return byteData.buffer.asUint8List();
}

int readGitUint64(archive.InputStream input) {
  final bytes = input.readBytes(8).toUint8List();
  return ByteData.sublistView(bytes).getUint64(0, Endian.big);
}

Uint8List encodeGitPackEntryHeader(GitPackEntryType type, int objectSize) {
  if (objectSize < 0) {
    throw ArgumentError.value(
      objectSize,
      'objectSize',
      'Pack entry object size must not be negative.',
    );
  }

  final bytes = <int>[];
  var remaining = objectSize;
  var byte = (type.code << 4) | (remaining & 0x0f);
  remaining >>= 4;
  if (remaining > 0) {
    byte |= 0x80;
  }
  bytes.add(byte);

  while (remaining > 0) {
    var nextByte = remaining & 0x7f;
    remaining >>= 7;
    if (remaining > 0) {
      nextByte |= 0x80;
    }
    bytes.add(nextByte);
  }

  return Uint8List.fromList(bytes);
}

({GitPackEntryType type, int objectSize}) decodeGitPackEntryHeader(
  archive.InputStream input,
) {
  var byte = input.readByte();
  final type = GitPackEntryType.fromCode((byte >> 4) & 0x07);
  var objectSize = byte & 0x0f;
  var shift = 4;

  while ((byte & 0x80) != 0) {
    byte = input.readByte();
    objectSize |= (byte & 0x7f) << shift;
    shift += 7;
  }

  return (type: type, objectSize: objectSize);
}

Uint8List encodeGitPackOffsetDistance(int value) {
  if (value <= 0) {
    throw ArgumentError.value(
      value,
      'value',
      'Pack offset delta base distance must be positive.',
    );
  }

  final bytes = <int>[value & 0x7f];
  var remaining = value;
  remaining >>= 7;
  while (remaining != 0) {
    remaining -= 1;
    bytes.add((remaining & 0x7f) | 0x80);
    remaining >>= 7;
  }
  return Uint8List.fromList(bytes.reversed.toList(growable: false));
}

int decodeGitPackOffsetDistance(archive.InputStream input) {
  var byte = input.readByte();
  var value = byte & 0x7f;

  while ((byte & 0x80) != 0) {
    byte = input.readByte();
    value = ((value + 1) << 7) | (byte & 0x7f);
  }

  return value;
}

Uint8List inflateGitPackZlibStream(archive.InputStream input) {
  final cmf = input.readByte();
  final flg = input.readByte();
  final method = cmf & 0x0f;
  final hasDictionary = (flg & 0x20) != 0;

  if (method != 8) {
    throw FormatException('Unsupported zlib compression method.', method);
  }
  if (((cmf << 8) + flg) % 31 != 0) {
    throw const FormatException('Invalid zlib header checksum.');
  }
  if (hasDictionary) {
    throw const FormatException('Zlib preset dictionaries are not supported.');
  }

  final output = archive.Inflate.stream(input).getBytes();
  final expectedAdler32 = input.readUint32();
  final actualAdler32 = archive.getAdler32(output);
  if (expectedAdler32 != actualAdler32) {
    throw FormatException(
      'Zlib Adler-32 checksum does not match the inflated output.',
      expectedAdler32,
    );
  }
  return output;
}

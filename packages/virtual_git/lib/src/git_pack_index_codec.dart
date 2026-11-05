// ignore_for_file: cascade_invocations
// ignore_for_file: avoid-substring
// Причина: разбор hex и каскады оставлены как в git_core.
// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'dart:typed_data';

import 'package:archive/archive.dart' as archive;

import 'package:virtual_git/src/git_crc32.dart';
import 'package:virtual_git/src/git_hash_algorithm.dart';
import 'package:virtual_git/src/git_object_id.dart';
import 'package:virtual_git/src/git_pack.dart';
import 'package:virtual_git/src/git_pack_codec_support.dart';
import 'package:virtual_git/src/git_pack_index.dart';

final class GitPackIndexCodec {
  const GitPackIndexCodec({this.checksumAlgorithm = GitHashAlgorithm.sha1});

  static const int version = 2;
  static const int _magic = 0xff744f63;

  final GitHashAlgorithm checksumAlgorithm;

  Uint8List encode(GitPackIndex index) {
    if (index.version != version) {
      throw ArgumentError.value(
        index.version,
        'index.version',
        'Pack index version must be 2.',
      );
    }
    if (index.checksumAlgorithm != checksumAlgorithm) {
      throw ArgumentError.value(
        index.checksumAlgorithm,
        'index.checksumAlgorithm',
        'Pack index checksum algorithm must match the codec checksum algorithm.',
      );
    }

    final bytes = _encodeWithoutChecksum(index);
    final checksum = GitObjectId.compute(bytes, algorithm: checksumAlgorithm);
    return Uint8List.fromList([...bytes, ...checksum.toBytes()]);
  }

  GitPackIndex decode(List<int> bytes) {
    final digestLength = checksumAlgorithm.digestLength;
    if (bytes.length < digestLength * 2 + 8 + (256 * 4)) {
      throw const FormatException('Pack index file is too short.');
    }

    final input = archive.InputMemoryStream(
      Uint8List.fromList(bytes),
      byteOrder: archive.ByteOrder.bigEndian,
    );

    final magic = input.readUint32();
    if (magic != _magic) {
      throw FormatException('Pack index magic number is invalid.', magic);
    }

    final actualVersion = input.readUint32();
    if (actualVersion != version) {
      throw FormatException('Unsupported pack index version.', actualVersion);
    }

    final fanoutTable = List<int>.generate(
      256,
      (_) => input.readUint32(),
      growable: false,
    );
    _validateFanoutTable(fanoutTable);

    final objectCount = fanoutTable.last;
    final objectIds = List<GitObjectId>.generate(objectCount, (_) {
      final objectId = GitObjectId.fromBytes(
        input.readBytes(digestLength).toUint8List(),
      );
      if (objectId.algorithm != checksumAlgorithm) {
        throw FormatException(
          'Pack index object ids must use the codec checksum algorithm.',
          objectId.hex,
        );
      }
      return objectId;
    }, growable: false);
    _validateSortedObjectIds(objectIds);
    _validateFanoutMatchesObjectIds(fanoutTable, objectIds);

    final crc32Values = List<int>.generate(
      objectCount,
      (_) => input.readUint32(),
      growable: false,
    );
    final rawOffsets = List<int>.generate(
      objectCount,
      (_) => input.readUint32(),
      growable: false,
    );

    final largeOffsetBytes = bytes.length - input.position - (digestLength * 2);
    if (largeOffsetBytes < 0 || largeOffsetBytes % 8 != 0) {
      throw const FormatException(
        'Pack index large offset table is malformed.',
      );
    }

    final largeOffsets = List<int>.generate(
      largeOffsetBytes ~/ 8,
      (_) => readGitUint64(input),
      growable: false,
    );

    final packChecksum = GitObjectId.fromBytes(
      input.readBytes(digestLength).toUint8List(),
    );
    final actualChecksum = GitObjectId.fromBytes(
      input.readBytes(digestLength).toUint8List(),
    );

    if (input.position != bytes.length) {
      throw FormatException(
        'Pack index decoder did not stop at the checksum trailer boundary.',
        input.position,
      );
    }

    final expectedChecksum = GitObjectId.compute(
      bytes.sublist(0, bytes.length - digestLength),
      algorithm: checksumAlgorithm,
    );
    if (expectedChecksum != actualChecksum) {
      throw FormatException(
        'Pack index checksum does not match the index contents.',
        actualChecksum.hex,
      );
    }

    final entries = <GitPackIndexEntry>[];
    for (var index = 0; index < objectCount; index++) {
      final rawOffset = rawOffsets[index];
      final offset = (rawOffset & 0x80000000) == 0
          ? rawOffset
          : _resolveLargeOffset(largeOffsets, rawOffset & 0x7fffffff);
      entries.add(
        GitPackIndexEntry(
          objectId: objectIds[index],
          offset: offset,
          crc32: crc32Values[index],
        ),
      );
    }

    return GitPackIndex(
      version: actualVersion,
      checksumAlgorithm: checksumAlgorithm,
      entries: entries,
      packChecksum: packChecksum,
      checksum: actualChecksum,
    );
  }

  GitPackIndex build(
    List<int> packBytes, {
    required List<GitObjectId> objectIdsInPackOrder,
  }) {
    if (packBytes.length < checksumAlgorithm.digestLength + 12) {
      throw const FormatException('Pack file is too short.');
    }

    if (objectIdsInPackOrder.any(
      (objectId) => objectId.algorithm != checksumAlgorithm,
    )) {
      throw ArgumentError.value(
        objectIdsInPackOrder,
        'objectIdsInPackOrder',
        'Pack index object ids must use the codec checksum algorithm.',
      );
    }

    final input = archive.InputMemoryStream(
      Uint8List.fromList(packBytes),
      byteOrder: archive.ByteOrder.bigEndian,
    );

    final actualSignature = input.readString(size: 4, utf8: false);
    if (actualSignature != gitPackSignature) {
      throw FormatException('Pack signature is invalid.', actualSignature);
    }

    final packVersion = input.readUint32();
    if (packVersion != 2 && packVersion != 3) {
      throw FormatException('Unsupported pack version.', packVersion);
    }

    final objectCount = input.readUint32();
    if (objectIdsInPackOrder.length != objectCount) {
      throw ArgumentError.value(
        objectIdsInPackOrder.length,
        'objectIdsInPackOrder',
        'Pack index builder requires one object id for each pack entry.',
      );
    }

    final packBodyEnd = packBytes.length - checksumAlgorithm.digestLength;
    final entriesByPackOrder = <GitPackIndexEntry>[];

    while (input.position < packBodyEnd &&
        entriesByPackOrder.length < objectCount) {
      final objectId = objectIdsInPackOrder[entriesByPackOrder.length];
      final offset = input.position;
      final header = decodeGitPackEntryHeader(input);

      switch (header.type) {
        case GitPackEntryType.commit ||
            GitPackEntryType.tree ||
            GitPackEntryType.blob ||
            GitPackEntryType.tag:
          final body = inflateGitPackZlibStream(input);
          if (body.length != header.objectSize) {
            throw FormatException(
              'Pack object size does not match the decoded body size.',
              body.length,
            );
          }
        case GitPackEntryType.offsetDelta:
          decodeGitPackOffsetDistance(input);
          inflateGitPackZlibStream(input);
        case GitPackEntryType.referenceDelta:
          input.readBytes(checksumAlgorithm.digestLength);
          inflateGitPackZlibStream(input);
      }

      entriesByPackOrder.add(
        GitPackIndexEntry(
          objectId: objectId,
          offset: offset,
          crc32: computeGitCrc32(packBytes.sublist(offset, input.position)),
        ),
      );
    }

    if (entriesByPackOrder.length != objectCount) {
      throw FormatException(
        'Pack object count does not match the number of indexed entries.',
        entriesByPackOrder.length,
      );
    }

    if (input.position != packBodyEnd) {
      throw FormatException(
        'Pack index builder did not stop at the checksum trailer boundary.',
        input.position,
      );
    }

    final expectedPackChecksum = GitObjectId.compute(
      packBytes.sublist(0, packBodyEnd),
      algorithm: checksumAlgorithm,
    );
    final actualPackChecksum = GitObjectId.fromBytes(
      packBytes.sublist(packBodyEnd),
    );
    if (expectedPackChecksum != actualPackChecksum) {
      throw FormatException(
        'Pack checksum does not match the pack contents.',
        actualPackChecksum.hex,
      );
    }

    final sortedEntries = [...entriesByPackOrder]
      ..sort((left, right) => left.objectId.hex.compareTo(right.objectId.hex));
    final index = GitPackIndex(
      checksumAlgorithm: checksumAlgorithm,
      entries: sortedEntries,
      packChecksum: actualPackChecksum,
    );

    return GitPackIndex(
      version: index.version,
      checksumAlgorithm: index.checksumAlgorithm,
      entries: index.entries,
      packChecksum: index.packChecksum,
      checksum: GitObjectId.compute(
        _encodeWithoutChecksum(index),
        algorithm: checksumAlgorithm,
      ),
    );
  }

  Uint8List _encodeWithoutChecksum(GitPackIndex index) {
    final packChecksum = index.packChecksum;
    if (packChecksum == null) {
      throw StateError('Pack index requires a pack checksum.');
    }
    if (packChecksum.algorithm != checksumAlgorithm) {
      throw ArgumentError.value(
        packChecksum,
        'index.packChecksum',
        'Pack checksum must use the codec checksum algorithm.',
      );
    }

    _validateEntries(index.entries);

    final bytes = BytesBuilder();
    bytes.add(encodeGitUint32(_magic));
    bytes.add(encodeGitUint32(version));

    for (final value in _buildFanoutTable(index.entries)) {
      bytes.add(encodeGitUint32(value));
    }
    for (final entry in index.entries) {
      bytes.add(entry.objectId.toBytes());
    }
    for (final entry in index.entries) {
      bytes.add(encodeGitUint32(entry.crc32 & 0xffffffff));
    }

    final largeOffsets = <int>[];
    for (final entry in index.entries) {
      if (entry.offset > 0x7fffffff) {
        final largeOffsetIndex = largeOffsets.length;
        largeOffsets.add(entry.offset);
        bytes.add(encodeGitUint32(largeOffsetIndex | 0x80000000));
      } else {
        bytes.add(encodeGitUint32(entry.offset));
      }
    }
    for (final offset in largeOffsets) {
      bytes.add(encodeGitUint64(offset));
    }

    bytes.add(packChecksum.toBytes());
    return bytes.takeBytes();
  }

  void _validateEntries(List<GitPackIndexEntry> entries) {
    String? previousHex;

    for (final entry in entries) {
      if (entry.objectId.algorithm != checksumAlgorithm) {
        throw ArgumentError.value(
          entry.objectId,
          'entry.objectId',
          'Pack index object ids must use the codec checksum algorithm.',
        );
      }
      if (entry.offset < 0) {
        throw ArgumentError.value(
          entry.offset,
          'entry.offset',
          'Pack index offsets must not be negative.',
        );
      }
      if (entry.crc32 < 0 || entry.crc32 > 0xffffffff) {
        throw ArgumentError.value(
          entry.crc32,
          'entry.crc32',
          'Pack index CRC32 values must fit in 32 bits.',
        );
      }

      final currentHex = entry.objectId.hex;
      if (previousHex != null && previousHex.compareTo(currentHex) >= 0) {
        throw ArgumentError.value(
          entries,
          'index.entries',
          'Pack index entries must be sorted by object id with no duplicates.',
        );
      }
      previousHex = currentHex;
    }
  }

  List<int> _buildFanoutTable(List<GitPackIndexEntry> entries) {
    final fanout = List<int>.filled(256, 0);
    var entryIndex = 0;

    for (var leadingByte = 0; leadingByte < 256; leadingByte++) {
      while (entryIndex < entries.length &&
          _leadingByte(entries[entryIndex].objectId) <= leadingByte) {
        entryIndex += 1;
      }
      fanout[leadingByte] = entryIndex;
    }

    return fanout;
  }

  void _validateFanoutTable(List<int> fanoutTable) {
    var previous = 0;

    for (final value in fanoutTable) {
      if (value < previous) {
        throw FormatException(
          'Pack index fan-out table must be non-decreasing.',
          value,
        );
      }
      previous = value;
    }
  }

  void _validateSortedObjectIds(List<GitObjectId> objectIds) {
    String? previousHex;

    for (final objectId in objectIds) {
      final currentHex = objectId.hex;
      if (previousHex != null && previousHex.compareTo(currentHex) >= 0) {
        throw FormatException(
          'Pack index object ids must be sorted with no duplicates.',
          currentHex,
        );
      }
      previousHex = currentHex;
    }
  }

  void _validateFanoutMatchesObjectIds(
    List<int> fanoutTable,
    List<GitObjectId> objectIds,
  ) {
    var objectIndex = 0;

    for (var leadingByte = 0; leadingByte < 256; leadingByte++) {
      while (objectIndex < objectIds.length &&
          _leadingByte(objectIds[objectIndex]) <= leadingByte) {
        objectIndex += 1;
      }
      if (fanoutTable[leadingByte] != objectIndex) {
        throw FormatException(
          'Pack index fan-out table does not match sorted object ids.',
          leadingByte,
        );
      }
    }
  }

  int _resolveLargeOffset(List<int> largeOffsets, int index) {
    if (index < 0 || index >= largeOffsets.length) {
      throw FormatException(
        'Pack index large offset reference is invalid.',
        index,
      );
    }
    return largeOffsets[index];
  }

  int _leadingByte(GitObjectId objectId) =>
      int.parse(objectId.hex.substring(0, 2), radix: 16);
}

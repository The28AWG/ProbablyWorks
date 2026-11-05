// ignore_for_file: cascade_invocations
// Причина: каскады оставлены как в git_core.
// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'dart:typed_data';

import 'package:archive/archive.dart' as archive;

import 'package:virtual_git/src/git_hash_algorithm.dart';
import 'package:virtual_git/src/git_object.dart';
import 'package:virtual_git/src/git_object_id.dart';
import 'package:virtual_git/src/git_pack.dart';
import 'package:virtual_git/src/git_pack_codec_support.dart';

final class GitPackCodec {
  const GitPackCodec({this.checksumAlgorithm = GitHashAlgorithm.sha1});

  final GitHashAlgorithm checksumAlgorithm;

  Uint8List encode(GitPack pack) {
    if (pack.version != 2 && pack.version != 3) {
      throw ArgumentError.value(
        pack.version,
        'pack.version',
        'Pack version must be 2 or 3.',
      );
    }
    if (pack.checksumAlgorithm != checksumAlgorithm) {
      throw ArgumentError.value(
        pack.checksumAlgorithm,
        'pack.checksumAlgorithm',
        'Pack checksum algorithm must match the codec checksum algorithm.',
      );
    }

    final bytes = BytesBuilder();
    bytes.add(gitPackSignature.codeUnits);
    bytes.add(encodeGitUint32(pack.version));
    bytes.add(encodeGitUint32(pack.entries.length));

    for (final entry in pack.entries) {
      bytes.add(_encodeEntry(entry));
    }

    final withoutChecksum = bytes.takeBytes();
    final checksum = GitObjectId.compute(
      withoutChecksum,
      algorithm: pack.checksumAlgorithm,
    );
    return Uint8List.fromList([...withoutChecksum, ...checksum.toBytes()]);
  }

  GitPack decode(List<int> bytes) {
    if (bytes.length < checksumAlgorithm.digestLength + 12) {
      throw const FormatException('Pack file is too short.');
    }

    final input = archive.InputMemoryStream(
      Uint8List.fromList(bytes),
      byteOrder: archive.ByteOrder.bigEndian,
    );

    final actualSignature = input.readString(size: 4, utf8: false);
    if (actualSignature != gitPackSignature) {
      throw FormatException('Pack signature is invalid.', actualSignature);
    }

    final version = input.readUint32();
    if (version != 2 && version != 3) {
      throw FormatException('Unsupported pack version.', version);
    }

    final objectCount = input.readUint32();
    final packBodyEnd = bytes.length - checksumAlgorithm.digestLength;
    final entries = <GitPackEntry>[];

    while (input.position < packBodyEnd && entries.length < objectCount) {
      entries.add(_decodeEntry(input));
    }

    if (entries.length != objectCount) {
      throw FormatException(
        'Pack object count does not match the number of decoded entries.',
        entries.length,
      );
    }

    if (input.position != packBodyEnd) {
      throw FormatException(
        'Pack decoder did not stop at the checksum trailer boundary.',
        input.position,
      );
    }

    final expectedChecksum = GitObjectId.compute(
      bytes.sublist(0, packBodyEnd),
      algorithm: checksumAlgorithm,
    );
    final actualChecksum = GitObjectId.fromBytes(bytes.sublist(packBodyEnd));
    if (expectedChecksum != actualChecksum) {
      throw FormatException(
        'Pack checksum does not match the pack contents.',
        actualChecksum.hex,
      );
    }

    return GitPack(
      version: version,
      checksumAlgorithm: checksumAlgorithm,
      entries: entries,
      checksum: actualChecksum,
    );
  }

  Uint8List _encodeEntry(GitPackEntry entry) {
    final bytes = BytesBuilder();
    bytes.add(encodeGitPackEntryHeader(entry.type, entry.objectSize));

    switch (entry) {
      case GitPackObjectEntry(:final object):
        bytes.add(const archive.ZLibEncoder().encode(object.bytes));
      case GitPackOffsetDeltaEntry(
        :final baseOffsetDistance,
        :final deltaBytes,
      ):
        bytes.add(encodeGitPackOffsetDistance(baseOffsetDistance));
        bytes.add(const archive.ZLibEncoder().encode(deltaBytes));
      case GitPackReferenceDeltaEntry(:final baseObjectId, :final deltaBytes):
        if (baseObjectId.algorithm != checksumAlgorithm) {
          throw ArgumentError.value(
            baseObjectId,
            'entry.baseObjectId',
            'Pack delta base object id must use the pack checksum algorithm.',
          );
        }
        bytes.add(baseObjectId.toBytes());
        bytes.add(const archive.ZLibEncoder().encode(deltaBytes));
    }

    return bytes.takeBytes();
  }

  GitPackEntry _decodeEntry(archive.InputStream input) {
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
        return GitPackObjectEntry(
          GitObject(header.type.objectType!, body),
          offset: offset,
        );
      case GitPackEntryType.offsetDelta:
        final baseOffsetDistance = decodeGitPackOffsetDistance(input);
        final deltaBytes = inflateGitPackZlibStream(input);
        return GitPackOffsetDeltaEntry(
          baseOffsetDistance: baseOffsetDistance,
          deltaBytes: deltaBytes,
          objectSize: header.objectSize,
          offset: offset,
        );
      case GitPackEntryType.referenceDelta:
        final baseObjectId = GitObjectId.fromBytes(
          input.readBytes(checksumAlgorithm.digestLength).toUint8List(),
        );
        final deltaBytes = inflateGitPackZlibStream(input);
        return GitPackReferenceDeltaEntry(
          baseObjectId: baseObjectId,
          deltaBytes: deltaBytes,
          objectSize: header.objectSize,
          offset: offset,
        );
    }
  }
}

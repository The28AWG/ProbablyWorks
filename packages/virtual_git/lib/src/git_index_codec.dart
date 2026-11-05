// ignore_for_file: cascade_invocations
// Причина: каскады оставлены как в git_core.
// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' as archive;

import 'package:virtual_git/src/git_hash_algorithm.dart';
import 'package:virtual_git/src/git_index.dart';
import 'package:virtual_git/src/git_object_id.dart';

final class GitIndexCodec {
  const GitIndexCodec({this.checksumAlgorithm = GitHashAlgorithm.sha1});

  static const String signature = 'DIRC';
  static const int _skipWorktreeFlag = 0x4000;
  static const int _intentToAddFlag = 0x2000;

  final GitHashAlgorithm checksumAlgorithm;

  Uint8List encode(GitIndex index) {
    if (index.version != 2 && index.version != 3) {
      throw ArgumentError.value(
        index.version,
        'index.version',
        'Git index version must be 2 or 3.',
      );
    }
    if (index.checksumAlgorithm != checksumAlgorithm) {
      throw ArgumentError.value(
        index.checksumAlgorithm,
        'index.checksumAlgorithm',
        'Git index checksum algorithm must match the codec checksum algorithm.',
      );
    }

    final bytes = BytesBuilder();
    bytes.add(signature.codeUnits);
    bytes.add(_encodeUint32(index.version));
    bytes.add(_encodeUint32(index.entries.length));

    _validateEntries(index.entries, version: index.version);
    for (final entry in index.entries) {
      bytes.add(_encodeEntry(entry, version: index.version));
    }

    for (final extension in index.extensions) {
      bytes.add(_encodeExtension(extension));
    }

    final withoutChecksum = bytes.takeBytes();
    final checksum = GitObjectId.compute(
      withoutChecksum,
      algorithm: checksumAlgorithm,
    );
    return Uint8List.fromList([...withoutChecksum, ...checksum.toBytes()]);
  }

  GitIndex decode(List<int> bytes) {
    final digestLength = checksumAlgorithm.digestLength;
    if (bytes.length < digestLength + 12) {
      throw const FormatException('Git index file is too short.');
    }

    final input = archive.InputMemoryStream(
      Uint8List.fromList(bytes),
      byteOrder: archive.ByteOrder.bigEndian,
    );

    final actualSignature = input.readString(size: 4, utf8: false);
    if (actualSignature != signature) {
      throw FormatException('Git index signature is invalid.', actualSignature);
    }

    final version = input.readUint32();
    if (version != 2 && version != 3) {
      throw FormatException('Unsupported git index version.', version);
    }

    final entryCount = input.readUint32();
    final entries = List<GitIndexEntry>.generate(
      entryCount,
      (_) => _decodeEntry(input, version: version),
      growable: false,
    );
    _validateEntries(entries, version: version);

    final trailerStart = bytes.length - digestLength;
    final extensions = <GitIndexExtension>[];
    while (input.position < trailerStart) {
      if (trailerStart - input.position < 8) {
        throw const FormatException('Git index extension header is truncated.');
      }
      extensions.add(_decodeExtension(input, trailerStart));
    }

    if (input.position != trailerStart) {
      throw FormatException(
        'Git index decoder did not stop at the checksum trailer boundary.',
        input.position,
      );
    }

    final expectedChecksum = GitObjectId.compute(
      bytes.sublist(0, trailerStart),
      algorithm: checksumAlgorithm,
    );
    final actualChecksum = GitObjectId.fromBytes(bytes.sublist(trailerStart));
    if (expectedChecksum != actualChecksum) {
      throw FormatException(
        'Git index checksum does not match the index contents.',
        actualChecksum.hex,
      );
    }

    return GitIndex(
      version: version,
      checksumAlgorithm: checksumAlgorithm,
      entries: entries,
      extensions: extensions,
      checksum: actualChecksum,
    );
  }

  Uint8List _encodeEntry(GitIndexEntry entry, {required int version}) {
    final pathBytes = utf8.encode(entry.path);
    final bytes = BytesBuilder();

    bytes.add(_encodeUint32(entry.ctimeSeconds));
    bytes.add(_encodeUint32(entry.ctimeNanoseconds));
    bytes.add(_encodeUint32(entry.mtimeSeconds));
    bytes.add(_encodeUint32(entry.mtimeNanoseconds));
    bytes.add(_encodeUint32(entry.device));
    bytes.add(_encodeUint32(entry.inode));
    bytes.add(_encodeUint32(entry.mode));
    bytes.add(_encodeUint32(entry.userId));
    bytes.add(_encodeUint32(entry.groupId));
    bytes.add(_encodeUint32(entry.fileSize));
    bytes.add(entry.objectId.toBytes());
    bytes.add(_encodeUint16(_encodeFlags(entry, pathBytes.length)));
    if (entry.requiresExtendedFlags) {
      bytes.add(_encodeUint16(_encodeExtendedFlags(entry)));
    }
    bytes.add(pathBytes);
    bytes.addByte(0);

    final entryBytes = bytes.takeBytes();
    if (version == 3) {
      return Uint8List.fromList(_padEntry(entryBytes));
    }
    return Uint8List.fromList(_padEntry(entryBytes));
  }

  GitIndexEntry _decodeEntry(
    archive.InputMemoryStream input, {
    required int version,
  }) {
    final entryStart = input.position;
    final ctimeSeconds = input.readUint32();
    final ctimeNanoseconds = input.readUint32();
    final mtimeSeconds = input.readUint32();
    final mtimeNanoseconds = input.readUint32();
    final device = input.readUint32();
    final inode = input.readUint32();
    final mode = input.readUint32();
    final userId = input.readUint32();
    final groupId = input.readUint32();
    final fileSize = input.readUint32();
    final objectId = GitObjectId.fromBytes(
      input.readBytes(checksumAlgorithm.digestLength).toUint8List(),
    );
    if (objectId.algorithm != checksumAlgorithm) {
      throw FormatException(
        'Git index object ids must use the codec checksum algorithm.',
        objectId.hex,
      );
    }

    final flags = input.readUint16();
    final assumeValid = (flags & 0x8000) != 0;
    final hasExtendedFlags = (flags & 0x4000) != 0;
    final stage = (flags >> 12) & 0x03;

    if (version == 2 && hasExtendedFlags) {
      throw const FormatException(
        'Version 2 git index entries cannot use extended flags.',
      );
    }

    var skipWorktree = false;
    var intentToAdd = false;
    if (hasExtendedFlags) {
      final extendedFlags = input.readUint16();
      if ((extendedFlags & 0x9fff) != 0) {
        throw FormatException(
          'Unsupported git index extended flags.',
          extendedFlags,
        );
      }
      skipWorktree = (extendedFlags & _skipWorktreeFlag) != 0;
      intentToAdd = (extendedFlags & _intentToAddFlag) != 0;
    }

    final pathBytes = <int>[];
    while (true) {
      final byte = input.readByte();
      if (byte == 0) {
        break;
      }
      pathBytes.add(byte);
    }

    final consumedLength = input.position - entryStart;
    final paddingLength = (8 - (consumedLength % 8)) % 8;
    if (paddingLength > 0) {
      final paddingBytes = input.readBytes(paddingLength).toUint8List();
      if (paddingBytes.any((byte) => byte != 0)) {
        throw const FormatException('Git index entry padding must be zero.');
      }
    }

    return GitIndexEntry(
      ctimeSeconds: ctimeSeconds,
      ctimeNanoseconds: ctimeNanoseconds,
      mtimeSeconds: mtimeSeconds,
      mtimeNanoseconds: mtimeNanoseconds,
      device: device,
      inode: inode,
      mode: mode,
      userId: userId,
      groupId: groupId,
      fileSize: fileSize,
      objectId: objectId,
      path: utf8.decode(pathBytes),
      assumeValid: assumeValid,
      stage: stage,
      skipWorktree: skipWorktree,
      intentToAdd: intentToAdd,
    );
  }

  Uint8List _encodeExtension(GitIndexExtension extension) {
    if (extension.signature.length != 4) {
      throw ArgumentError.value(
        extension.signature,
        'extension.signature',
        'Git index extension signatures must be 4 characters long.',
      );
    }

    final bytes = BytesBuilder();
    bytes.add(extension.signature.codeUnits);
    bytes.add(_encodeUint32(extension.data.length));
    bytes.add(extension.data);
    return bytes.takeBytes();
  }

  GitIndexExtension _decodeExtension(
    archive.InputMemoryStream input,
    int trailerStart,
  ) {
    final signature = input.readString(size: 4, utf8: false);
    final size = input.readUint32();
    if (input.position + size > trailerStart) {
      throw FormatException('Git index extension overruns the trailer.', size);
    }

    return GitIndexExtension(
      signature: signature,
      data: input.readBytes(size).toUint8List(),
    );
  }

  void _validateEntries(List<GitIndexEntry> entries, {required int version}) {
    GitIndexEntry? previousEntry;

    for (final entry in entries) {
      if (entry.objectId.algorithm != checksumAlgorithm) {
        throw ArgumentError.value(
          entry.objectId,
          'entry.objectId',
          'Git index entry object ids must use the codec checksum algorithm.',
        );
      }
      if (entry.path.isEmpty) {
        throw ArgumentError.value(
          entry.path,
          'entry.path',
          'Git index entry paths must not be empty.',
        );
      }
      if (entry.path.startsWith('/') ||
          entry.path.endsWith('/') ||
          entry.path.contains('\u0000')) {
        throw ArgumentError.value(
          entry.path,
          'entry.path',
          'Git index entry paths must be relative, non-empty paths without NUL bytes.',
        );
      }
      if (entry.stage < 0 || entry.stage > 3) {
        throw ArgumentError.value(
          entry.stage,
          'entry.stage',
          'Git index entry stages must be between 0 and 3.',
        );
      }
      if (version == 2 && entry.requiresExtendedFlags) {
        throw ArgumentError.value(
          entry,
          'index.entries',
          'Version 2 git indexes cannot encode extended entry flags.',
        );
      }

      if (previousEntry != null && _compareEntries(previousEntry, entry) >= 0) {
        throw ArgumentError.value(
          entries,
          'index.entries',
          'Git index entries must be sorted by path and stage with no duplicates.',
        );
      }
      previousEntry = entry;
    }
  }

  int _compareEntries(GitIndexEntry left, GitIndexEntry right) {
    final leftBytes = utf8.encode(left.path);
    final rightBytes = utf8.encode(right.path);
    final prefixLength = leftBytes.length < rightBytes.length
        ? leftBytes.length
        : rightBytes.length;

    for (var index = 0; index < prefixLength; index++) {
      final comparison = leftBytes[index] - rightBytes[index];
      if (comparison != 0) {
        return comparison;
      }
    }

    final lengthComparison = leftBytes.length - rightBytes.length;
    if (lengthComparison != 0) {
      return lengthComparison;
    }
    return left.stage - right.stage;
  }

  int _encodeFlags(GitIndexEntry entry, int pathLength) {
    final nameLength = pathLength < 0x0fff ? pathLength : 0x0fff;
    var value = nameLength;
    value |= entry.stage << 12;
    if (entry.requiresExtendedFlags) {
      value |= 0x4000;
    }
    if (entry.assumeValid) {
      value |= 0x8000;
    }
    return value;
  }

  int _encodeExtendedFlags(GitIndexEntry entry) {
    var value = 0;
    if (entry.skipWorktree) {
      value |= _skipWorktreeFlag;
    }
    if (entry.intentToAdd) {
      value |= _intentToAddFlag;
    }
    return value;
  }

  List<int> _padEntry(Uint8List entryBytes) {
    final paddingLength = (8 - (entryBytes.length % 8)) % 8;
    if (paddingLength == 0) {
      return entryBytes;
    }
    return [
      ...entryBytes,
      ...List<int>.filled(paddingLength, 0, growable: false),
    ];
  }

  Uint8List _encodeUint16(int value) {
    final byteData = ByteData(2)..setUint16(0, value, Endian.big);
    return byteData.buffer.asUint8List();
  }

  Uint8List _encodeUint32(int value) {
    final byteData = ByteData(4)..setUint32(0, value, Endian.big);
    return byteData.buffer.asUint8List();
  }
}

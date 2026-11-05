// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'dart:convert';
import 'dart:typed_data';

import 'package:virtual_git/src/git_hash_algorithm.dart';
import 'package:virtual_git/src/git_object_id.dart';
import 'package:virtual_git/src/git_tree.dart';

final class GitTreeCodec {
  const GitTreeCodec({this.algorithm = GitHashAlgorithm.sha1});

  final GitHashAlgorithm algorithm;

  Uint8List encode(Iterable<GitTreeEntry> entries) {
    final encoded = <int>[];
    for (final entry in entries) {
      if (entry.objectId.algorithm != algorithm) {
        throw ArgumentError.value(
          entry.objectId,
          'entries',
          'Tree entry object id algorithm must match the codec algorithm.',
        );
      }

      encoded
        ..addAll(ascii.encode('${entry.mode} '))
        ..addAll(entry.nameBytes)
        ..add(0)
        ..addAll(entry.objectId.toBytes());
    }
    return Uint8List.fromList(encoded);
  }

  List<GitTreeEntry> decode(List<int> bytes) {
    final entries = <GitTreeEntry>[];
    var index = 0;

    while (index < bytes.length) {
      final modeSeparatorIndex = bytes.indexOf(32, index);
      if (modeSeparatorIndex == -1) {
        throw const FormatException(
          'Tree entry is missing the mode separator.',
        );
      }

      final nameTerminatorIndex = bytes.indexOf(0, modeSeparatorIndex + 1);
      if (nameTerminatorIndex == -1) {
        throw const FormatException(
          'Tree entry is missing the name terminator.',
        );
      }

      final mode = ascii.decode(bytes.sublist(index, modeSeparatorIndex));
      final nameBytes = bytes.sublist(
        modeSeparatorIndex + 1,
        nameTerminatorIndex,
      );
      final objectIdStart = nameTerminatorIndex + 1;
      final objectIdEnd = objectIdStart + algorithm.digestLength;
      if (objectIdEnd > bytes.length) {
        throw const FormatException('Tree entry is missing object id bytes.');
      }

      entries.add(
        GitTreeEntry(
          mode: mode,
          nameBytes: nameBytes,
          objectId: GitObjectId.fromBytes(
            bytes.sublist(objectIdStart, objectIdEnd),
          ),
        ),
      );
      index = objectIdEnd;
    }

    return entries;
  }
}

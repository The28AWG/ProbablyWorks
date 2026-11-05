// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'dart:typed_data';

import 'package:virtual_git/src/git_hash_algorithm.dart';
import 'package:virtual_git/src/git_object.dart';
import 'package:virtual_git/src/git_object_id.dart';
import 'package:virtual_git/src/git_object_type.dart';

enum GitPackEntryType {
  commit(1, GitObjectType.commit),
  tree(2, GitObjectType.tree),
  blob(3, GitObjectType.blob),
  tag(4, GitObjectType.tag),
  offsetDelta(6, null),
  referenceDelta(7, null);

  const GitPackEntryType(this.code, this.objectType);

  final int code;
  final GitObjectType? objectType;

  bool get isDelta =>
      this == GitPackEntryType.offsetDelta ||
      this == GitPackEntryType.referenceDelta;

  static GitPackEntryType fromCode(int value) =>
      GitPackEntryType.values.firstWhere(
        (type) => type.code == value,
        orElse: () =>
            throw FormatException('Unsupported pack entry type.', value),
      );

  static GitPackEntryType fromObjectType(GitObjectType value) =>
      switch (value) {
        GitObjectType.commit => GitPackEntryType.commit,
        GitObjectType.tree => GitPackEntryType.tree,
        GitObjectType.blob => GitPackEntryType.blob,
        GitObjectType.tag => GitPackEntryType.tag,
      };
}

sealed class GitPackEntry {
  const GitPackEntry({
    required this.type,
    required this.objectSize,
    this.offset,
  });

  final GitPackEntryType type;
  final int objectSize;
  final int? offset;
}

final class GitPackObjectEntry extends GitPackEntry {
  GitPackObjectEntry(this.object, {super.offset})
    : super(
        type: GitPackEntryType.fromObjectType(object.type),
        objectSize: object.size,
      );

  final GitObject object;
}

final class GitPackOffsetDeltaEntry extends GitPackEntry {
  GitPackOffsetDeltaEntry({
    required this.baseOffsetDistance,
    required List<int> deltaBytes,
    required super.objectSize,
    super.offset,
  }) : deltaBytes = Uint8List.fromList(deltaBytes),
       super(type: GitPackEntryType.offsetDelta);

  final int baseOffsetDistance;
  final Uint8List deltaBytes;
}

final class GitPackReferenceDeltaEntry extends GitPackEntry {
  GitPackReferenceDeltaEntry({
    required this.baseObjectId,
    required List<int> deltaBytes,
    required super.objectSize,
    super.offset,
  }) : deltaBytes = Uint8List.fromList(deltaBytes),
       super(type: GitPackEntryType.referenceDelta);

  final GitObjectId baseObjectId;
  final Uint8List deltaBytes;
}

final class GitPack {
  const GitPack({
    this.version = 2,
    this.checksumAlgorithm = GitHashAlgorithm.sha1,
    this.entries = const [],
    this.checksum,
  });

  final int version;
  final GitHashAlgorithm checksumAlgorithm;
  final List<GitPackEntry> entries;
  final GitObjectId? checksum;
}

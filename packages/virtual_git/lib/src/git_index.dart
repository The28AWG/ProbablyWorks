// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'dart:convert';
import 'dart:typed_data';

import 'package:virtual_git/src/git_hash_algorithm.dart';
import 'package:virtual_git/src/git_object_id.dart';

final class GitIndexEntry {
  const GitIndexEntry({
    required this.ctimeSeconds,
    required this.ctimeNanoseconds,
    required this.mtimeSeconds,
    required this.mtimeNanoseconds,
    required this.device,
    required this.inode,
    required this.mode,
    required this.userId,
    required this.groupId,
    required this.fileSize,
    required this.objectId,
    required this.path,
    this.assumeValid = false,
    this.stage = 0,
    this.skipWorktree = false,
    this.intentToAdd = false,
  });
  static const int regularFileMode = 0x81a4;
  static const int executableFileMode = 0x81ed;
  static const int symbolicLinkMode = 0xa000;
  static const int gitLinkMode = 0xe000;

  final int ctimeSeconds;
  final int ctimeNanoseconds;
  final int mtimeSeconds;
  final int mtimeNanoseconds;
  final int device;
  final int inode;
  final int mode;
  final int userId;
  final int groupId;
  final int fileSize;
  final GitObjectId objectId;
  final String path;
  final bool assumeValid;
  final int stage;
  final bool skipWorktree;
  final bool intentToAdd;

  bool get requiresExtendedFlags => skipWorktree || intentToAdd;

  String get treeMode => switch (mode) {
    regularFileMode => '100644',
    executableFileMode => '100755',
    symbolicLinkMode => '120000',
    gitLinkMode => '160000',
    _ => throw StateError('Unsupported index entry mode: $mode'),
  };
}

final class GitIndexExtension {
  GitIndexExtension({required this.signature, required List<int> data})
    : data = Uint8List.fromList(data);

  final String signature;
  final Uint8List data;

  bool get isOptional {
    final firstCodeUnit = signature.codeUnitAt(0);
    return firstCodeUnit >= 0x41 && firstCodeUnit <= 0x5a;
  }
}

final class GitIndex {
  const GitIndex({
    this.version = 2,
    this.checksumAlgorithm = GitHashAlgorithm.sha1,
    this.entries = const [],
    this.extensions = const [],
    this.checksum,
  });

  final int version;
  final GitHashAlgorithm checksumAlgorithm;
  final List<GitIndexEntry> entries;
  final List<GitIndexExtension> extensions;
  final GitObjectId? checksum;

  int get objectCount => entries.length;

  GitIndexEntry? entryForPath(String path, {int stage = 0}) {
    for (final entry in entries) {
      if (entry.path == path && entry.stage == stage) {
        return entry;
      }
    }
    return null;
  }

  GitIndex withEntry(
    GitIndexEntry entry, {
    bool replaceConflictedStages = true,
  }) {
    final updatedEntries = <GitIndexEntry>[
      for (final existing in entries)
        if (!_shouldReplaceEntry(
          existing,
          entry,
          replaceConflictedStages: replaceConflictedStages,
        ))
          existing,
      entry,
    ]..sort(_compareEntries);

    return GitIndex(
      version: version,
      checksumAlgorithm: checksumAlgorithm,
      entries: updatedEntries,
      extensions: extensions,
    );
  }

  GitIndex withoutPath(String path, {int? stage}) {
    final updatedEntries = [
      for (final entry in entries)
        if (!(entry.path == path && (stage == null || entry.stage == stage)))
          entry,
    ];

    return GitIndex(
      version: version,
      checksumAlgorithm: checksumAlgorithm,
      entries: updatedEntries,
      extensions: extensions,
    );
  }

  static bool _shouldReplaceEntry(
    GitIndexEntry existing,
    GitIndexEntry replacement, {
    required bool replaceConflictedStages,
  }) {
    if (existing.path != replacement.path) {
      return false;
    }
    if (replaceConflictedStages) {
      return true;
    }
    return existing.stage == replacement.stage;
  }

  static int _compareEntries(GitIndexEntry left, GitIndexEntry right) {
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
}

// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'dart:async';

import 'package:virtual_git/src/git_delta_codec.dart';
import 'package:virtual_git/src/git_hash_algorithm.dart';
import 'package:virtual_git/src/git_object.dart';
import 'package:virtual_git/src/git_object_id.dart';
import 'package:virtual_git/src/git_pack.dart';

typedef GitExternalPackBaseResolver = FutureOr<GitObject?> Function(
  GitObjectId objectId,
);

final class GitPackResolvedEntry {
  const GitPackResolvedEntry({
    required this.packEntry,
    required this.object,
    required this.objectId,
  });

  final GitPackEntry packEntry;
  final GitObject object;
  final GitObjectId objectId;
}

final class GitPackResolver {
  const GitPackResolver({
    this.objectIdAlgorithm = GitHashAlgorithm.sha1,
    this.deltaCodec = const GitDeltaCodec(),
  });

  final GitHashAlgorithm objectIdAlgorithm;
  final GitDeltaCodec deltaCodec;

  Future<List<GitPackResolvedEntry>> resolve(
    GitPack pack, {
    GitExternalPackBaseResolver? externalBaseResolver,
  }) async {
    final resolvedEntries = <GitPackResolvedEntry>[];
    final resolvedByOffset = <int, GitPackResolvedEntry>{};
    final resolvedByObjectId = <GitObjectId, GitPackResolvedEntry>{};

    for (final entry in pack.entries) {
      final object = await _resolveObject(
        entry,
        resolvedByOffset: resolvedByOffset,
        resolvedByObjectId: resolvedByObjectId,
        externalBaseResolver: externalBaseResolver,
      );
      final resolvedEntry = GitPackResolvedEntry(
        packEntry: entry,
        object: object,
        objectId: object.id(algorithm: objectIdAlgorithm),
      );
      resolvedEntries.add(resolvedEntry);

      final offset = entry.offset;
      if (offset != null) {
        resolvedByOffset[offset] = resolvedEntry;
      }
      resolvedByObjectId[resolvedEntry.objectId] = resolvedEntry;
    }

    return resolvedEntries;
  }

  Future<GitObject> _resolveObject(
    GitPackEntry entry, {
    required Map<int, GitPackResolvedEntry> resolvedByOffset,
    required Map<GitObjectId, GitPackResolvedEntry> resolvedByObjectId,
    required GitExternalPackBaseResolver? externalBaseResolver,
  }) async {
    switch (entry) {
      case GitPackObjectEntry(:final object):
        return object;
      case GitPackOffsetDeltaEntry(
        :final baseOffsetDistance,
        :final deltaBytes,
        :final offset,
      ):
        if (offset == null) {
          throw StateError(
            'Offset delta pack entries require decoded pack offsets to resolve.',
          );
        }

        final baseEntry = resolvedByOffset[offset - baseOffsetDistance];
        if (baseEntry == null) {
          throw FormatException(
            'Offset delta base object could not be resolved.',
            offset - baseOffsetDistance,
          );
        }

        return GitObject(
          baseEntry.object.type,
          deltaCodec.apply(baseEntry.object.bytes, deltaBytes),
        );
      case GitPackReferenceDeltaEntry(:final baseObjectId, :final deltaBytes):
        final inPackBase = resolvedByObjectId[baseObjectId]?.object;
        final externalBase =
            inPackBase ?? await externalBaseResolver?.call(baseObjectId);
        if (externalBase == null) {
          throw FormatException(
            'Reference delta base object could not be resolved.',
            baseObjectId.hex,
          );
        }

        return GitObject(
          externalBase.type,
          deltaCodec.apply(externalBase.bytes, deltaBytes),
        );
    }
  }
}

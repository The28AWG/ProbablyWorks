// ignore_for_file: cascade_invocations
// ignore_for_file: avoid-substring
// Причина: разбор hex и каскады оставлены как в git_core.
part of '../git_repository.dart';

/// rev-parse, log, merge-base и обход предков.
extension GitRepositoryHistory on GitRepository {
  Future<GitObjectId?> revParse(
    String revision, {
    GitCommitCodec commitCodec = const GitCommitCodec(),
  }) async {
    final normalized = revision.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(
        revision,
        'revision',
        'Revision must not be empty.',
      );
    }

    final operatorMatch = RegExp(r'[\^~]').firstMatch(normalized);
    final baseSpec = operatorMatch == null
        ? normalized
        : normalized.substring(0, operatorMatch.start);
    var objectId = await _resolveRevisionBase(baseSpec);
    if (objectId == null || operatorMatch == null) {
      return objectId;
    }

    var cursor = operatorMatch.start;
    while (cursor < normalized.length) {
      if (objectId == null) {
        return null;
      }
      final operator = normalized[cursor];
      cursor++;

      final numberStart = cursor;
      while (cursor < normalized.length &&
          normalized.codeUnitAt(cursor) >= 0x30 &&
          normalized.codeUnitAt(cursor) <= 0x39) {
        cursor++;
      }

      final rawCount = normalized.substring(numberStart, cursor);
      switch (operator) {
        case '^':
          if (cursor < normalized.length && normalized[cursor] == '{') {
            final endBrace = normalized.indexOf('}', cursor);
            if (endBrace < 0) {
              throw FormatException(
                'Unclosed brace in revision suffix',
                revision,
              );
            }
            final braceName = normalized.substring(cursor + 1, endBrace);
            cursor = endBrace + 1;
            objectId = await _revParseBraceSuffix(
              objectId,
              braceName,
              codec: commitCodec,
            );
            continue;
          }
          final parentNumber = rawCount.isEmpty ? 1 : int.parse(rawCount);
          if (parentNumber == 0) {
            objectId = await _peelTagObjectId(objectId);
            continue;
          }
          objectId = await _resolveCommitParent(
            objectId,
            parentNumber,
            codec: commitCodec,
          );
        case '~':
          final generations = rawCount.isEmpty ? 1 : int.parse(rawCount);
          for (var index = 0; index < generations; index++) {
            if (objectId == null) {
              return null;
            }
            objectId = await _resolveCommitParent(
              objectId,
              1,
              codec: commitCodec,
            );
            if (objectId == null) {
              return null;
            }
          }
        default:
          throw FormatException(
            'Unsupported revision operator: $operator',
            revision,
          );
      }

      if (objectId == null) {
        return null;
      }
    }

    return objectId;
  }

  Future<GitObject?> show(
    String revision, {
    GitCommitCodec commitCodec = const GitCommitCodec(),
    GitLooseObjectCodec codec = const GitLooseObjectCodec(),
  }) async {
    final objectId = await revParse(revision, commitCodec: commitCodec);
    if (objectId == null) {
      return null;
    }
    return readObject(objectId, looseCodec: codec);
  }

  Future<List<GitLogEntry>> log(
    String revision, {
    int? maxCount,
    bool firstParent = false,
    GitCommitCodec commitCodec = const GitCommitCodec(),
  }) async {
    if (maxCount != null && maxCount < 0) {
      throw ArgumentError.value(
        maxCount,
        'maxCount',
        'Log maxCount must be greater than or equal to zero.',
      );
    }

    final commitId = await revParse(revision, commitCodec: commitCodec);
    if (commitId == null || maxCount == 0) {
      return const <GitLogEntry>[];
    }

    final entries = <GitLogEntry>[];
    final visited = <GitObjectId>{};
    final queue = <GitObjectId>[commitId];
    final commitCache = <GitObjectId, GitCommit>{};
    var cursor = 0;

    while (cursor < queue.length) {
      final currentCommitId = queue[cursor];
      cursor++;
      if (!visited.add(currentCommitId)) {
        continue;
      }

      final commit = await _readCommitCached(
        currentCommitId,
        codec: commitCodec,
        cache: commitCache,
      );
      entries.add(GitLogEntry(objectId: currentCommitId, commit: commit));
      if (maxCount != null && entries.length >= maxCount) {
        break;
      }

      final parents = firstParent && commit.parents.isNotEmpty
          ? [commit.parents.first]
          : commit.parents;
      queue.addAll(parents);
    }

    return entries;
  }

  /// Коммиты, достижимые из [tip], но не из [base] (как `git rev-list ^base tip`),
  /// в порядке от старых к новым (как `git log --reverse base..tip`).
  ///
  /// При [excludeMerges] merge-коммиты отбрасываются (как `git log --no-merges`
  /// у `git range-diff` по умолчанию); при `false` они остаются в списке, обход
  /// идёт по всем родителям — упрощение относительно git `--diff-merges`.
  Future<List<GitLogEntry>> revListAncestryPath({
    required String base,
    required String tip,
    bool excludeMerges = true,
    GitCommitCodec commitCodec = const GitCommitCodec(),
  }) async {
    final baseId = await revParse(base, commitCodec: commitCodec);
    final tipId = await revParse(tip, commitCodec: commitCodec);
    if (baseId == null || tipId == null) {
      return const [];
    }

    final cache = <GitObjectId, GitCommit>{};
    final baseReachable = await _collectAncestorDepths(
      baseId,
      codec: commitCodec,
      cache: cache,
    );
    final baseSet = baseReachable.keys.toSet();

    final order = <GitObjectId>[];
    final done = <GitObjectId>{};

    Future<void> dfsPost(GitObjectId id) async {
      if (baseSet.contains(id) || done.contains(id)) {
        return;
      }
      final commit = await _readCommitCached(
        id,
        codec: commitCodec,
        cache: cache,
      );
      final parents = excludeMerges && commit.parents.length > 1
          ? <GitObjectId>[commit.parents.first]
          : commit.parents;
      for (final parent in parents) {
        if (!baseSet.contains(parent)) {
          await dfsPost(parent);
        }
      }
      done.add(id);
      order.add(id);
    }

    await dfsPost(tipId);

    final out = <GitLogEntry>[];
    for (final id in order) {
      final commit = await _readCommitCached(
        id,
        codec: commitCodec,
        cache: cache,
      );
      if (excludeMerges && commit.parents.length > 1) {
        continue;
      }
      out.add(GitLogEntry(objectId: id, commit: commit));
    }
    return out;
  }

  Future<GitObjectId?> mergeBase(
    String leftRevision,
    String rightRevision, {
    GitCommitCodec commitCodec = const GitCommitCodec(),
  }) async {
    final leftCommitId = await revParse(leftRevision, commitCodec: commitCodec);
    final rightCommitId = await revParse(
      rightRevision,
      commitCodec: commitCodec,
    );
    if (leftCommitId == null || rightCommitId == null) {
      return null;
    }

    final commitCache = <GitObjectId, GitCommit>{};
    final leftDepths = await _collectAncestorDepths(
      leftCommitId,
      codec: commitCodec,
      cache: commitCache,
    );
    final rightDepths = await _collectAncestorDepths(
      rightCommitId,
      codec: commitCodec,
      cache: commitCache,
    );

    final commonAncestors = leftDepths.keys
        .where(rightDepths.containsKey)
        .toList(growable: false);
    if (commonAncestors.isEmpty) {
      return null;
    }

    final bestCommonAncestors = <GitObjectId>[];
    for (final candidate in commonAncestors) {
      var isBestCommonAncestor = true;
      for (final other in commonAncestors) {
        if (candidate == other) {
          continue;
        }
        if (await _isCommitAncestorOf(
          candidate,
          other,
          codec: commitCodec,
          cache: commitCache,
        )) {
          isBestCommonAncestor = false;
          break;
        }
      }
      if (isBestCommonAncestor) {
        bestCommonAncestors.add(candidate);
      }
    }

    final candidates = bestCommonAncestors.isEmpty
        ? commonAncestors
        : bestCommonAncestors;
    GitObjectId? bestCandidate;
    var bestDistance = 0;
    var bestTimestamp = 0;

    for (final candidate in candidates) {
      final combinedDistance = leftDepths[candidate]! + rightDepths[candidate]!;
      final commit = await _readCommitCached(
        candidate,
        codec: commitCodec,
        cache: commitCache,
      );
      final committerTimestamp = commit.committer.timestampSeconds;

      if (bestCandidate == null ||
          combinedDistance < bestDistance ||
          (combinedDistance == bestDistance &&
              committerTimestamp > bestTimestamp) ||
          (combinedDistance == bestDistance &&
              committerTimestamp == bestTimestamp &&
              candidate.hex.compareTo(bestCandidate.hex) < 0)) {
        bestCandidate = candidate;
        bestDistance = combinedDistance;
        bestTimestamp = committerTimestamp;
      }
    }

    return bestCandidate;
  }

  Future<Map<GitObjectId, int>> _collectAncestorDepths(
    GitObjectId startCommitId, {
    required GitCommitCodec codec,
    required Map<GitObjectId, GitCommit> cache,
  }) async {
    final depths = <GitObjectId, int>{};
    final queue = <({GitObjectId commitId, int depth})>[
      (commitId: startCommitId, depth: 0),
    ];
    var cursor = 0;

    while (cursor < queue.length) {
      final item = queue[cursor];
      cursor++;

      final currentDepth = depths[item.commitId];
      if (currentDepth != null && currentDepth <= item.depth) {
        continue;
      }
      depths[item.commitId] = item.depth;

      final commit = await _readCommitCached(
        item.commitId,
        codec: codec,
        cache: cache,
      );
      for (final parent in commit.parents) {
        queue.add((commitId: parent, depth: item.depth + 1));
      }
    }

    return depths;
  }

  Future<bool> _isCommitAncestorOf(
    GitObjectId ancestorCommitId,
    GitObjectId descendantCommitId, {
    required GitCommitCodec codec,
    required Map<GitObjectId, GitCommit> cache,
  }) async {
    final stack = <GitObjectId>[descendantCommitId];
    final visited = <GitObjectId>{};

    while (stack.isNotEmpty) {
      final currentCommitId = stack.removeLast();
      if (!visited.add(currentCommitId)) {
        continue;
      }
      if (currentCommitId == ancestorCommitId) {
        return true;
      }

      final commit = await _readCommitCached(
        currentCommitId,
        codec: codec,
        cache: cache,
      );
      stack.addAll(commit.parents);
    }

    return false;
  }

  Future<bool> _isCommitAncestorAcrossRepositories(
    GitObjectId ancestorCommitId,
    GitObjectId descendantCommitId, {
    required _GitRemoteTransport remoteTransport,
    required GitCommitCodec codec,
    required Map<GitObjectId, GitCommit> cache,
  }) async {
    final stack = <GitObjectId>[descendantCommitId];
    final visited = <GitObjectId>{};

    while (stack.isNotEmpty) {
      final currentCommitId = stack.removeLast();
      if (!visited.add(currentCommitId)) {
        continue;
      }
      if (currentCommitId == ancestorCommitId) {
        return true;
      }

      final commit = await _readCommitCachedAcrossRepositories(
        currentCommitId,
        remoteTransport: remoteTransport,
        codec: codec,
        cache: cache,
      );
      stack.addAll(commit.parents);
    }

    return false;
  }

  Future<GitObjectId?> _resolveRevisionBase(String baseSpec) async {
    final reflogMatch = RegExp(r'^(.*)@\{(\d+)\}$').firstMatch(baseSpec.trim());
    if (reflogMatch != null) {
      final reflogReference = reflogMatch.group(1)!;
      final entryIndex = int.parse(reflogMatch.group(2)!);
      final normalizedReflogReference = reflogReference.isEmpty
          ? 'HEAD'
          : GitRepositoryReferences._normalizeReflogReferenceName(
              reflogReference,
            );
      final reflogEntries = await reflog(
        referenceName: normalizedReflogReference,
      );
      if (entryIndex >= reflogEntries.length) {
        return null;
      }
      return reflogEntries[entryIndex].newObjectId;
    }

    if (GitObjectId.isValidHex(baseSpec)) {
      return GitObjectId.fromHex(baseSpec);
    }

    final directCandidates = [
      baseSpec,
      'refs/heads/$baseSpec',
      'refs/tags/$baseSpec',
      'refs/remotes/$baseSpec',
    ];
    for (final candidate in directCandidates) {
      final objectId = await resolveReferenceObjectId(candidate);
      if (objectId != null) {
        return objectId;
      }
    }
    return null;
  }

  Future<String> _currentBranchDisplayName() async {
    final headReference = await readReference('HEAD');
    final targetReferenceName = headReference?.targetReferenceName;
    if (targetReferenceName != null &&
        targetReferenceName.startsWith('refs/heads/')) {
      return GitRepositoryReferences._branchShortName(targetReferenceName);
    }

    final objectId = await resolveReferenceObjectId('HEAD');
    return objectId == null
        ? 'detached HEAD'
        : 'detached HEAD at ${objectId.hex}';
  }
}

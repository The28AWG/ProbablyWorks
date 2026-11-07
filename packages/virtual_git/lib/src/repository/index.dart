// ignore_for_file: cascade_invocations
// ignore_for_file: avoid-substring
// Причина: разбор hex и каскады оставлены как в git_core.
part of '../git_repository.dart';

/// Индекс, `add`, запись дерева и коммита.
extension GitRepositoryIndex on GitRepository {
  Future<GitIndex?> readIndex({
    GitIndexCodec codec = const GitIndexCodec(),
  }) async {
    final indexFile = File(indexFilePath);
    if (!await indexFile.exists()) {
      return null;
    }

    final bytes = await indexFile.readAsBytes();
    return codec.decode(bytes);
  }

  Future<void> writeIndex(
    GitIndex index, {
    GitIndexCodec codec = const GitIndexCodec(),
  }) async {
    final indexFile = File(indexFilePath);
    await indexFile.parent.create(recursive: true);
    await indexFile.writeAsBytes(codec.encode(index), flush: true);
  }

  Future<GitIndexEntry> createIndexEntryFromWorkTreePath(
    String relativePath, {
    GitHashAlgorithm algorithm = GitHashAlgorithm.sha1,
    int stage = 0,
    bool assumeValid = false,
    bool skipWorktree = false,
    bool intentToAdd = false,
  }) async {
    final absolutePath = resolveWorkTreePath(relativePath);
    final entityType = await FileSystemEntity.type(
      absolutePath,
      followLinks: false,
    );
    final stat = await FileStat.stat(absolutePath);

    late final GitObject object;
    late final int mode;
    late final int fileSize;

    switch (entityType) {
      case FileSystemEntityType.file:
        final rawBytes = await File(absolutePath).readAsBytes();
        final fileBytes = await _cleanWorkTreeBytes(relativePath, rawBytes);
        object = GitObject.blob(fileBytes);
        mode = GitRepositoryIndex._fileModeFromStat(stat);
        fileSize = fileBytes.length;
      case FileSystemEntityType.link:
        final targetPath = await Link(absolutePath).target();
        final targetBytes = targetPath.codeUnits;
        object = GitObject.blob(targetBytes);
        mode = GitIndexEntry.symbolicLinkMode;
        fileSize = targetBytes.length;
      case FileSystemEntityType.directory:
      case FileSystemEntityType.notFound:
        throw ArgumentError.value(
          relativePath,
          'relativePath',
          'Working tree entries must point to regular files or symbolic links.',
        );
    }

    final objectId = await writeLooseObject(object, algorithm: algorithm);
    return GitIndexEntry(
      ctimeSeconds: stat.changed.millisecondsSinceEpoch ~/ 1000,
      ctimeNanoseconds: (stat.changed.microsecondsSinceEpoch % 1000000) * 1000,
      mtimeSeconds: stat.modified.millisecondsSinceEpoch ~/ 1000,
      mtimeNanoseconds: (stat.modified.microsecondsSinceEpoch % 1000000) * 1000,
      device: stat.mode,
      inode: 0,
      mode: mode,
      userId: 0,
      groupId: 0,
      fileSize: fileSize,
      objectId: objectId,
      path: p.posix.normalize(p.relative(absolutePath, from: path)),
      assumeValid: assumeValid,
      stage: stage,
      skipWorktree: skipWorktree,
      intentToAdd: intentToAdd,
    );
  }

  Future<GitIndex> stageWorkTreePath(
    String relativePath, {
    GitIndex? index,
    GitHashAlgorithm algorithm = GitHashAlgorithm.sha1,
    bool assumeValid = false,
    bool skipWorktree = false,
    bool intentToAdd = false,
  }) async {
    final effectiveIndex =
        index ?? await readIndex() ?? GitIndex(checksumAlgorithm: algorithm);
    final entry = await createIndexEntryFromWorkTreePath(
      relativePath,
      algorithm: effectiveIndex.checksumAlgorithm,
      assumeValid: assumeValid,
      skipWorktree: skipWorktree,
      intentToAdd: intentToAdd,
    );
    final updatedIndex = effectiveIndex.withEntry(entry);
    await writeIndex(
      updatedIndex,
      codec: GitIndexCodec(checksumAlgorithm: updatedIndex.checksumAlgorithm),
    );
    return updatedIndex;
  }

  Future<GitIndex> add(
    Iterable<String> relativePaths, {
    GitIndex? index,
    GitHashAlgorithm algorithm = GitHashAlgorithm.sha1,
    bool assumeValid = false,
    bool skipWorktree = false,
    bool intentToAdd = false,
    bool includeIgnored = false,
  }) async {
    var currentIndex =
        index ?? await readIndex() ?? GitIndex(checksumAlgorithm: algorithm);

    final pathsToStage = <String>{};
    final pathsToRemove = <String>{};

    for (final relativePath in relativePaths) {
      final targets = await _collectAddTargetsForPathspec(
        relativePath,
        currentIndex,
        includeIgnored: includeIgnored,
      );
      pathsToStage.addAll(targets.pathsToStage);
      pathsToRemove.addAll(targets.pathsToRemove);
    }

    for (final path in pathsToRemove.toList()..sort()) {
      currentIndex = currentIndex.withoutPath(path);
    }

    for (final path in pathsToStage.toList()..sort()) {
      final entry = await createIndexEntryFromWorkTreePath(
        path,
        algorithm: currentIndex.checksumAlgorithm,
        assumeValid: assumeValid,
        skipWorktree: skipWorktree,
        intentToAdd: intentToAdd,
      );
      currentIndex = currentIndex.withEntry(entry);
    }

    await writeIndex(
      currentIndex,
      codec: GitIndexCodec(checksumAlgorithm: currentIndex.checksumAlgorithm),
    );
    return currentIndex;
  }

  Future<GitObjectId> writeTreeFromIndex(
    GitIndex index, {
    GitTreeCodec? codec,
  }) async {
    final checkResult = checkWriteTreeFromIndex(index);
    if (!checkResult.canWrite) {
      final description = checkResult.conflicts
          .map(
            (conflict) =>
                '${conflict.path} (stages ${conflict.stages.join(', ')})',
          )
          .join(', ');
      throw StateError(
        'Cannot write a tree from an index with unmerged entries: '
        '$description.',
      );
    }

    final effectiveCodec =
        codec ?? GitTreeCodec(algorithm: index.checksumAlgorithm);
    return _writeTreeForPath(
      '',
      index.entries,
      algorithm: index.checksumAlgorithm,
      codec: effectiveCodec,
    );
  }

  GitWriteTreeCheckResult checkWriteTreeFromIndex(GitIndex index) {
    final groupedConflicts = GitRepositoryIndex._groupConflictedIndexEntries(
      index.entries,
    );
    return GitWriteTreeCheckResult(
      conflicts: [
        for (final path in groupedConflicts.keys.toList()..sort())
          GitWriteTreeConflict(
            path: path,
            stages: groupedConflicts[path]!.map((entry) => entry.stage).toList()
              ..sort(),
          ),
      ],
    );
  }

  Future<GitObjectId> writeCommit(
    GitCommit commit, {
    GitHashAlgorithm? algorithm,
    GitCommitCodec codec = const GitCommitCodec(),
  }) async {
    final effectiveAlgorithm = algorithm ?? commit.tree.algorithm;
    if (commit.tree.algorithm != effectiveAlgorithm ||
        commit.parents.any(
          (parent) => parent.algorithm != effectiveAlgorithm,
        )) {
      throw ArgumentError.value(
        commit,
        'commit',
        'Commit tree and parent object ids must use the selected hash algorithm.',
      );
    }

    final commitObject = GitObject.commit(codec.encode(commit));
    return writeLooseObject(commitObject, algorithm: effectiveAlgorithm);
  }

  Future<GitObjectId> writeCommitFromTree(
    GitObjectId tree, {
    required GitCommitSignature author,
    GitCommitSignature? committer,
    required String message,
    List<GitObjectId> parents = const [],
    List<GitCommitHeader> extraHeaders = const [],
    GitCommitCodec codec = const GitCommitCodec(),
  }) {
    final commit = GitCommit(
      tree: tree,
      parents: parents,
      author: author,
      committer: committer ?? author,
      message: message,
      extraHeaders: extraHeaders,
    );
    return writeCommit(commit, algorithm: tree.algorithm, codec: codec);
  }

  Future<GitObjectId> commitIndex(
    GitIndex index, {
    required GitCommitSignature author,
    GitCommitSignature? committer,
    required String message,
    String referenceName = 'HEAD',
    List<GitObjectId>? parents,
    List<GitCommitHeader> extraHeaders = const [],
    String reflogAction = 'commit',
    GitTreeCodec? treeCodec,
    GitCommitCodec commitCodec = const GitCommitCodec(),
  }) async {
    final treeId = await writeTreeFromIndex(index, codec: treeCodec);
    final resolvedParents =
        parents ?? [?await resolveReferenceObjectId(referenceName)];
    final commitId = await writeCommitFromTree(
      treeId,
      author: author,
      committer: committer,
      message: message,
      parents: resolvedParents,
      extraHeaders: extraHeaders,
      codec: commitCodec,
    );

    final writableReferenceName = await _resolveWritableReferenceName(
      referenceName,
    );
    final action = reflogAction == 'commit' && resolvedParents.isEmpty
        ? 'commit (initial)'
        : reflogAction;
    await _writeReferenceWithReflog(
      GitReference.direct(writableReferenceName, commitId),
      actor: committer ?? author,
      message:
          '$action: ${GitRepositoryReferences._summarizeReflogMessage(message)}',
    );
    return commitId;
  }

  Future<GitObjectId> commit({
    required GitCommitSignature author,
    GitCommitSignature? committer,
    required String message,
    String referenceName = 'HEAD',
    bool allowEmpty = false,
    GitIndex? index,
    List<GitObjectId>? parents,
    List<GitCommitHeader> extraHeaders = const [],
    String reflogAction = 'commit',
    GitTreeCodec? treeCodec,
    GitCommitCodec commitCodec = const GitCommitCodec(),
  }) async {
    final effectiveIndex = index ?? await readIndex() ?? const GitIndex();
    final treeId = await writeTreeFromIndex(effectiveIndex, codec: treeCodec);

    if (!allowEmpty) {
      final currentCommitId = await resolveReferenceObjectId(referenceName);
      final currentTreeId = currentCommitId == null
          ? null
          : await _readCommitTreeId(currentCommitId, codec: commitCodec);
      final hasStagedChanges = currentTreeId == null
          ? effectiveIndex.entries.isNotEmpty
          : treeId != currentTreeId;
      if (!hasStagedChanges) {
        throw StateError('No staged changes to commit.');
      }
    }

    return commitIndex(
      effectiveIndex,
      author: author,
      committer: committer,
      message: message,
      referenceName: referenceName,
      parents: parents,
      extraHeaders: extraHeaders,
      reflogAction: reflogAction,
      treeCodec: treeCodec,
      commitCodec: commitCodec,
    );
  }

  Future<List<int>?> _readIndexFileBytesOrNull() async {
    final indexFile = File(indexFilePath);
    if (!await indexFile.exists()) {
      return null;
    }
    return indexFile.readAsBytes();
  }

  Future<void> _restoreIndexFileBytes(List<int>? bytes) async {
    final indexFile = File(indexFilePath);
    if (bytes == null) {
      if (await indexFile.exists()) {
        await indexFile.delete();
      }
      return;
    }
    await indexFile.parent.create(recursive: true);
    await indexFile.writeAsBytes(bytes, flush: true);
  }

  static GitConflictStageEntry? _toConflictStageEntry(
    List<GitIndexEntry>? entries,
    int stage,
  ) {
    if (entries == null) {
      return null;
    }
    for (final entry in entries) {
      if (entry.stage == stage) {
        return GitConflictStageEntry(
          stage: stage,
          objectId: entry.objectId,
          mode: entry.mode,
        );
      }
    }
    return null;
  }

  static Map<String, List<GitIndexEntry>> _groupConflictedIndexEntries(
    Iterable<GitIndexEntry> entries,
  ) {
    final grouped = <String, List<GitIndexEntry>>{};
    for (final entry in entries) {
      if (entry.stage == 0) {
        continue;
      }
      grouped.putIfAbsent(entry.path, () => []).add(entry);
    }
    for (final entry in grouped.values) {
      entry.sort((left, right) => left.stage - right.stage);
    }
    return grouped;
  }

  static GitConflictEntry _toConflictEntry(
    String path,
    List<GitIndexEntry> entries,
  ) => GitConflictEntry(
    path: path,
    base: GitRepositoryIndex._toConflictStageEntry(entries, 1),
    ours: GitRepositoryIndex._toConflictStageEntry(entries, 2),
    theirs: GitRepositoryIndex._toConflictStageEntry(entries, 3),
  );

  static GitIndexEntry? _preferredConflictIndexEntryForWorkTree(
    List<GitIndexEntry> entries,
  ) {
    for (final preferredStage in const [2, 3, 1]) {
      for (final entry in entries) {
        if (entry.stage == preferredStage) {
          return entry;
        }
      }
    }
    return entries.isEmpty ? null : entries.first;
  }

  static GitIndexEntry? _selectConflictIndexEntryForStagedDiff(
    _GitTreeSnapshotEntry? referenceEntry,
    List<GitIndexEntry> entries,
  ) {
    for (final preferredStage in const [2, 3, 1]) {
      for (final entry in entries) {
        if (entry.stage == preferredStage &&
            GitRepositoryIndex._compareIndexStatus(referenceEntry, entry) !=
                GitFileStatus.unchanged) {
          return entry;
        }
      }
    }
    return GitRepositoryIndex._preferredConflictIndexEntryForWorkTree(entries);
  }

  Future<({List<String> pathsToStage, List<String> pathsToRemove})>
  _collectAddTargetsForPathspec(
    String pathspec,
    GitIndex index, {
    required bool includeIgnored,
  }) async {
    if (!GitRepositoryStatus._hasPathspecWildcards(pathspec)) {
      final normalizedPath = _normalizeRelativeWorkTreePath(pathspec);
      return _collectAddTargets(
        normalizedPath,
        index,
        includeIgnored: includeIgnored,
      );
    }

    final trackedPaths = {
      for (final entry in index.entries)
        if (entry.stage == 0) entry.path,
    };
    final workTreePaths = await _listWorkTreeFilesInDirectory('.');
    final candidatePaths = <String>{...trackedPaths, ...workTreePaths}.toList()
      ..sort();

    final pathsToStage = <String>{};
    final pathsToRemove = <String>{};
    for (final path in candidatePaths) {
      if (!GitRepositoryStatus._pathMatchesPathspec(path, pathspec)) {
        continue;
      }
      if (!includeIgnored && !trackedPaths.contains(path)) {
        final ignoreMatches = await checkIgnore([path]);
        if (ignoreMatches.isNotEmpty) {
          continue;
        }
      }
      final targets = await _collectAddTargets(
        path,
        index,
        includeIgnored: includeIgnored,
      );
      pathsToStage.addAll(targets.pathsToStage);
      pathsToRemove.addAll(targets.pathsToRemove);
    }

    return (
      pathsToStage: pathsToStage.toList()..sort(),
      pathsToRemove: pathsToRemove.toList()..sort(),
    );
  }

  Future<({List<String> pathsToStage, List<String> pathsToRemove})>
  _collectAddTargets(
    String relativePath,
    GitIndex index, {
    required bool includeIgnored,
  }) async {
    final normalizedPath = _normalizeRelativeWorkTreePath(relativePath);
    final absolutePath = resolveWorkTreePath(normalizedPath);
    final entityType = await FileSystemEntity.type(
      absolutePath,
      followLinks: false,
    );
    final trackedPaths = {
      for (final entry in index.entries)
        if (entry.stage == 0) entry.path,
    };

    switch (entityType) {
      case FileSystemEntityType.file:
      case FileSystemEntityType.link:
        if (!includeIgnored && !trackedPaths.contains(normalizedPath)) {
          final ignoreMatches = await checkIgnore([normalizedPath]);
          if (ignoreMatches.isNotEmpty) {
            return (
              pathsToStage: const <String>[],
              pathsToRemove: const <String>[],
            );
          }
        }
        return (
          pathsToStage: [normalizedPath],
          pathsToRemove: const <String>[],
        );
      case FileSystemEntityType.directory:
        final workTreePaths = await _listWorkTreeFilesInDirectory(
          normalizedPath,
        );
        final pathsToStage = <String>[];
        for (final path in workTreePaths) {
          if (!includeIgnored && !trackedPaths.contains(path)) {
            final ignoreMatches = await checkIgnore([path]);
            if (ignoreMatches.isNotEmpty) {
              continue;
            }
          }
          pathsToStage.add(path);
        }
        final pathsToRemove = <String>[];
        for (final entry in index.entries) {
          if (!GitRepositoryStatus._pathEqualsOrWithin(
            entry.path,
            normalizedPath,
          )) {
            continue;
          }
          final entryType = await FileSystemEntity.type(
            resolveWorkTreePath(entry.path),
            followLinks: false,
          );
          if (entryType == FileSystemEntityType.notFound) {
            pathsToRemove.add(entry.path);
          }
        }
        if (workTreePaths.isEmpty && pathsToRemove.isEmpty) {
          throw ArgumentError.value(
            relativePath,
            'relativePath',
            'No stageable files were found for the requested path.',
          );
        }
        return (pathsToStage: pathsToStage, pathsToRemove: pathsToRemove);
      case FileSystemEntityType.notFound:
        final pathsToRemove = [
          for (final entry in index.entries)
            if (GitRepositoryStatus._pathEqualsOrWithin(
              entry.path,
              normalizedPath,
            ))
              entry.path,
        ];
        if (pathsToRemove.isEmpty) {
          throw ArgumentError.value(
            relativePath,
            'relativePath',
            'No tracked files matched the requested path.',
          );
        }
        return (pathsToStage: const <String>[], pathsToRemove: pathsToRemove);
    }
  }

  static GitFileStatus _compareIndexStatus(
    _GitTreeSnapshotEntry? headEntry,
    GitIndexEntry? indexEntry,
  ) {
    if (headEntry == null && indexEntry == null) {
      return GitFileStatus.unchanged;
    }
    if (headEntry == null) {
      return GitFileStatus.added;
    }
    if (indexEntry == null) {
      return GitFileStatus.deleted;
    }
    if (headEntry.objectId == indexEntry.objectId &&
        headEntry.mode == indexEntry.treeMode) {
      return GitFileStatus.unchanged;
    }
    return GitFileStatus.modified;
  }

  Future<void> _writeIndexForTreeEntries(
    Map<String, _GitTreeSnapshotEntry> targetTreeEntries, {
    required GitHashAlgorithm algorithm,
    required GitIndex currentIndex,
  }) async {
    final updatedIndex = await _buildIndexForTreeEntries(
      targetTreeEntries,
      algorithm: algorithm,
      currentIndex: currentIndex,
    );
    await writeIndex(
      updatedIndex,
      codec: GitIndexCodec(checksumAlgorithm: updatedIndex.checksumAlgorithm),
    );
  }

  Future<GitIndex> _buildIndexForTreeEntries(
    Map<String, _GitTreeSnapshotEntry> targetTreeEntries, {
    required GitHashAlgorithm algorithm,
    required GitIndex currentIndex,
  }) async {
    var updatedIndex = GitIndex(
      version: currentIndex.version,
      checksumAlgorithm: algorithm,
    );
    for (final path in targetTreeEntries.keys.toList()..sort()) {
      updatedIndex = updatedIndex.withEntry(
        await _createIndexEntryFromTreeSnapshot(path, targetTreeEntries[path]!),
      );
    }
    return updatedIndex;
  }

  Future<GitIndex> _buildIndexWithPathUpdates(
    GitIndex currentIndex, {
    required Set<String> candidatePaths,
    required Map<String, _GitTreeSnapshotEntry> replacementEntries,
    required GitHashAlgorithm algorithm,
  }) async {
    var updatedIndex = GitIndex(
      version: currentIndex.version,
      checksumAlgorithm: algorithm,
      entries: [
        for (final entry in currentIndex.entries)
          if (!candidatePaths.contains(entry.path)) entry,
      ],
    );
    for (final path in replacementEntries.keys.toList()..sort()) {
      updatedIndex = updatedIndex.withEntry(
        await _createIndexEntryFromTreeSnapshot(
          path,
          replacementEntries[path]!,
        ),
      );
    }
    return updatedIndex;
  }

  Future<GitIndex> _buildIndexWithConflictUpdates(
    GitIndex currentIndex, {
    required GitHashAlgorithm algorithm,
    required Set<String> resolvedCandidatePaths,
    required Map<String, _GitTreeSnapshotEntry> resolvedEntries,
    required Map<
      String,
      ({
        _GitTreeSnapshotEntry? baseEntry,
        _GitTreeSnapshotEntry? currentEntry,
        _GitTreeSnapshotEntry? incomingEntry,
      })
    >
    conflictEntries,
  }) async {
    var updatedIndex = GitIndex(
      version: currentIndex.version,
      checksumAlgorithm: algorithm,
      entries: [
        for (final entry in currentIndex.entries)
          if (!resolvedCandidatePaths.contains(entry.path) &&
              !conflictEntries.containsKey(entry.path))
            entry,
      ],
      extensions: currentIndex.extensions,
    );

    for (final path in resolvedCandidatePaths.toList()..sort()) {
      if (resolvedEntries[path] case final resolvedEntry?) {
        updatedIndex = updatedIndex.withEntry(
          await _createIndexEntryFromTreeSnapshot(path, resolvedEntry),
        );
      }
    }

    for (final path in conflictEntries.keys.toList()..sort()) {
      final conflict = conflictEntries[path]!;
      if (conflict.baseEntry case final baseEntry?) {
        updatedIndex = updatedIndex.withEntry(
          await _createIndexEntryFromTreeSnapshot(path, baseEntry, stage: 1),
          replaceConflictedStages: false,
        );
      }
      if (conflict.currentEntry case final currentEntry?) {
        updatedIndex = updatedIndex.withEntry(
          await _createIndexEntryFromTreeSnapshot(path, currentEntry, stage: 2),
          replaceConflictedStages: false,
        );
      }
      if (conflict.incomingEntry case final incomingEntry?) {
        updatedIndex = updatedIndex.withEntry(
          await _createIndexEntryFromTreeSnapshot(
            path,
            incomingEntry,
            stage: 3,
          ),
          replaceConflictedStages: false,
        );
      }
    }

    return updatedIndex;
  }

  Future<GitIndexEntry> _createIndexEntryFromTreeSnapshot(
    String relativePath,
    _GitTreeSnapshotEntry entry, {
    int stage = 0,
  }) async {
    final fileSize = (await _readBlobObjectBytes(entry.objectId)).length;

    return GitIndexEntry(
      ctimeSeconds: 0,
      ctimeNanoseconds: 0,
      mtimeSeconds: 0,
      mtimeNanoseconds: 0,
      device: 0,
      inode: 0,
      mode: switch (entry.mode) {
        '100644' => GitIndexEntry.regularFileMode,
        '100755' => GitIndexEntry.executableFileMode,
        '120000' => GitIndexEntry.symbolicLinkMode,
        _ => throw StateError(
          'Unsupported tree mode for checkout: ${entry.mode}.',
        ),
      },
      userId: 0,
      groupId: 0,
      fileSize: fileSize,
      objectId: entry.objectId,
      path: relativePath,
      stage: stage,
    );
  }

  Future<GitObjectId> _writeTreeForPath(
    String directoryPath,
    List<GitIndexEntry> entries, {
    required GitHashAlgorithm algorithm,
    required GitTreeCodec codec,
  }) async {
    final directEntries = <GitTreeEntry>[];
    final childDirectories = <String, List<GitIndexEntry>>{};

    for (final entry in entries) {
      final relativePath = directoryPath.isEmpty
          ? entry.path
          : p.posix.relative(entry.path, from: directoryPath);
      if (relativePath == '.' || relativePath.isEmpty) {
        continue;
      }

      final parts = p.posix.split(relativePath);
      if (parts.length == 1) {
        directEntries.add(
          GitTreeEntry.utf8(
            mode: entry.treeMode,
            name: parts.single,
            objectId: entry.objectId,
          ),
        );
        continue;
      }

      final childDirectoryPath = directoryPath.isEmpty
          ? parts.first
          : p.posix.join(directoryPath, parts.first);
      childDirectories.putIfAbsent(childDirectoryPath, () => []).add(entry);
    }

    for (final childDirectoryPath in childDirectories.keys.toList()..sort()) {
      final childTreeId = await _writeTreeForPath(
        childDirectoryPath,
        childDirectories[childDirectoryPath]!,
        algorithm: algorithm,
        codec: codec,
      );
      directEntries.add(
        GitTreeEntry.utf8(
          mode: '040000',
          name: p.posix.basename(childDirectoryPath),
          objectId: childTreeId,
        ),
      );
    }

    directEntries.sort(GitRepositoryIndex._compareTreeEntries);
    final treeObject = GitObject.tree(codec.encode(directEntries));
    return writeLooseObject(treeObject, algorithm: algorithm);
  }

  static int _fileModeFromStat(FileStat stat) {
    const executableMask = 0x49;
    if ((stat.mode & executableMask) != 0) {
      return GitIndexEntry.executableFileMode;
    }
    return GitIndexEntry.regularFileMode;
  }

  static int _compareTreeEntries(GitTreeEntry left, GitTreeEntry right) {
    final leftBytes = [
      ...left.nameBytes,
      if (GitRepositoryObjects._treeModeIsDirectory(left.mode)) 0x2f,
    ];
    final rightBytes = [
      ...right.nameBytes,
      if (GitRepositoryObjects._treeModeIsDirectory(right.mode)) 0x2f,
    ];
    final prefixLength = leftBytes.length < rightBytes.length
        ? leftBytes.length
        : rightBytes.length;

    for (var index = 0; index < prefixLength; index++) {
      final comparison = leftBytes[index] - rightBytes[index];
      if (comparison != 0) {
        return comparison;
      }
    }

    return leftBytes.length - rightBytes.length;
  }
}

// ignore_for_file: cascade_invocations
// ignore_for_file: avoid-substring
// Причина: разбор hex и каскады оставлены как в git_core.
part of '../git_repository.dart';

/// merge, continue и abort.
extension GitRepositoryMerge on GitRepository {
  Future<GitMergeResult> merge(
    String revision, {
    String referenceName = 'HEAD',
    GitCommitSignature? author,
    GitCommitSignature? committer,
    String? message,
    GitCommitCodec commitCodec = const GitCommitCodec(),
    GitTreeCodec? treeCodec,
  }) async {
    if (bare) {
      throw StateError('Bare repositories do not have a working tree.');
    }
    if (await _readMergeOperationState() != null) {
      throw StateError(
        'A merge recovery is already in progress. '
        'Use mergeContinue(...) or mergeAbort() first.',
      );
    }

    final incomingObjectId = await revParse(revision, commitCodec: commitCodec);
    if (incomingObjectId == null) {
      throw StateError('Could not resolve merge target: $revision.');
    }

    final writableReferenceName = await _resolveWritableReferenceName(
      referenceName,
    );
    final currentObjectId = await resolveReferenceObjectId(referenceName);
    final incomingEntries = await _readCommitTreeEntries(
      incomingObjectId,
      commitCodec: commitCodec,
      treeCodec: treeCodec,
    );

    if (currentObjectId == null) {
      final currentIndex = GitIndex(
        checksumAlgorithm: incomingObjectId.algorithm,
      );
      await _ensureCheckoutSafe(
        targetPaths: incomingEntries.keys.toSet(),
        currentIndex: currentIndex,
        commitCodec: commitCodec,
        treeCodec: treeCodec,
      );
      await _writeCheckoutTreeEntries(
        incomingEntries,
        currentIndex: currentIndex,
      );
      await _writeIndexForTreeEntries(
        incomingEntries,
        algorithm: incomingObjectId.algorithm,
        currentIndex: currentIndex,
      );
      await _writeReferenceWithReflog(
        GitReference.direct(writableReferenceName, incomingObjectId),
        actor: committer ?? author ?? _resolveReflogActor(null),
        message: 'merge ${revision.trim()}: fast-forward',
      );
      return GitMergeResult(
        status: GitMergeStatus.fastForward,
        referenceName: writableReferenceName,
        incomingObjectId: incomingObjectId,
        resultObjectId: incomingObjectId,
      );
    }

    if (currentObjectId == incomingObjectId) {
      return GitMergeResult(
        status: GitMergeStatus.alreadyUpToDate,
        referenceName: writableReferenceName,
        currentObjectId: currentObjectId,
        incomingObjectId: incomingObjectId,
        resultObjectId: currentObjectId,
      );
    }

    final commitCache = <GitObjectId, GitCommit>{};
    final currentIsAncestor = await _isCommitAncestorOf(
      currentObjectId,
      incomingObjectId,
      codec: commitCodec,
      cache: commitCache,
    );
    if (currentIsAncestor) {
      final currentEntries = await _readCommitTreeEntries(
        currentObjectId,
        commitCodec: commitCodec,
        treeCodec: treeCodec,
      );
      final currentIndex = await _readOrBuildIndexForTreeEntries(
        currentEntries,
        algorithm: currentObjectId.algorithm,
      );
      await _ensureCheckoutSafe(
        targetPaths: incomingEntries.keys.toSet(),
        currentIndex: currentIndex,
        commitCodec: commitCodec,
        treeCodec: treeCodec,
      );
      await _writeCheckoutTreeEntries(
        incomingEntries,
        currentIndex: currentIndex,
      );
      await _writeIndexForTreeEntries(
        incomingEntries,
        algorithm: incomingObjectId.algorithm,
        currentIndex: currentIndex,
      );
      await _writeReferenceWithReflog(
        GitReference.direct(writableReferenceName, incomingObjectId),
        actor: committer ?? author ?? _resolveReflogActor(null),
        message: 'merge ${revision.trim()}: fast-forward',
      );
      return GitMergeResult(
        status: GitMergeStatus.fastForward,
        referenceName: writableReferenceName,
        currentObjectId: currentObjectId,
        incomingObjectId: incomingObjectId,
        resultObjectId: incomingObjectId,
      );
    }

    final incomingIsAncestor = await _isCommitAncestorOf(
      incomingObjectId,
      currentObjectId,
      codec: commitCodec,
      cache: commitCache,
    );
    if (incomingIsAncestor) {
      return GitMergeResult(
        status: GitMergeStatus.alreadyUpToDate,
        referenceName: writableReferenceName,
        currentObjectId: currentObjectId,
        incomingObjectId: incomingObjectId,
        resultObjectId: currentObjectId,
      );
    }

    final baseObjectId = await mergeBase(
      currentObjectId.hex,
      incomingObjectId.hex,
      commitCodec: commitCodec,
    );

    final baseEntries = baseObjectId == null
        ? const <String, _GitTreeSnapshotEntry>{}
        : await _readCommitTreeEntries(
            baseObjectId,
            commitCodec: commitCodec,
            treeCodec: treeCodec,
          );
    final currentEntries = await _readCommitTreeEntries(
      currentObjectId,
      commitCodec: commitCodec,
      treeCodec: treeCodec,
    );
    final currentIndex = await _readOrBuildIndexForTreeEntries(
      currentEntries,
      algorithm: currentObjectId.algorithm,
    );
    final originalIndexBytes = await _readIndexFileBytesOrNull();
    final mergePlan = await _mergeTreeSnapshotEntries(
      baseEntries: baseEntries,
      currentEntries: currentEntries,
      incomingEntries: incomingEntries,
      algorithm: currentObjectId.algorithm,
    );

    await _ensureCheckoutSafe(
      targetPaths: mergePlan.entries.keys.toSet(),
      currentIndex: currentIndex,
      commitCodec: commitCodec,
      treeCodec: treeCodec,
    );

    if (mergePlan.files.any((file) => !file.merged)) {
      final conflictPaths = <String>{
        for (final file in mergePlan.files)
          if (!file.merged) file.path,
      };
      final resolvedCandidatePaths = <String>{
        ...baseEntries.keys,
        ...currentEntries.keys,
        ...incomingEntries.keys,
      }..removeAll(conflictPaths);
      final conflictEntries =
          <
            String,
            ({
              _GitTreeSnapshotEntry? baseEntry,
              _GitTreeSnapshotEntry? currentEntry,
              _GitTreeSnapshotEntry? incomingEntry,
            })
          >{
            for (final path in conflictPaths)
              path: (
                baseEntry: baseEntries[path],
                currentEntry: currentEntries[path],
                incomingEntry: incomingEntries[path],
              ),
          };
      final mergeMessage = message ?? 'Merge ${revision.trim()}\n';
      await _writeMergeOperationState(
        _GitMergeOperationState(
          referenceName: writableReferenceName,
          currentObjectId: currentObjectId,
          incomingObjectId: incomingObjectId,
          baseObjectId: baseObjectId,
          message: mergeMessage,
          originalIndexBytes: originalIndexBytes,
        ),
      );
      final conflictedIndex = await _buildIndexWithConflictUpdates(
        currentIndex,
        algorithm: currentObjectId.algorithm,
        resolvedCandidatePaths: resolvedCandidatePaths,
        resolvedEntries: mergePlan.entries,
        conflictEntries: conflictEntries,
      );
      await writeIndex(
        conflictedIndex,
        codec: GitIndexCodec(
          checksumAlgorithm: conflictedIndex.checksumAlgorithm,
        ),
      );
      await _restoreWorkTreePaths(
        candidatePaths: resolvedCandidatePaths,
        sourceEntries: {
          for (final entry in mergePlan.entries.entries)
            if (!conflictPaths.contains(entry.key)) entry.key: entry.value,
        },
      );
      return GitMergeResult(
        status: GitMergeStatus.conflict,
        referenceName: writableReferenceName,
        currentObjectId: currentObjectId,
        incomingObjectId: incomingObjectId,
        baseObjectId: baseObjectId,
        resultObjectId: currentObjectId,
        files: mergePlan.files,
      );
    }

    if (author == null) {
      throw StateError('Merge commits require an author signature.');
    }

    final mergedIndex = await _buildIndexForTreeEntries(
      mergePlan.entries,
      algorithm: currentObjectId.algorithm,
      currentIndex: currentIndex,
    );
    final treeId = await writeTreeFromIndex(mergedIndex, codec: treeCodec);
    final mergeCommitId = await writeCommitFromTree(
      treeId,
      author: author,
      committer: committer,
      message: message ?? 'Merge ${revision.trim()}\n',
      parents: [currentObjectId, incomingObjectId],
      codec: commitCodec,
    );

    await _writeCheckoutTreeEntries(
      mergePlan.entries,
      currentIndex: currentIndex,
    );
    await writeIndex(
      mergedIndex,
      codec: GitIndexCodec(checksumAlgorithm: mergedIndex.checksumAlgorithm),
    );
    await _writeReferenceWithReflog(
      GitReference.direct(writableReferenceName, mergeCommitId),
      actor: committer ?? author,
      message:
          'merge ${revision.trim()}: ${GitRepositoryReferences._summarizeReflogMessage(message ?? 'Merge ${revision.trim()}\n')}',
    );

    return GitMergeResult(
      status: GitMergeStatus.merged,
      referenceName: writableReferenceName,
      currentObjectId: currentObjectId,
      incomingObjectId: incomingObjectId,
      baseObjectId: baseObjectId,
      resultObjectId: mergeCommitId,
      files: mergePlan.files,
    );
  }

  Future<GitMergeResult> mergeContinue({
    required GitCommitSignature author,
    GitCommitSignature? committer,
    String? message,
    GitCommitCodec commitCodec = const GitCommitCodec(),
    GitTreeCodec? treeCodec,
  }) async {
    if (bare) {
      throw StateError('Bare repositories do not have a working tree.');
    }

    final state = await _readMergeOperationState();
    if (state == null) {
      throw StateError('No merge recovery is currently in progress.');
    }

    final currentIndex =
        await readIndex() ??
        GitIndex(checksumAlgorithm: state.currentObjectId.algorithm);
    final checkResult = checkWriteTreeFromIndex(currentIndex);
    if (!checkResult.canWrite) {
      final description = checkResult.conflicts
          .map(
            (conflict) =>
                '${conflict.path} (stages ${conflict.stages.join(', ')})',
          )
          .join(', ');
      throw StateError(
        'Cannot continue merge with unmerged entries: $description.',
      );
    }

    final treeId = await writeTreeFromIndex(currentIndex, codec: treeCodec);
    final mergeMessage = message ?? state.message;
    final mergeCommitId = await writeCommitFromTree(
      treeId,
      author: author,
      committer: committer,
      message: mergeMessage,
      parents: [state.currentObjectId, state.incomingObjectId],
      codec: commitCodec,
    );
    await _writeReferenceWithReflog(
      GitReference.direct(state.referenceName, mergeCommitId),
      actor: committer ?? author,
      message:
          'merge --continue: ${GitRepositoryReferences._summarizeReflogMessage(mergeMessage)}',
    );
    await _clearMergeOperationState();
    return GitMergeResult(
      status: GitMergeStatus.merged,
      referenceName: state.referenceName,
      currentObjectId: state.currentObjectId,
      incomingObjectId: state.incomingObjectId,
      baseObjectId: state.baseObjectId,
      resultObjectId: mergeCommitId,
    );
  }

  Future<GitMergeAbortResult> mergeAbort({
    GitCommitCodec commitCodec = const GitCommitCodec(),
    GitTreeCodec? treeCodec,
  }) async {
    if (bare) {
      throw StateError('Bare repositories do not have a working tree.');
    }

    final state = await _readMergeOperationState();
    if (state == null) {
      throw StateError('No merge recovery is currently in progress.');
    }

    final originalEntries = await _readCommitTreeEntries(
      state.currentObjectId,
      commitCodec: commitCodec,
      treeCodec: treeCodec,
    );
    final incomingEntries = await _readCommitTreeEntries(
      state.incomingObjectId,
      commitCodec: commitCodec,
      treeCodec: treeCodec,
    );
    final baseEntries = state.baseObjectId == null
        ? const <String, _GitTreeSnapshotEntry>{}
        : await _readCommitTreeEntries(
            state.baseObjectId!,
            commitCodec: commitCodec,
            treeCodec: treeCodec,
          );
    final candidatePaths = <String>{
      ...originalEntries.keys,
      ...incomingEntries.keys,
      ...baseEntries.keys,
    };
    await _restoreWorkTreePaths(
      candidatePaths: candidatePaths,
      sourceEntries: originalEntries,
    );
    await _restoreIndexFileBytes(state.originalIndexBytes);
    await _clearMergeOperationState();
    return GitMergeAbortResult(
      referenceName: state.referenceName,
      originalObjectId: state.currentObjectId,
      incomingObjectId: state.incomingObjectId,
      baseObjectId: state.baseObjectId,
    );
  }

  Future<void> _writeMergeOperationState(_GitMergeOperationState state) async {
    await writeReference(
      GitReference.direct('ORIG_HEAD', state.currentObjectId),
    );
    final mergeHeadFile = File(mergeHeadFilePath);
    await mergeHeadFile.parent.create(recursive: true);
    await mergeHeadFile.writeAsString(
      '${state.incomingObjectId.hex}\n',
      flush: true,
    );
    final mergeMessageFile = File(mergeMessageFilePath);
    await mergeMessageFile.parent.create(recursive: true);
    await mergeMessageFile.writeAsString(state.message, flush: true);
    final stateFile = File(mergeStateFilePath);
    await stateFile.parent.create(recursive: true);
    await stateFile.writeAsString(jsonEncode(state.toJson()), flush: true);
  }

  Future<_GitMergeOperationState?> _readMergeOperationState() async {
    final stateFile = File(mergeStateFilePath);
    if (!await stateFile.exists()) {
      return null;
    }
    final decoded =
        jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>;
    return _GitMergeOperationState.fromJson(decoded);
  }

  Future<void> _clearMergeOperationState() async {
    for (final path in [
      mergeHeadFilePath,
      mergeMessageFilePath,
      mergeStateFilePath,
    ]) {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  Future<
    ({
      Map<String, _GitTreeSnapshotEntry> entries,
      List<GitMergeFileResult> files,
    })
  >
  _mergeTreeSnapshotEntries({
    required Map<String, _GitTreeSnapshotEntry> baseEntries,
    required Map<String, _GitTreeSnapshotEntry> currentEntries,
    required Map<String, _GitTreeSnapshotEntry> incomingEntries,
    required GitHashAlgorithm algorithm,
  }) async {
    final mergedEntries = <String, _GitTreeSnapshotEntry>{};
    final fileResults = <GitMergeFileResult>[];
    final allPaths = <String>{
      ...baseEntries.keys,
      ...currentEntries.keys,
      ...incomingEntries.keys,
    }.toList()..sort();

    for (final path in allPaths) {
      final baseEntry = baseEntries[path];
      final currentEntry = currentEntries[path];
      final incomingEntry = incomingEntries[path];

      if (GitRepositoryMerge._treeSnapshotEntriesEqual(
        currentEntry,
        incomingEntry,
      )) {
        if (currentEntry != null) {
          mergedEntries[path] = currentEntry;
        }
        continue;
      }
      if (GitRepositoryMerge._treeSnapshotEntriesEqual(
        baseEntry,
        currentEntry,
      )) {
        if (incomingEntry != null) {
          mergedEntries[path] = incomingEntry;
        }
        continue;
      }
      if (GitRepositoryMerge._treeSnapshotEntriesEqual(
        baseEntry,
        incomingEntry,
      )) {
        if (currentEntry != null) {
          mergedEntries[path] = currentEntry;
        }
        continue;
      }

      final mergedPath = await _mergeTreeSnapshotPath(
        path,
        baseEntry: baseEntry,
        currentEntry: currentEntry,
        incomingEntry: incomingEntry,
        algorithm: algorithm,
      );
      if (mergedPath.entry case final entry?) {
        mergedEntries[path] = entry;
      }
      if (mergedPath.fileResult case final fileResult?) {
        fileResults.add(fileResult);
      }
    }

    fileResults.sort((left, right) => left.path.compareTo(right.path));
    return (entries: mergedEntries, files: fileResults);
  }

  Future<({_GitTreeSnapshotEntry? entry, GitMergeFileResult? fileResult})>
  _mergeTreeSnapshotPath(
    String path, {
    required _GitTreeSnapshotEntry? baseEntry,
    required _GitTreeSnapshotEntry? currentEntry,
    required _GitTreeSnapshotEntry? incomingEntry,
    required GitHashAlgorithm algorithm,
  }) async {
    if (baseEntry == null) {
      return (
        entry: null,
        fileResult: GitMergeFileResult(
          path: path,
          status: GitMergeFileStatus.conflict,
          message: 'Both sides added the path differently.',
        ),
      );
    }
    if (currentEntry == null || incomingEntry == null) {
      return (
        entry: null,
        fileResult: GitMergeFileResult(
          path: path,
          status: GitMergeFileStatus.conflict,
          message: 'Merge detected a delete/modify conflict for this path.',
        ),
      );
    }
    if (currentEntry.mode != incomingEntry.mode ||
        currentEntry.mode != baseEntry.mode) {
      return (
        entry: null,
        fileResult: GitMergeFileResult(
          path: path,
          status: GitMergeFileStatus.conflict,
          message:
              'Merge detected incompatible file mode changes on both sides.',
        ),
      );
    }
    if (!GitRepositoryMerge._isMergeTextMode(currentEntry.mode)) {
      return (
        entry: null,
        fileResult: GitMergeFileResult(
          path: path,
          status: GitMergeFileStatus.conflict,
          message:
              'Merge detected non-text changes on both sides of this path.',
        ),
      );
    }

    final baseText = await _readTreeSnapshotEntryText(baseEntry);
    final currentText = await _readTreeSnapshotEntryText(currentEntry);
    final incomingText = await _readTreeSnapshotEntryText(incomingEntry);
    if (baseText == null || currentText == null || incomingText == null) {
      return (
        entry: null,
        fileResult: GitMergeFileResult(
          path: path,
          status: GitMergeFileStatus.conflict,
          message:
              'Merge detected non-text changes on both sides of this path.',
        ),
      );
    }

    final mergeResult = GitRepositoryApply._threeWayMergeTexts(
      baseText: baseText,
      currentText: currentText,
      incomingText: incomingText,
    );
    if (mergeResult.conflicts.isNotEmpty) {
      return (
        entry: null,
        fileResult: GitMergeFileResult(
          path: path,
          status: GitMergeFileStatus.conflict,
          message: '3-way merge detected overlapping changes in this file.',
          conflicts: mergeResult.conflicts,
        ),
      );
    }

    final mergedEntry = mergeResult.mergedText == currentText
        ? currentEntry
        : mergeResult.mergedText == incomingText
        ? incomingEntry
        : _GitTreeSnapshotEntry(
            objectId: await writeLooseObject(
              GitObject.blob(utf8.encode(mergeResult.mergedText)),
              algorithm: algorithm,
            ),
            mode: currentEntry.mode,
          );
    return (
      entry: mergedEntry,
      fileResult: GitMergeFileResult(
        path: path,
        status: GitMergeFileStatus.merged,
        mergedText: mergeResult.mergedText,
      ),
    );
  }

  static bool _treeSnapshotEntriesEqual(
    _GitTreeSnapshotEntry? left,
    _GitTreeSnapshotEntry? right,
  ) {
    if (left == null || right == null) {
      return left == right;
    }
    return left.mode == right.mode && left.objectId == right.objectId;
  }

  static bool _isMergeTextMode(String mode) =>
      mode == '100644' || mode == '100755';

  Future<String?> _readTreeSnapshotEntryText(
    _GitTreeSnapshotEntry entry,
  ) async => GitRepositoryApply._decodeApplyText(
    await _readBlobObjectBytes(entry.objectId),
  );
}

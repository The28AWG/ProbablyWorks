// ignore_for_file: cascade_invocations
// ignore_for_file: avoid-substring
// Причина: разбор hex и каскады оставлены как в git_core.
part of '../git_repository.dart';

/// branch, checkout, reset, restore и worktree.
extension GitRepositoryBranch on GitRepository {
  Future<GitBranch> branch(
    String branchName, {
    String startPoint = 'HEAD',
    bool force = false,
    bool writeReflog = true,
    GitCommitSignature? reflogActor,
    GitCommitCodec commitCodec = const GitCommitCodec(),
  }) async {
    final referenceName = GitRepositoryReferences._normalizeBranchReferenceName(
      branchName,
    );
    final objectId = await revParse(startPoint, commitCodec: commitCodec);
    if (objectId == null) {
      throw StateError('Could not resolve branch start point: $startPoint.');
    }

    final existing = await readReference(referenceName);
    if (existing != null && !force) {
      throw StateError(
        'Branch already exists: ${GitRepositoryReferences._branchShortName(referenceName)}.',
      );
    }

    final reference = GitReference.direct(referenceName, objectId);
    final headReference = await readReference('HEAD');
    final startLabel = startPoint.trim() == 'HEAD'
        ? GitRepositoryReferences._branchShortName(
            headReference?.targetReferenceName ?? 'HEAD',
          )
        : startPoint.trim();
    final reflogMessage = force && existing != null
        ? 'branch: Reset to $startLabel'
        : 'branch: Created from $startLabel';
    // core.logAllRefUpdates=false не пишет журнал, пока нет --create-reflog.
    // По умолчанию журнал есть: так git ведёт себя в непустом рабочем дереве.
    if (writeReflog) {
      await _writeReferenceWithReflog(
        reference,
        actor: _resolveReflogActor(reflogActor),
        message: reflogMessage,
      );
    } else {
      await writeReference(reference);
    }
    return GitBranch(
      name: GitRepositoryReferences._branchShortName(referenceName),
      referenceName: referenceName,
      objectId: objectId,
      current: headReference?.targetReferenceName == referenceName,
    );
  }

  Future<List<GitBranch>> branches() async {
    final branchesDirectory = Directory(
      p.join(referenceDirectoryPath, 'heads'),
    );
    if (!await branchesDirectory.exists()) {
      return const <GitBranch>[];
    }

    final headReference = await readReference('HEAD');
    final currentReferenceName = headReference?.targetReferenceName;
    final branches = <GitBranch>[];

    await for (final entity in branchesDirectory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) {
        continue;
      }

      final relativeName = p.posix.joinAll(
        p.split(p.relative(entity.path, from: branchesDirectory.path)),
      );
      final referenceName = 'refs/heads/$relativeName';
      final objectId = await resolveReferenceObjectId(referenceName);
      if (objectId == null) {
        continue;
      }
      branches.add(
        GitBranch(
          name: relativeName,
          referenceName: referenceName,
          objectId: objectId,
          current: currentReferenceName == referenceName,
        ),
      );
    }

    branches.sort((left, right) => left.name.compareTo(right.name));
    return branches;
  }

  Future<GitCheckoutResult> checkout(
    String target, {
    bool create = false,
    String startPoint = 'HEAD',
    bool track = false,
    String? trackingRemoteName,
    bool force = false,
    String? detachedLabel,
    GitCommitSignature? reflogActor,
    GitCommitCodec commitCodec = const GitCommitCodec(),
    GitTreeCodec? treeCodec,
  }) async {
    if (bare) {
      throw StateError('Bare repositories do not have a working tree.');
    }

    final currentIndex = await readIndex() ?? const GitIndex();
    final targetReferenceName = create
        ? GitRepositoryReferences._normalizeBranchReferenceName(target)
        : await _resolveCheckoutBranchReferenceName(target);
    if (create) {
      await branch(
        targetReferenceName!,
        startPoint: startPoint,
        force: force,
        reflogActor: reflogActor,
        commitCodec: commitCodec,
      );
    }
    if (track && !create) {
      throw ArgumentError.value(
        create,
        'create',
        'Tracking config can only be set when checkout creates a branch.',
      );
    }

    final targetObjectId = targetReferenceName == null
        ? await revParse(target, commitCodec: commitCodec)
        : await resolveReferenceObjectId(targetReferenceName);
    if (targetObjectId == null) {
      throw StateError('Could not resolve checkout target: $target.');
    }

    final targetTreeEntries = await _readCommitTreeEntries(
      targetObjectId,
      commitCodec: commitCodec,
      treeCodec: treeCodec,
    );

    if (!force) {
      await _ensureCheckoutSafe(
        targetPaths: targetTreeEntries.keys.toSet(),
        currentIndex: currentIndex,
        commitCodec: commitCodec,
        treeCodec: treeCodec,
      );
    }

    await _writeCheckoutTreeEntries(
      targetTreeEntries,
      currentIndex: currentIndex,
    );
    await _writeIndexForTreeEntries(
      targetTreeEntries,
      algorithm: targetObjectId.algorithm,
      currentIndex: currentIndex,
    );

    final currentHeadReference = await readReference('HEAD');
    final currentHeadObjectId = await resolveReferenceObjectId('HEAD');
    if (targetReferenceName != null) {
      await _writeReferenceWithReflog(
        GitReference.symbolic('HEAD', targetReferenceName),
        actor: _resolveReflogActor(reflogActor),
        message:
            'checkout: moving from '
            '${GitRepositoryReferences._describeReflogLocation(currentHeadReference, currentHeadObjectId)} '
            'to ${GitRepositoryReferences._branchShortName(targetReferenceName)}',
      );
    } else {
      await _writeReferenceWithReflog(
        GitReference.direct('HEAD', targetObjectId),
        actor: _resolveReflogActor(reflogActor),
        message:
            'checkout: moving from '
            '${GitRepositoryReferences._describeReflogLocation(currentHeadReference, currentHeadObjectId)} '
            'to ${detachedLabel ?? targetObjectId.hex}',
      );
    }

    if (track && targetReferenceName != null) {
      final inferredTracking =
          GitRepositoryBranch._inferBranchTrackingForCheckout(
            targetReferenceName: targetReferenceName,
            startPoint: startPoint,
            trackingRemoteName: trackingRemoteName,
          );
      if (inferredTracking == null) {
        throw StateError(
          'checkout(..., track: true) requires a remote-tracking startPoint '
          'or an explicit trackingRemoteName.',
        );
      }
      await setBranchTracking(inferredTracking);
    }

    return GitCheckoutResult(
      objectId: targetObjectId,
      referenceName: targetReferenceName,
      detached: targetReferenceName == null,
    );
  }

  Future<GitResetResult> reset(
    String target, {
    String referenceName = 'HEAD',
    GitResetMode mode = GitResetMode.mixed,
    GitCommitSignature? reflogActor,
    GitCommitCodec commitCodec = const GitCommitCodec(),
    GitTreeCodec? treeCodec,
  }) async {
    final targetObjectId = await revParse(target, commitCodec: commitCodec);
    if (targetObjectId == null) {
      throw StateError('Could not resolve reset target: $target.');
    }

    if (mode == GitResetMode.hard && bare) {
      throw StateError('Bare repositories do not have a working tree.');
    }

    final writableReferenceName = await _resolveWritableReferenceName(
      referenceName,
    );
    if (mode != GitResetMode.soft) {
      final currentIndex =
          await readIndex() ??
          GitIndex(checksumAlgorithm: targetObjectId.algorithm);
      final targetTreeEntries = await _readCommitTreeEntries(
        targetObjectId,
        commitCodec: commitCodec,
        treeCodec: treeCodec,
      );
      if (mode == GitResetMode.hard) {
        await _writeCheckoutTreeEntries(
          targetTreeEntries,
          currentIndex: currentIndex,
        );
      }
      await _writeIndexForTreeEntries(
        targetTreeEntries,
        algorithm: targetObjectId.algorithm,
        currentIndex: currentIndex,
      );
    }

    await _writeReferenceWithReflog(
      GitReference.direct(writableReferenceName, targetObjectId),
      actor: _resolveReflogActor(reflogActor),
      message: 'reset: moving to ${target.trim()}',
    );
    return GitResetResult(
      objectId: targetObjectId,
      referenceName: writableReferenceName,
      mode: mode,
    );
  }

  Future<GitRestoreResult> restore(
    Iterable<String> relativePaths, {
    String? source,
    bool staged = false,
    bool workTree = true,
    GitCommitCodec commitCodec = const GitCommitCodec(),
    GitTreeCodec? treeCodec,
  }) async {
    if (!staged && !workTree) {
      throw ArgumentError.value(
        workTree,
        'workTree',
        'Restore must target the index, the working tree, or both.',
      );
    }
    if (workTree && bare) {
      throw StateError('Bare repositories do not have a working tree.');
    }

    final normalizedPaths =
        relativePaths.map(_normalizeRelativeWorkTreePath).toSet().toList()
          ..sort();
    if (normalizedPaths.isEmpty) {
      throw ArgumentError.value(
        relativePaths,
        'relativePaths',
        'Restore requires at least one path.',
      );
    }

    final currentIndex = await readIndex() ?? const GitIndex();
    final headEntries = await _readReferenceTreeEntries(
      'HEAD',
      commitCodec: commitCodec,
      treeCodec: treeCodec,
    );
    final effectiveSource = source ?? (staged ? 'HEAD' : null);
    final sourceSnapshot = effectiveSource == null
        ? null
        : await _readRevisionTreeEntries(
            effectiveSource,
            commitCodec: commitCodec,
            treeCodec: treeCodec,
          );
    final selectedSourceEntries = sourceSnapshot == null
        ? const <String, _GitTreeSnapshotEntry>{}
        : GitRepositoryTree._selectTreeEntries(
            sourceSnapshot.entries,
            normalizedPaths,
          );
    final selectedCurrentIndexEntries = GitRepositoryTree._selectTreeEntries(
      GitRepositoryTree._treeEntriesFromIndex(currentIndex),
      normalizedPaths,
    );
    final selectedHeadEntries = GitRepositoryTree._selectTreeEntries(
      headEntries,
      normalizedPaths,
    );

    var updatedIndex = currentIndex;
    final restoredPaths = <String>{};

    if (staged) {
      final stagedCandidatePaths = <String>{
        ...selectedSourceEntries.keys,
        ...selectedCurrentIndexEntries.keys,
        ...selectedHeadEntries.keys,
      };
      if (stagedCandidatePaths.isNotEmpty) {
        updatedIndex = await _buildIndexWithPathUpdates(
          currentIndex,
          candidatePaths: stagedCandidatePaths,
          replacementEntries: selectedSourceEntries,
          algorithm:
              sourceSnapshot?.algorithm ?? currentIndex.checksumAlgorithm,
        );
        await writeIndex(
          updatedIndex,
          codec: GitIndexCodec(
            checksumAlgorithm: updatedIndex.checksumAlgorithm,
          ),
        );
        restoredPaths.addAll(stagedCandidatePaths);
      }
    }

    if (workTree) {
      final workTreeSourceEntries = effectiveSource == null
          ? GitRepositoryTree._selectTreeEntries(
              GitRepositoryTree._treeEntriesFromIndex(updatedIndex),
              normalizedPaths,
            )
          : selectedSourceEntries;
      final workTreeCandidatePaths = <String>{
        ...workTreeSourceEntries.keys,
        ...selectedCurrentIndexEntries.keys,
        ...selectedHeadEntries.keys,
      };
      if (workTreeCandidatePaths.isNotEmpty) {
        await _restoreWorkTreePaths(
          candidatePaths: workTreeCandidatePaths,
          sourceEntries: workTreeSourceEntries,
        );
        restoredPaths.addAll(workTreeCandidatePaths);
      }
    }

    final restoredPathList = restoredPaths.toList()..sort();
    return GitRestoreResult(
      paths: restoredPathList,
      source: effectiveSource,
      staged: staged,
      workTree: workTree,
    );
  }

  Future<GitWorktreeResult> worktree(
    String workTreePath, {
    String startPoint = 'HEAD',
    String? branchName,
    bool dryRun = false,
    GitCommitSignature? reflogActor,
    GitCommitCodec commitCodec = const GitCommitCodec(),
    GitTreeCodec? treeCodec,
  }) async {
    final normalizedWorkTreePath = await _normalizeNewWorkTreePath(
      workTreePath,
    );
    final targetObjectId = await revParse(startPoint, commitCodec: commitCodec);
    if (targetObjectId == null) {
      throw StateError('Could not resolve worktree start point: $startPoint.');
    }

    final targetTreeEntries = await _readCommitTreeEntries(
      targetObjectId,
      commitCodec: commitCodec,
      treeCodec: treeCodec,
    );

    String? referenceName;
    if (branchName != null) {
      referenceName = GitRepositoryReferences._normalizeBranchReferenceName(
        branchName,
      );
      if (await readReference(referenceName) != null) {
        throw StateError(
          'Branch already exists: ${GitRepositoryReferences._branchShortName(referenceName)}.',
        );
      }
    }

    final worktreeId = await _allocateWorktreeId(normalizedWorkTreePath);
    final linkedGitDirectoryPath = p.join(worktreesDirectoryPath, worktreeId);
    if (await FileSystemEntity.type(linkedGitDirectoryPath) !=
        FileSystemEntityType.notFound) {
      throw StateError('Linked worktree admin directory already exists.');
    }

    final linkedRepository = GitRepository._(
      path: normalizedWorkTreePath,
      gitDirectoryPath: linkedGitDirectoryPath,
      commonDirectoryPath: commonDirectoryPath,
      bare: false,
    );
    final targetIndex = await linkedRepository._buildIndexForTreeEntries(
      targetTreeEntries,
      algorithm: targetObjectId.algorithm,
      currentIndex: GitIndex(checksumAlgorithm: targetObjectId.algorithm),
    );

    final workTreeRelativeGitPath = p.relative(
      linkedGitDirectoryPath,
      from: normalizedWorkTreePath,
    );
    final commonDirectoryRelativePath = p.relative(
      commonDirectoryPath,
      from: linkedGitDirectoryPath,
    );
    final gitFilePath = p.join(normalizedWorkTreePath, '.git');
    final headFileContents = referenceName == null
        ? '${targetObjectId.hex}\n'
        : 'ref: $referenceName\n';
    final metadataOperations = <GitWorktreeOperation>[
      GitWorktreeOperation(
        kind: GitWorktreeOperationKind.createDirectory,
        path: normalizedWorkTreePath,
      ),
      GitWorktreeOperation(
        kind: GitWorktreeOperationKind.createDirectory,
        path: worktreesDirectoryPath,
      ),
      GitWorktreeOperation(
        kind: GitWorktreeOperationKind.createDirectory,
        path: linkedGitDirectoryPath,
      ),
      GitWorktreeOperation(
        kind: GitWorktreeOperationKind.writeMetadataFile,
        path: gitFilePath,
      ),
      GitWorktreeOperation(
        kind: GitWorktreeOperationKind.writeMetadataFile,
        path: linkedRepository.headFilePath,
      ),
      GitWorktreeOperation(
        kind: GitWorktreeOperationKind.writeMetadataFile,
        path: p.join(linkedGitDirectoryPath, 'commondir'),
      ),
      GitWorktreeOperation(
        kind: GitWorktreeOperationKind.writeMetadataFile,
        path: p.join(linkedGitDirectoryPath, 'gitdir'),
      ),
      if (referenceName != null)
        GitWorktreeOperation(
          kind: GitWorktreeOperationKind.writeReference,
          path: resolveReferencePath(referenceName),
        ),
    ];
    final workTreeOperations = [
      for (final directoryPath in GitRepository._collectParentDirectories(
        targetTreeEntries.keys.toList(),
      ))
        GitWorktreeOperation(
          kind: GitWorktreeOperationKind.createDirectory,
          path: linkedRepository.resolveWorkTreePath(directoryPath),
        ),
      for (final relativePath in targetTreeEntries.keys.toList()..sort())
        GitWorktreeOperation(
          kind: GitWorktreeOperationKind.writeWorkTreeFile,
          path: linkedRepository.resolveWorkTreePath(relativePath),
        ),
    ];
    final operations = <GitWorktreeOperation>[
      ...metadataOperations,
      ...workTreeOperations,
      GitWorktreeOperation(
        kind: GitWorktreeOperationKind.writeIndex,
        path: linkedRepository.indexFilePath,
      ),
    ];
    final result = GitWorktreeResult(
      workTreePath: normalizedWorkTreePath,
      gitDirectoryPath: linkedGitDirectoryPath,
      commonDirectoryPath: commonDirectoryPath,
      objectId: targetObjectId,
      operations: operations,
      referenceName: referenceName,
      detached: referenceName == null,
      dryRun: dryRun,
    );
    if (dryRun) {
      return result;
    }

    try {
      await Directory(normalizedWorkTreePath).create(recursive: true);
      await Directory(worktreesDirectoryPath).create(recursive: true);
      await Directory(linkedGitDirectoryPath).create(recursive: true);
      await File(gitFilePath)
          .writeAsString('gitdir: $workTreeRelativeGitPath\n', flush: true);
      await File(linkedRepository.headFilePath)
          .writeAsString(headFileContents, flush: true);
      await File(p.join(linkedGitDirectoryPath, 'commondir'))
          .writeAsString('$commonDirectoryRelativePath\n', flush: true);
      await File(p.join(linkedGitDirectoryPath, 'gitdir'))
          .writeAsString('$gitFilePath\n', flush: true);
      if (referenceName != null) {
        await _writeReferenceWithReflog(
          GitReference.direct(referenceName, targetObjectId),
          actor: _resolveReflogActor(reflogActor),
          message: 'branch: Created from ${startPoint.trim()}',
        );
      }
      await linkedRepository._restoreWorkTreePaths(
        candidatePaths: targetTreeEntries.keys.toSet(),
        sourceEntries: targetTreeEntries,
      );
      await linkedRepository.writeIndex(
        targetIndex,
        codec: GitIndexCodec(checksumAlgorithm: targetIndex.checksumAlgorithm),
      );
    } catch (_) {
      await _rollbackWorktreeCreation(
        normalizedWorkTreePath,
        linkedGitDirectoryPath,
        referenceName: referenceName,
      );
      rethrow;
    }

    return result;
  }

  Future<String> _normalizeNewWorkTreePath(String workTreePath) async {
    final normalized = p.normalize(
      p.absolute(GitRepository._normalizePath(workTreePath)),
    );
    final entityType = await FileSystemEntity.type(
      normalized,
      followLinks: false,
    );
    if (entityType != FileSystemEntityType.notFound) {
      throw StateError('Worktree path already exists: $normalized.');
    }

    final currentPath = p.normalize(p.absolute(path));
    final sharedPath = p.normalize(p.absolute(commonDirectoryPath));
    if (GitRepository._pathsOverlap(normalized, currentPath) ||
        GitRepository._pathsOverlap(normalized, sharedPath)) {
      throw StateError(
        'Worktree path must not overlap the current repository layout.',
      );
    }

    return normalized;
  }

  Future<String> _allocateWorktreeId(String normalizedWorkTreePath) async {
    final baseName = p.basename(normalizedWorkTreePath);
    final sanitizedBaseName = GitRepositoryBranch._sanitizeWorktreeId(baseName);
    final worktreesDirectory = Directory(worktreesDirectoryPath);
    if (!await worktreesDirectory.exists()) {
      return sanitizedBaseName;
    }

    final existingNames = <String>{};
    await for (final entity in worktreesDirectory.list(
      recursive: false,
      followLinks: false,
    )) {
      existingNames.add(p.basename(entity.path));
    }
    if (!existingNames.contains(sanitizedBaseName)) {
      return sanitizedBaseName;
    }

    for (var suffix = 2; ; suffix++) {
      final candidate = '$sanitizedBaseName-$suffix';
      if (!existingNames.contains(candidate)) {
        return candidate;
      }
    }
  }

  Future<void> _rollbackWorktreeCreation(
    String workTreePath,
    String gitDirectoryPath, {
    String? referenceName,
  }) async {
    if (referenceName != null) {
      await deleteReference(referenceName);
    }

    final workTreeDirectory = Directory(workTreePath);
    if (await workTreeDirectory.exists()) {
      await workTreeDirectory.delete(recursive: true);
    }

    final gitDirectory = Directory(gitDirectoryPath);
    if (await gitDirectory.exists()) {
      await gitDirectory.delete(recursive: true);
    }

    await _deleteDirectoryIfEmpty(worktreesDirectoryPath);
  }

  Future<void> _deleteDirectoryIfEmpty(String directoryPath) async {
    final directory = Directory(directoryPath);
    if (!await directory.exists()) {
      return;
    }

    final children = await directory.list(followLinks: false).toList();
    if (children.isEmpty) {
      await directory.delete();
    }
  }

  static String _sanitizeWorktreeId(String value) {
    final normalized = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-');
    final trimmed = normalized.replaceAll(RegExp(r'^-+|-+$'), '');
    return trimmed.isEmpty ? 'worktree' : trimmed;
  }

  static GitBranchTracking? _inferBranchTrackingForCheckout({
    required String targetReferenceName,
    required String startPoint,
    String? trackingRemoteName,
  }) {
    final normalizedTrackingRemoteName =
        trackingRemoteName?.trim().isEmpty ?? true
        ? null
        : GitRepositoryConfig._normalizeRemoteName(trackingRemoteName!);
    final normalizedStartPoint = startPoint.trim();

    if (normalizedStartPoint.startsWith('refs/remotes/')) {
      final remainder = normalizedStartPoint.substring('refs/remotes/'.length);
      final separatorIndex = remainder.indexOf('/');
      if (separatorIndex <= 0 || separatorIndex == remainder.length - 1) {
        return null;
      }
      final remoteName =
          normalizedTrackingRemoteName ??
          GitRepositoryConfig._normalizeRemoteName(
            remainder.substring(0, separatorIndex),
          );
      final mergeReferenceName =
          'refs/heads/${remainder.substring(separatorIndex + 1)}';
      return GitBranchTracking(
        branchName: GitRepositoryReferences._branchShortName(
          targetReferenceName,
        ),
        referenceName: targetReferenceName,
        remoteName: remoteName,
        mergeReferenceName: mergeReferenceName,
      );
    }

    if (normalizedTrackingRemoteName == null) {
      return null;
    }
    return GitBranchTracking(
      branchName: GitRepositoryReferences._branchShortName(targetReferenceName),
      referenceName: targetReferenceName,
      remoteName: normalizedTrackingRemoteName,
      mergeReferenceName: targetReferenceName,
    );
  }

  Future<String?> _resolveCheckoutBranchReferenceName(String target) async {
    final referenceName = GitRepositoryReferences._normalizeBranchReferenceName(
      target,
    );
    final reference = await readReference(referenceName);
    if (reference == null) {
      return null;
    }
    return referenceName;
  }

  Future<void> _ensureCheckoutSafe({
    required Set<String> targetPaths,
    required GitIndex currentIndex,
    required GitCommitCodec commitCodec,
    GitTreeCodec? treeCodec,
  }) async {
    final currentStatus = await status(
      index: currentIndex,
      commitCodec: commitCodec,
      treeCodec: treeCodec,
    );
    final hasTrackedChanges = currentStatus.entries.any(
      (entry) =>
          entry.indexStatus != GitFileStatus.unchanged ||
          (entry.workTreeStatus != GitFileStatus.unchanged &&
              entry.workTreeStatus != GitFileStatus.untracked),
    );
    if (hasTrackedChanges) {
      throw StateError(
        'Cannot checkout with staged or unstaged tracked changes.',
      );
    }

    final trackedPaths = {
      for (final entry in currentIndex.entries)
        if (entry.stage == 0) entry.path,
    };
    final workTreePaths = await _listWorkTreeFilesInDirectory('.');
    final conflictingUntrackedPaths = <String>[
      for (final workTreePath in workTreePaths)
        if (!trackedPaths.contains(workTreePath) &&
            targetPaths.any(
              (targetPath) =>
                  GitRepositoryStatus._pathEqualsOrWithin(
                    workTreePath,
                    targetPath,
                  ) ||
                  GitRepositoryStatus._pathEqualsOrWithin(
                    targetPath,
                    workTreePath,
                  ),
            ))
          workTreePath,
    ]..sort();
    if (conflictingUntrackedPaths.isNotEmpty) {
      throw StateError(
        'Cannot checkout because untracked paths would be overwritten: '
        '${conflictingUntrackedPaths.first}.',
      );
    }
  }

  Future<void> _writeCheckoutTreeEntries(
    Map<String, _GitTreeSnapshotEntry> targetTreeEntries, {
    required GitIndex currentIndex,
  }) async {
    final currentTrackedPaths = {
      for (final entry in currentIndex.entries)
        if (entry.stage == 0) entry.path,
    };
    final targetPaths = targetTreeEntries.keys.toSet();

    final pathsToDelete = currentTrackedPaths.difference(targetPaths).toList()
      ..sort(
        (left, right) =>
            GitRepositoryStatus._comparePathDepthThenLexicographically(
              right,
              left,
            ),
      );
    for (final path in pathsToDelete) {
      await _deleteWorkTreePath(path);
    }

    final pathsToWrite = targetPaths.toList()
      ..sort(GitRepositoryStatus._comparePathDepthThenLexicographically);
    for (final path in pathsToWrite) {
      await _writeTreeSnapshotEntryToWorkTree(path, targetTreeEntries[path]!);
    }
  }

  Future<void> _deleteWorkTreePath(String relativePath) async {
    final absolutePath = resolveWorkTreePath(relativePath);
    final entityType = await FileSystemEntity.type(
      absolutePath,
      followLinks: false,
    );
    switch (entityType) {
      case FileSystemEntityType.file:
        await File(absolutePath).delete();
      case FileSystemEntityType.link:
        await Link(absolutePath).delete();
      case FileSystemEntityType.directory:
        await Directory(absolutePath).delete(recursive: true);
      case FileSystemEntityType.notFound:
        return;
    }

    await _deleteEmptyParentDirectories(relativePath);
  }

  Future<void> _deleteEmptyParentDirectories(String relativePath) async {
    var directoryPath = p.posix.dirname(relativePath);
    while (directoryPath != '.' && directoryPath.isNotEmpty) {
      final absoluteDirectoryPath = resolveWorkTreePath(directoryPath);
      final directory = Directory(absoluteDirectoryPath);
      if (!await directory.exists()) {
        directoryPath = p.posix.dirname(directoryPath);
        continue;
      }

      final children = await directory.list(followLinks: false).toList();
      if (children.isNotEmpty) {
        return;
      }

      await directory.delete();
      directoryPath = p.posix.dirname(directoryPath);
    }
  }
}

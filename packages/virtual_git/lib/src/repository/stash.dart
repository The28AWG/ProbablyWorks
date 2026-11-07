// ignore_for_file: cascade_invocations
// ignore_for_file: avoid-substring
// Причина: разбор hex и каскады оставлены как в git_core.
part of '../git_repository.dart';

/// Стек stash и его reflog.
extension GitRepositoryStash on GitRepository {
  Future<GitStashResult> stash({
    String? message,
    bool includeUntracked = false,
    bool keepIndex = false,
    GitCommitSignature? author,
    GitCommitSignature? committer,
    GitCommitCodec commitCodec = const GitCommitCodec(),
    GitTreeCodec? treeCodec,
  }) async {
    if (bare) {
      throw StateError('Bare repositories do not have a working tree.');
    }

    final baseObjectId = await resolveReferenceObjectId('HEAD');
    if (baseObjectId == null) {
      throw StateError('stash(...) requires HEAD to resolve to a commit.');
    }

    final effectiveAuthor = author ?? _resolveReflogActor(null);
    final effectiveCommitter = committer ?? effectiveAuthor;
    final currentIndex =
        await readIndex() ??
        GitIndex(checksumAlgorithm: baseObjectId.algorithm);
    final workTreeEntries = await _readWorkTreeEntries(
      effectiveIndex: currentIndex,
    );
    final currentStatus = await status(
      index: currentIndex,
      commitCodec: commitCodec,
      treeCodec: treeCodec,
    );

    final trackedPaths = <String>{
      for (final entry in currentStatus.entries)
        if (entry.workTreeStatus != GitFileStatus.untracked) entry.path,
    }.toList()..sort();
    final untrackedPaths = <String>[
      for (final entry in currentStatus.entries)
        if (entry.workTreeStatus == GitFileStatus.untracked) entry.path,
    ]..sort();
    if (trackedPaths.isEmpty && (!includeUntracked || untrackedPaths.isEmpty)) {
      return const GitStashResult(referenceName: 'refs/stash');
    }

    final baseCommit = await _readCommit(baseObjectId, codec: commitCodec);
    final branchName = await _currentBranchDisplayName();
    final headSummary = GitRepositoryStash._stashHeadSummary(
      baseObjectId.hex,
      GitRepositoryReferences._summarizeReflogMessage(baseCommit.message),
    );
    final stashMessage = GitRepositoryStash._buildStashMessage(
      branchName: branchName,
      message: message,
      defaultSummary: headSummary,
    );
    // Индексный коммит всегда описывает HEAD, а не текст -m.
    // У git у этого сообщения есть завершающий перевод строки, а у самого
    // stash-коммита его нет: хеш `Dropped refs/stash@{0}` зависит от этой разницы.
    final indexMessage = 'index on $branchName: $headSummary\n';
    final indexEntries = GitRepositoryTree._treeEntriesFromIndex(currentIndex);
    final trackedWorkTreeEntries = await _treeEntriesFromTrackedWorkTree(
      currentIndex,
      workTreeEntries,
    );
    final indexCommitId = await _writeSnapshotCommit(
      indexEntries,
      author: effectiveAuthor,
      committer: effectiveCommitter,
      message: indexMessage,
      parents: [baseObjectId],
      algorithm: baseObjectId.algorithm,
      treeCodec: treeCodec,
      commitCodec: commitCodec,
    );

    GitObjectId? untrackedCommitId;
    if (includeUntracked && untrackedPaths.isNotEmpty) {
      final untrackedEntries = await _selectWorkTreeSnapshotEntries(
        workTreeEntries,
        untrackedPaths,
      );
      if (untrackedEntries.isNotEmpty) {
        untrackedCommitId = await _writeSnapshotCommit(
          untrackedEntries,
          author: effectiveAuthor,
          committer: effectiveCommitter,
          message:
              'untracked files on $branchName: '
              '${GitRepositoryReferences._summarizeReflogMessage(stashMessage)}\n',
          parents: [baseObjectId],
          algorithm: baseObjectId.algorithm,
          treeCodec: treeCodec,
          commitCodec: commitCodec,
        );
      }
    }

    final stashCommitId = await _writeSnapshotCommit(
      trackedWorkTreeEntries,
      author: effectiveAuthor,
      committer: effectiveCommitter,
      message: stashMessage,
      parents: [baseObjectId, indexCommitId, ?untrackedCommitId],
      algorithm: baseObjectId.algorithm,
      treeCodec: treeCodec,
      commitCodec: commitCodec,
    );
    await _writeReferenceWithReflog(
      GitReference.direct('refs/stash', stashCommitId),
      actor: effectiveCommitter,
      message:
          'stash: ${GitRepositoryReferences._summarizeReflogMessage(stashMessage)}',
    );

    if (trackedPaths.isNotEmpty) {
      if (keepIndex) {
        await restore(
          trackedPaths,
          workTree: true,
          commitCodec: commitCodec,
          treeCodec: treeCodec,
        );
      } else {
        await restore(
          trackedPaths,
          source: 'HEAD',
          staged: true,
          workTree: true,
          commitCodec: commitCodec,
          treeCodec: treeCodec,
        );
      }
    }

    if (includeUntracked && untrackedPaths.isNotEmpty) {
      final sortedUntrackedPaths = untrackedPaths.toList()
        ..sort(
          (left, right) =>
              GitRepositoryStatus._comparePathDepthThenLexicographically(
                right,
                left,
              ),
        );
      for (final path in sortedUntrackedPaths) {
        await _deleteWorkTreePath(path);
      }
    }

    return GitStashResult(
      referenceName: 'refs/stash',
      stashObjectId: stashCommitId,
      baseObjectId: baseObjectId,
      indexObjectId: indexCommitId,
      untrackedObjectId: untrackedCommitId,
      message: stashMessage,
      trackedPaths: trackedPaths,
      untrackedPaths: includeUntracked ? untrackedPaths : const <String>[],
      includeUntracked: includeUntracked,
      keepIndex: keepIndex,
      created: true,
    );
  }

  Future<List<GitStashEntry>> stashList({
    bool newestFirst = true,
    GitCommitCodec commitCodec = const GitCommitCodec(),
    GitReflogCodec reflogCodec = const GitReflogCodec(),
  }) async {
    final stack = await _readStashStack(
      commitCodec: commitCodec,
      reflogCodec: reflogCodec,
    );
    final ordered = newestFirst ? stack : stack.reversed.toList();
    return [
      for (final entry in ordered)
        GitStashEntry(
          revision: entry.revision,
          referenceName: entry.referenceName,
          stashObjectId: entry.stashObjectId,
          baseObjectId: entry.baseObjectId,
          indexObjectId: entry.indexObjectId,
          untrackedObjectId: entry.untrackedObjectId,
          actor: entry.actor,
          message: entry.message,
          reflogMessage: entry.reflogMessage,
        ),
    ];
  }

  Future<GitStashDropResult> stashDrop({
    String revision = 'stash@{0}',
    GitCommitCodec commitCodec = const GitCommitCodec(),
    GitReflogCodec reflogCodec = const GitReflogCodec(),
  }) async {
    final stack = await _readStashStack(
      commitCodec: commitCodec,
      reflogCodec: reflogCodec,
    );
    final selection = GitRepositoryStash._selectStashStackEntry(
      stack,
      revision,
    );
    final remaining = <_GitStashStackEntry>[
      for (final entry in stack)
        if (entry.revision != selection.revision) entry,
    ];

    if (remaining.isEmpty) {
      await deleteReference('refs/stash');
      await _writeReflogEntries(
        'refs/stash',
        const <GitReflogEntry>[],
        codec: reflogCodec,
      );
    } else {
      await writeReference(
        GitReference.direct('refs/stash', remaining.first.stashObjectId),
      );
      await _rewriteStashReflog(remaining, codec: reflogCodec);
    }

    return GitStashDropResult(
      referenceName: selection.referenceName,
      revision: selection.revision,
      stashObjectId: selection.stashObjectId,
      newTopObjectId: remaining.isEmpty ? null : remaining.first.stashObjectId,
      remainingCount: remaining.length,
    );
  }

  Future<GitStashPopResult> stashPop({
    String revision = 'stash',
    bool reinstateIndex = false,
    GitCommitCodec commitCodec = const GitCommitCodec(),
    GitTreeCodec? treeCodec,
    GitReflogCodec reflogCodec = const GitReflogCodec(),
  }) async {
    final selection = GitRepositoryStash._selectStashStackEntry(
      await _readStashStack(commitCodec: commitCodec, reflogCodec: reflogCodec),
      revision,
    );
    final applyResult = await stashApply(
      revision: selection.revision,
      reinstateIndex: reinstateIndex,
      commitCodec: commitCodec,
      treeCodec: treeCodec,
    );

    late final GitStashPopStatus status;
    GitStashDropResult? dropResult;
    if (applyResult.status == GitStashApplyStatus.applied) {
      status = GitStashPopStatus.applied;
      dropResult = await stashDrop(
        revision: selection.revision,
        commitCodec: commitCodec,
        reflogCodec: reflogCodec,
      );
    } else {
      status = GitStashPopStatus.conflict;
    }

    return GitStashPopResult(
      status: status,
      referenceName: selection.referenceName,
      revision: selection.revision,
      stashObjectId: selection.stashObjectId,
      applyResult: applyResult,
      dropResult: dropResult,
    );
  }

  Future<GitStashApplyResult> stashApply({
    String revision = 'stash',
    bool reinstateIndex = false,
    GitCommitCodec commitCodec = const GitCommitCodec(),
    GitTreeCodec? treeCodec,
  }) async {
    if (bare) {
      throw StateError('Bare repositories do not have a working tree.');
    }

    final stashSelection = await _tryResolveStashSelection(
      revision,
      commitCodec: commitCodec,
    );
    final normalizedRevision = revision.trim() == 'stash'
        ? 'refs/stash'
        : revision.trim();
    final stashObjectId =
        stashSelection?.stashObjectId ??
        await revParse(normalizedRevision, commitCodec: commitCodec);
    if (stashObjectId == null) {
      throw StateError('Could not resolve stash revision: $revision.');
    }

    final stashCommit = await _readCommit(stashObjectId, codec: commitCodec);
    if (stashCommit.parents.length < 2) {
      throw StateError(
        'stashApply(...) requires a stash-style commit with index state.',
      );
    }

    final baseObjectId = stashCommit.parents.first;
    final indexObjectId = stashCommit.parents[1];
    final untrackedObjectId = stashCommit.parents.length > 2
        ? stashCommit.parents[2]
        : null;
    final baseEntries = await _readCommitTreeEntries(
      baseObjectId,
      commitCodec: commitCodec,
      treeCodec: treeCodec,
    );
    final stashEntries = await _readCommitTreeEntries(
      stashObjectId,
      commitCodec: commitCodec,
      treeCodec: treeCodec,
    );
    final untrackedEntries = untrackedObjectId == null
        ? const <String, _GitTreeSnapshotEntry>{}
        : await _readCommitTreeEntries(
            untrackedObjectId,
            commitCodec: commitCodec,
            treeCodec: treeCodec,
          );
    final conflictingPaths = <String>[];
    for (final path in untrackedEntries.keys.toList()..sort()) {
      final entityType = await FileSystemEntity.type(
        resolveWorkTreePath(path),
        followLinks: false,
      );
      if (entityType != FileSystemEntityType.notFound) {
        conflictingPaths.add(path);
      }
    }
    if (conflictingPaths.isNotEmpty) {
      return GitStashApplyResult(
        status: GitStashApplyStatus.conflict,
        referenceName: stashSelection?.referenceName ?? 'refs/stash',
        stashObjectId: stashObjectId,
        baseObjectId: baseObjectId,
        indexObjectId: indexObjectId,
        untrackedObjectId: untrackedObjectId,
        conflictingPaths: conflictingPaths,
      );
    }

    final applyResult = await apply(
      await _buildDiffEntriesFromTreeSnapshots(baseEntries, stashEntries),
      threeWay: true,
      recordConflictsInIndex: true,
      whitespaceMode: GitApplyWhitespaceMode.exact,
    );
    if (!applyResult.success) {
      return GitStashApplyResult(
        status: GitStashApplyStatus.conflict,
        referenceName: stashSelection?.referenceName ?? 'refs/stash',
        stashObjectId: stashObjectId,
        baseObjectId: baseObjectId,
        indexObjectId: indexObjectId,
        untrackedObjectId: untrackedObjectId,
        applyResult: applyResult,
      );
    }

    final restoredUntrackedPaths = <String>[];
    for (final path in untrackedEntries.keys.toList()..sort()) {
      await _writeTreeSnapshotEntryToWorkTree(path, untrackedEntries[path]!);
      restoredUntrackedPaths.add(path);
    }

    var indexRestored = false;
    if (reinstateIndex) {
      final currentIndex =
          await readIndex() ??
          GitIndex(checksumAlgorithm: baseObjectId.algorithm);
      final indexEntries = await _readCommitTreeEntries(
        indexObjectId,
        commitCodec: commitCodec,
        treeCodec: treeCodec,
      );
      final candidatePaths = <String>{
        ...baseEntries.keys,
        ...stashEntries.keys,
        ...indexEntries.keys,
      };
      final updatedIndex = await _buildIndexWithPathUpdates(
        currentIndex,
        candidatePaths: candidatePaths,
        replacementEntries: indexEntries,
        algorithm: currentIndex.checksumAlgorithm,
      );
      await writeIndex(
        updatedIndex,
        codec: GitIndexCodec(checksumAlgorithm: updatedIndex.checksumAlgorithm),
      );
      indexRestored = true;
    }

    return GitStashApplyResult(
      status: GitStashApplyStatus.applied,
      referenceName: stashSelection?.referenceName ?? 'refs/stash',
      stashObjectId: stashObjectId,
      baseObjectId: baseObjectId,
      indexObjectId: indexObjectId,
      untrackedObjectId: untrackedObjectId,
      applyResult: applyResult,
      restoredUntrackedPaths: restoredUntrackedPaths,
      indexRestored: indexRestored,
    );
  }

  Future<void> _rewriteStashReflog(
    List<_GitStashStackEntry> stack, {
    GitReflogCodec codec = const GitReflogCodec(),
  }) async {
    final reflogEntries = <GitReflogEntry>[];
    GitObjectId? previousObjectId;
    for (final entry in stack.reversed) {
      reflogEntries.add(
        GitReflogEntry(
          previousObjectId: previousObjectId,
          newObjectId: entry.stashObjectId,
          actor: entry.actor,
          message: entry.reflogMessage,
        ),
      );
      previousObjectId = entry.stashObjectId;
    }
    await _writeReflogEntries('refs/stash', reflogEntries, codec: codec);
  }

  Future<List<_GitStashStackEntry>> _readStashStack({
    required GitCommitCodec commitCodec,
    GitReflogCodec reflogCodec = const GitReflogCodec(),
  }) async {
    final reflogEntries = await reflog(
      referenceName: 'refs/stash',
      newestFirst: true,
      codec: reflogCodec,
    );
    final stack = <_GitStashStackEntry>[];

    for (var index = 0; index < reflogEntries.length; index++) {
      final reflogEntry = reflogEntries[index];
      final stashObjectId = reflogEntry.newObjectId;
      if (stashObjectId == null) {
        continue;
      }

      final stashCommit = await _readCommit(stashObjectId, codec: commitCodec);
      if (stashCommit.parents.length < 2) {
        throw StateError(
          'refs/stash contains a non-stash commit: $stashObjectId.',
        );
      }

      stack.add(
        _GitStashStackEntry(
          revision: 'stash@{$index}',
          referenceName: 'refs/stash',
          stashObjectId: stashObjectId,
          baseObjectId: stashCommit.parents.first,
          indexObjectId: stashCommit.parents[1],
          untrackedObjectId: stashCommit.parents.length > 2
              ? stashCommit.parents[2]
              : null,
          actor: reflogEntry.actor,
          message: stashCommit.message,
          reflogMessage: reflogEntry.message,
        ),
      );
    }

    return stack;
  }

  Future<_GitStashStackEntry?> _tryResolveStashSelection(
    String revision, {
    required GitCommitCodec commitCodec,
    GitReflogCodec reflogCodec = const GitReflogCodec(),
  }) async {
    final match = RegExp(r'^(?:refs/)?stash(?:@\{(\d+)\})?$')
        .firstMatch(revision.trim());
    if (match == null) {
      return null;
    }

    return GitRepositoryStash._selectStashStackEntry(
      await _readStashStack(commitCodec: commitCodec, reflogCodec: reflogCodec),
      revision,
    );
  }

  static _GitStashStackEntry _selectStashStackEntry(
    List<_GitStashStackEntry> stack,
    String revision,
  ) {
    final match = RegExp(r'^(?:refs/)?stash(?:@\{(\d+)\})?$')
        .firstMatch(revision.trim());
    if (match == null) {
      throw StateError('Could not resolve stash revision: $revision.');
    }

    final index = int.parse(match.group(1) ?? '0');
    if (index < 0 || index >= stack.length) {
      throw StateError('Could not resolve stash revision: $revision.');
    }
    return stack[index];
  }

  GitCommitSignature _resolveReflogActor(GitCommitSignature? actor) {
    if (actor != null) {
      return actor;
    }

    final environment = Platform.environment;
    final name =
        environment['GIT_COMMITTER_NAME'] ??
        environment['GIT_AUTHOR_NAME'] ??
        environment['USER'] ??
        environment['USERNAME'] ??
        'git_core';
    final email =
        environment['GIT_COMMITTER_EMAIL'] ??
        environment['GIT_AUTHOR_EMAIL'] ??
        '$name@localhost';
    return GitCommitSignature.fromDateTime(
      name: name,
      email: email,
      timestamp: DateTime.now(),
    );
  }

  /// `09784ed subject` — git ставит короткий хеш HEAD в текст stash и index.
  static String _stashHeadSummary(String hex, String subject) {
    final short = hex.length > 7 ? hex.substring(0, 7) : hex;
    return '$short $subject';
  }

  static String _buildStashMessage({
    required String branchName,
    required String? message,
    required String defaultSummary,
  }) {
    // Без -m git пишет «WIP on branch: subject». С -m — «On branch: message».
    if (message == null || message.trim().isEmpty) {
      return 'WIP on $branchName: $defaultSummary';
    }
    return 'On $branchName: ${message.trim()}';
  }
}

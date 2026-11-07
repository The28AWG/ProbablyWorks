// ignore_for_file: cascade_invocations
// ignore_for_file: avoid-substring
// Причина: разбор hex и каскады оставлены как в git_core.
part of '../git_repository.dart';

/// git apply: план записи, whitespace и трёхсторонний текст.
extension GitRepositoryApply on GitRepository {
  Future<GitApplyResult> apply(
    Iterable<GitDiffEntry> entries, {
    bool check = false,
    bool threeWay = false,
    bool recordConflictsInIndex = false,
    bool reject = false,
    int stripPathSegments = 0,
    GitApplyWhitespaceMode whitespaceMode = GitApplyWhitespaceMode.exact,
    GitApplyWhitespacePolicy whitespacePolicy = GitApplyWhitespacePolicy.warn,
    Set<String>? includePaths,
    Set<String>? excludePaths,
    int applyContextLines = 3,
    String? applyDirectoryPrefix,
    List<String>? patchWhitespaceStderr,
    bool whitespaceBlocked = false,
    int whitespaceFixedLineCount = 0,
    int whitespaceErrorLineCount = 0,
  }) async {
    if (bare) {
      throw StateError('Bare repositories do not have a working tree.');
    }
    if (await _readApplyOperationState() case final existingState?) {
      throw StateError(
        'An apply recovery is already in progress for: '
        '${existingState.conflictPaths.join(', ')}.',
      );
    }

    var orderedEntries = entries.toList()
      ..sort((left, right) => left.path.compareTo(right.path));
    orderedEntries = GitRepositoryApply._filterApplyEntries(
      orderedEntries,
      stripPathSegments: stripPathSegments,
      includePaths: includePaths,
      excludePaths: excludePaths,
      applyDirectoryPrefix: applyDirectoryPrefix,
    );
    if (orderedEntries.isEmpty) {
      return GitApplyResult(
        files: const [],
        check: check,
        stderrLines: patchWhitespaceStderr ?? const [],
        whitespaceBlocked: whitespaceBlocked,
        whitespaceFixedLineCount: whitespaceFixedLineCount,
        whitespaceErrorLineCount: whitespaceErrorLineCount,
      );
    }

    final fileResults = <GitApplyFileResult>[];
    final writePlans = <_GitApplyWritePlan>[];
    for (final entry in orderedEntries) {
      final plan = await _planApplyEntry(
        entry,
        threeWay: threeWay,
        whitespaceMode: whitespaceMode,
        applyContextLines: applyContextLines,
      );
      fileResults.add(plan.result);
      if (plan.writePlan case final writePlan?) {
        writePlans.add(writePlan);
      }
    }

    final stderrCombined = <String>[...?patchWhitespaceStderr];
    if (whitespacePolicy == GitApplyWhitespacePolicy.fix &&
        (patchWhitespaceStderr?.isNotEmpty ?? false) &&
        whitespaceFixedLineCount > 0) {
      stderrCombined.add(
        'warning: $whitespaceFixedLineCount line applied after fixing whitespace errors.',
      );
    }

    final result = GitApplyResult(
      files: fileResults,
      check: check,
      stderrLines: stderrCombined,
      whitespaceErrorLineCount: whitespaceErrorLineCount,
      whitespaceFixedLineCount: whitespaceFixedLineCount,
      whitespaceBlocked: whitespaceBlocked,
    );
    if (!result.success || check) {
      if (!check && recordConflictsInIndex && result.hasConflicts) {
        final originalIndexBytes = await _readIndexFileBytesOrNull();
        final currentIndex = await readIndex() ?? const GitIndex();
        final conflictingPaths = <String>{
          for (final file in fileResults)
            if (file.status == GitApplyStatus.conflict) file.path,
        };
        await _writeApplyOperationState(
          _GitApplyOperationState(
            conflictPaths: conflictingPaths.toList()..sort(),
            originalIndexBytes: originalIndexBytes,
          ),
        );
        try {
          await _writeApplyConflictsToIndex([
            for (final entry in orderedEntries)
              if (conflictingPaths.contains(entry.path)) entry,
          ], currentIndex: currentIndex);
        } catch (_) {
          await _clearApplyOperationState();
          rethrow;
        }
      }
      if (reject && result.hasConflicts) {
        await _writeApplyRejectFiles(orderedEntries, fileResults);
      }
      return result;
    }

    for (final writePlan in writePlans) {
      await _executeApplyWritePlan(writePlan);
    }

    return result;
  }

  Future<GitApplyResult> applyPatch(
    String patchText, {
    bool check = false,
    bool threeWay = false,
    bool recordConflictsInIndex = false,
    bool reject = false,
    GitDiffCodec codec = const GitDiffCodec(),
    int stripPathSegments = 0,
    GitApplyWhitespaceMode whitespaceMode = GitApplyWhitespaceMode.exact,
    GitApplyWhitespacePolicy whitespacePolicy = GitApplyWhitespacePolicy.warn,
    Set<String>? includePaths,
    Set<String>? excludePaths,
    int applyContextLines = 3,
    String? applyDirectoryPrefix,
    String patchFileLabel = 'p.patch',
  }) async {
    var text = patchText;
    var fixedCount = 0;
    List<String>? wsStderr;
    var wsBlocked = false;
    var errorCount = 0;
    if (whitespacePolicy != GitApplyWhitespacePolicy.nowarn) {
      final scan = GitRepositoryApply._scanPatchTrailingWhitespace(
        patchText,
        patchFileLabel: patchFileLabel,
      );
      wsStderr = [...scan.messages];
      errorCount = scan.errorLineCount;
      if (whitespacePolicy == GitApplyWhitespacePolicy.warn &&
          scan.errorLineCount > 0) {
        final n = scan.errorLineCount;
        final plural = n == 1 ? '' : 's';
        wsStderr.add('warning: $n line$plural adds whitespace errors.');
      }
      if (whitespacePolicy == GitApplyWhitespacePolicy.fix &&
          scan.errorLineCount > 0) {
        final fixed = GitRepositoryApply._fixPatchTrailingWhitespace(patchText);
        fixedCount = scan.errorLineCount;
        text = fixed;
      } else if ((whitespacePolicy == GitApplyWhitespacePolicy.error ||
              whitespacePolicy == GitApplyWhitespacePolicy.errorAll) &&
          scan.errorLineCount > 0) {
        final plural = scan.errorLineCount == 1 ? '' : 's';
        wsStderr = [
          ...scan.messages,
          'error: ${scan.errorLineCount} line$plural add${scan.errorLineCount == 1 ? 's' : ''} whitespace errors.',
        ];
        wsBlocked = true;
        return GitApplyResult(
          files: const [],
          check: check,
          stderrLines: wsStderr,
          whitespaceErrorLineCount: scan.errorLineCount,
          whitespaceBlocked: true,
        );
      }
    }

    return apply(
      codec.decode(text),
      check: check,
      threeWay: threeWay,
      recordConflictsInIndex: recordConflictsInIndex,
      reject: reject,
      stripPathSegments: stripPathSegments,
      whitespaceMode: whitespaceMode,
      whitespacePolicy: whitespacePolicy,
      includePaths: includePaths,
      excludePaths: excludePaths,
      applyContextLines: applyContextLines,
      applyDirectoryPrefix: applyDirectoryPrefix,
      patchWhitespaceStderr: wsStderr,
      whitespaceBlocked: wsBlocked,
      whitespaceFixedLineCount: fixedCount,
      whitespaceErrorLineCount: errorCount,
    );
  }

  /// Оставляет в патче только записи с путями после `-p` и фильтров include/exclude.
  static List<GitDiffEntry> _filterApplyEntries(
    List<GitDiffEntry> entries, {
    required int stripPathSegments,
    Set<String>? includePaths,
    Set<String>? excludePaths,
    String? applyDirectoryPrefix,
  }) {
    String stripLeading(String path, int count) {
      var result = path;
      for (var i = 0; i < count; i++) {
        final slash = result.indexOf('/');
        if (slash < 0) return '';
        result = result.substring(slash + 1);
      }
      return result;
    }

    final out = <GitDiffEntry>[];
    for (final entry in entries) {
      final stripped = stripLeading(entry.path, stripPathSegments);
      if (stripped.isEmpty) continue;
      final prefixed =
          applyDirectoryPrefix == null || applyDirectoryPrefix.isEmpty
          ? stripped
          : p.join(applyDirectoryPrefix, stripped);
      final normalizedPath = p.normalize(prefixed);
      if (includePaths != null &&
          includePaths.isNotEmpty &&
          !GitRepositoryApply._pathMatchesApplyFilter(stripped, includePaths)) {
        continue;
      }
      if (excludePaths != null &&
          excludePaths.isNotEmpty &&
          GitRepositoryApply._pathMatchesApplyFilter(stripped, excludePaths)) {
        continue;
      }
      if (stripPathSegments == 0 &&
          includePaths == null &&
          excludePaths == null &&
          applyDirectoryPrefix == null) {
        out.add(entry);
        continue;
      }
      out.add(
        GitDiffEntry(
          path: normalizedPath,
          changeType: entry.changeType,
          oldMode: entry.oldMode,
          newMode: entry.newMode,
          oldObjectId: entry.oldObjectId,
          newObjectId: entry.newObjectId,
          oldBytes: entry.oldBytes,
          newBytes: entry.newBytes,
          binary: entry.binary,
          hunks: entry.hunks,
          conflict: entry.conflict,
        ),
      );
    }
    return out;
  }

  static bool _pathMatchesApplyFilter(String path, Set<String> patterns) {
    for (final pattern in patterns) {
      if (pattern == path) return true;
      if (pattern.endsWith('/') && path.startsWith(pattern)) return true;
    }
    return false;
  }

  Future<GitApplyAbortResult> applyAbort() async {
    if (bare) {
      throw StateError('Bare repositories do not have a working tree.');
    }

    final state = await _readApplyOperationState();
    if (state == null) {
      throw StateError('No apply recovery is currently in progress.');
    }

    await _restoreIndexFileBytes(state.originalIndexBytes);
    await _clearApplyOperationState();
    return GitApplyAbortResult(
      conflictPaths: state.conflictPaths,
      indexRestored: true,
    );
  }

  Future<void> _writeApplyOperationState(_GitApplyOperationState state) async {
    final stateFile = File(applyStateFilePath);
    await stateFile.parent.create(recursive: true);
    await stateFile.writeAsString(jsonEncode(state.toJson()), flush: true);
  }

  Future<_GitApplyOperationState?> _readApplyOperationState() async {
    final stateFile = File(applyStateFilePath);
    if (!await stateFile.exists()) {
      return null;
    }
    final decoded =
        jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>;
    return _GitApplyOperationState.fromJson(decoded);
  }

  Future<void> _clearApplyOperationState() async {
    final stateFile = File(applyStateFilePath);
    if (await stateFile.exists()) {
      await stateFile.delete();
    }
  }

  Future<_GitApplyPlan> _planApplyEntry(
    GitDiffEntry entry, {
    required bool threeWay,
    required GitApplyWhitespaceMode whitespaceMode,
    required int applyContextLines,
  }) async {
    if (entry.binary) {
      return _planBinaryApplyEntry(entry);
    }

    if (!GitRepositoryApply._isSupportedApplyMode(entry.oldMode) ||
        !GitRepositoryApply._isSupportedApplyMode(entry.newMode)) {
      return _GitApplyPlan(
        result: GitApplyFileResult(
          path: entry.path,
          status: GitApplyStatus.conflict,
          message: 'Patch modes other than regular files, executables, and symlinks cannot be applied automatically.',
        ),
      );
    }

    final absolutePath = resolveWorkTreePath(entry.path);
    final entityType = await FileSystemEntity.type(
      absolutePath,
      followLinks: false,
    );
    if (entityType == FileSystemEntityType.directory) {
      return _GitApplyPlan(
        result: GitApplyFileResult(
          path: entry.path,
          status: GitApplyStatus.conflict,
          message: 'Patch application cannot replace a directory in-place.',
        ),
      );
    }

    final exists = entityType != FileSystemEntityType.notFound;
    if (entry.changeType == GitDiffChangeType.added && exists) {
      return _GitApplyPlan(
        result: GitApplyFileResult(
          path: entry.path,
          status: GitApplyStatus.conflict,
          message: 'Expected the target path to be absent before applying the patch.',
        ),
      );
    }
    if (entry.changeType != GitDiffChangeType.added && !exists) {
      return _GitApplyPlan(
        result: GitApplyFileResult(
          path: entry.path,
          status: GitApplyStatus.conflict,
          message:
              'Expected the target path to exist before applying the patch.',
        ),
      );
    }

    final currentBytes = exists
        ? await _readWorkTreeFileBytes(entry.path)
        : null;
    final currentText = currentBytes == null
        ? ''
        : GitRepositoryApply._decodeApplyText(currentBytes);
    if (currentText == null) {
      return _GitApplyPlan(
        result: GitApplyFileResult(
          path: entry.path,
          status: GitApplyStatus.conflict,
          message: 'Current file contents could not be interpreted as text for this patch.',
        ),
      );
    }

    final patchedText = GitRepositoryApply._applyDiffHunksToText(
      currentText,
      entry.hunks,
      whitespaceMode: whitespaceMode,
      applyContextLines: applyContextLines,
    );
    if (patchedText != null) {
      return _GitApplyPlan(
        result: GitApplyFileResult(
          path: entry.path,
          status: GitApplyStatus.applied,
          mergedText: patchedText,
        ),
        writePlan: _GitApplyWritePlan(
          path: entry.path,
          mode: entry.newMode,
          delete: entry.changeType == GitDiffChangeType.deleted,
          bytes: utf8.encode(patchedText),
        ),
      );
    }

    if (threeWay) {
      final threeWayPlan = await _planThreeWayApplyEntry(
        entry,
        currentText: currentText,
        whitespaceMode: whitespaceMode,
        applyContextLines: applyContextLines,
      );
      if (threeWayPlan != null) {
        return threeWayPlan;
      }
    }

    return _GitApplyPlan(
      result: GitApplyFileResult(
        path: entry.path,
        status: GitApplyStatus.conflict,
        message:
            'Current file contents did not match the expected patch context.',
      ),
    );
  }

  Future<_GitApplyPlan> _planBinaryApplyEntry(GitDiffEntry entry) async {
    final absolutePath = resolveWorkTreePath(entry.path);
    final entityType = await FileSystemEntity.type(
      absolutePath,
      followLinks: false,
    );
    if (entityType == FileSystemEntityType.directory) {
      return _GitApplyPlan(
        result: GitApplyFileResult(
          path: entry.path,
          status: GitApplyStatus.conflict,
          message: 'Patch application cannot replace a directory in-place.',
        ),
      );
    }

    final exists = entityType != FileSystemEntityType.notFound;
    final currentBytes = exists
        ? await _readWorkTreeFileBytes(entry.path)
        : null;
    final expectedOldBytes = await _resolveApplyBytes(
      entry.oldBytes,
      entry.oldObjectId,
    );
    final replacementBytes = await _resolveApplyBytes(
      entry.newBytes,
      entry.newObjectId,
    );

    switch (entry.changeType) {
      case GitDiffChangeType.added:
        if (exists) {
          return _GitApplyPlan(
            result: GitApplyFileResult(
              path: entry.path,
              status: GitApplyStatus.conflict,
              message: 'Expected the target path to be absent before applying the patch.',
            ),
          );
        }
        if (replacementBytes == null) {
          return _GitApplyPlan(
            result: GitApplyFileResult(
              path: entry.path,
              status: GitApplyStatus.conflict,
              message: 'Binary patch data was not available for this entry.',
            ),
          );
        }
      case GitDiffChangeType.modified:
        if (!exists) {
          return _GitApplyPlan(
            result: GitApplyFileResult(
              path: entry.path,
              status: GitApplyStatus.conflict,
              message: 'Expected the target path to exist before applying the patch.',
            ),
          );
        }
        if (expectedOldBytes == null || replacementBytes == null) {
          return _GitApplyPlan(
            result: GitApplyFileResult(
              path: entry.path,
              status: GitApplyStatus.conflict,
              message: 'Binary patch data was not available for this entry.',
            ),
          );
        }
        if (!GitRepositoryApply._listEquals(currentBytes, expectedOldBytes)) {
          return _GitApplyPlan(
            result: GitApplyFileResult(
              path: entry.path,
              status: GitApplyStatus.conflict,
              message: 'Current file contents did not match the expected binary base.',
            ),
          );
        }
      case GitDiffChangeType.deleted:
        if (!exists) {
          return _GitApplyPlan(
            result: GitApplyFileResult(
              path: entry.path,
              status: GitApplyStatus.conflict,
              message: 'Expected the target path to exist before applying the patch.',
            ),
          );
        }
        if (expectedOldBytes == null) {
          return _GitApplyPlan(
            result: GitApplyFileResult(
              path: entry.path,
              status: GitApplyStatus.conflict,
              message: 'Binary patch data was not available for this entry.',
            ),
          );
        }
        if (!GitRepositoryApply._listEquals(currentBytes, expectedOldBytes)) {
          return _GitApplyPlan(
            result: GitApplyFileResult(
              path: entry.path,
              status: GitApplyStatus.conflict,
              message: 'Current file contents did not match the expected binary base.',
            ),
          );
        }
    }

    return _GitApplyPlan(
      result: GitApplyFileResult(
        path: entry.path,
        status: GitApplyStatus.applied,
      ),
      writePlan: _GitApplyWritePlan(
        path: entry.path,
        mode: entry.newMode,
        delete: entry.changeType == GitDiffChangeType.deleted,
        bytes: replacementBytes,
      ),
    );
  }

  Future<List<int>?> _resolveApplyBytes(
    List<int>? capturedBytes,
    GitObjectId? objectId,
  ) async {
    if (capturedBytes != null) {
      return capturedBytes;
    }
    if (objectId == null) {
      return null;
    }
    return _readBlobObjectBytes(objectId);
  }

  Future<_GitApplyPlan?> _planThreeWayApplyEntry(
    GitDiffEntry entry, {
    required String currentText,
    required GitApplyWhitespaceMode whitespaceMode,
    required int applyContextLines,
  }) async {
    if (entry.changeType != GitDiffChangeType.modified ||
        entry.oldObjectId == null) {
      return null;
    }

    final baseBytes = await _readBlobObjectBytes(entry.oldObjectId!);
    final baseText = GitRepositoryApply._decodeApplyText(baseBytes);
    if (baseText == null) {
      return _GitApplyPlan(
        result: GitApplyFileResult(
          path: entry.path,
          status: GitApplyStatus.conflict,
          message: '3-way patch application could not decode the recorded base as text.',
        ),
      );
    }

    final incomingText = GitRepositoryApply._applyDiffHunksToText(
      baseText,
      entry.hunks,
      whitespaceMode: whitespaceMode,
      applyContextLines: applyContextLines,
    );
    if (incomingText == null) {
      return _GitApplyPlan(
        result: GitApplyFileResult(
          path: entry.path,
          status: GitApplyStatus.conflict,
          message: 'Patch hunks did not apply cleanly to their recorded base.',
        ),
      );
    }

    final mergeResult = GitRepositoryApply._threeWayMergeTexts(
      baseText: baseText,
      currentText: currentText,
      incomingText: incomingText,
    );
    if (mergeResult.conflicts.isNotEmpty) {
      return _GitApplyPlan(
        result: GitApplyFileResult(
          path: entry.path,
          status: GitApplyStatus.conflict,
          message:
              '3-way merge detected overlapping changes in the current file.',
          conflicts: mergeResult.conflicts,
        ),
      );
    }

    return _GitApplyPlan(
      result: GitApplyFileResult(
        path: entry.path,
        status: GitApplyStatus.applied,
        mergedText: mergeResult.mergedText,
      ),
      writePlan: _GitApplyWritePlan(
        path: entry.path,
        mode: entry.newMode,
        delete: false,
        bytes: utf8.encode(mergeResult.mergedText),
      ),
    );
  }

  static bool _isSupportedApplyMode(String? mode) => switch (mode) {
    null || '100644' || '100755' || '120000' => true,
    _ => false,
  };

  static String? _decodeApplyText(List<int> bytes) {
    if (bytes.contains(0)) {
      return null;
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }

  static bool _listEquals(List<int>? left, List<int>? right) {
    if (identical(left, right)) {
      return true;
    }
    if (left == null || right == null || left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) {
        return false;
      }
    }
    return true;
  }

  static String? _applyDiffHunksToText(
    String currentText,
    List<GitDiffHunk> hunks, {
    required GitApplyWhitespaceMode whitespaceMode,
    required int applyContextLines,
  }) {
    if (hunks.isEmpty) {
      return currentText;
    }

    final currentLines = GitRepositoryStatus._splitDiffLines(currentText);
    final resultLines = <String>[];
    var currentIndex = 0;

    for (final hunk
        in hunks.toList()..sort(GitRepositoryApply._compareDiffHunks)) {
      final expectedStart = hunk.oldStart == 0 ? 0 : hunk.oldStart - 1;
      if (expectedStart < currentIndex || expectedStart > currentLines.length) {
        return null;
      }

      resultLines.addAll(currentLines.sublist(currentIndex, expectedStart));
      currentIndex = expectedStart;

      for (final line in hunk.lines) {
        switch (line.type) {
          case GitDiffLineType.context:
            final match = GitRepositoryApply._matchApplyLine(
              currentLines,
              currentIndex,
              line.text,
              whitespaceMode: whitespaceMode,
              contextLimit: applyContextLines,
            );
            if (match == null) return null;
            currentIndex = match;
            resultLines.add(currentLines[currentIndex - 1]);
          case GitDiffLineType.deletion:
            final match = GitRepositoryApply._matchApplyLine(
              currentLines,
              currentIndex,
              line.text,
              whitespaceMode: whitespaceMode,
              contextLimit: applyContextLines,
            );
            if (match == null) return null;
            currentIndex = match;
          case GitDiffLineType.addition:
            resultLines.add(line.text);
        }
      }
    }

    resultLines.addAll(currentLines.sublist(currentIndex));
    return resultLines.join();
  }

  /// Находит строку файла, совпадающую с строкой патча, начиная с [fromIndex].
  /// Возвращает индекс сразу после совпавшей строки.
  static int? _matchApplyLine(
    List<String> lines,
    int fromIndex,
    String patchLine, {
    required GitApplyWhitespaceMode whitespaceMode,
    required int contextLimit,
  }) {
    if (whitespaceMode == GitApplyWhitespaceMode.exact) {
      if (fromIndex >= lines.length || lines[fromIndex] != patchLine) {
        return null;
      }
      return fromIndex + 1;
    }
    final maxScan = fromIndex + contextLimit;
    for (var i = fromIndex; i < lines.length && i <= maxScan; i++) {
      if (applyLinesEqual(lines[i], patchLine, whitespaceMode)) {
        return i + 1;
      }
    }
    return null;
  }

  static _GitThreeWayMergeResult _threeWayMergeTexts({
    required String baseText,
    required String currentText,
    required String incomingText,
  }) {
    final baseLines = GitRepositoryStatus._splitDiffLines(baseText);
    final currentChanges = GitRepositoryApply._extractTextChanges(
      baseText,
      currentText,
    );
    final incomingChanges = GitRepositoryApply._extractTextChanges(
      baseText,
      incomingText,
    );

    final conflicts = <GitApplyConflict>[];
    for (final currentChange in currentChanges) {
      for (final incomingChange in incomingChanges) {
        if (GitRepositoryApply._textChangesEquivalent(
          currentChange,
          incomingChange,
        )) {
          continue;
        }
        if (!GitRepositoryApply._textChangesConflict(
          currentChange,
          incomingChange,
        )) {
          continue;
        }

        final start = currentChange.baseStart < incomingChange.baseStart
            ? currentChange.baseStart
            : incomingChange.baseStart;
        final end = currentChange.baseEnd > incomingChange.baseEnd
            ? currentChange.baseEnd
            : incomingChange.baseEnd;
        conflicts.add(
          GitApplyConflict(
            startLine: start + 1,
            lineCount: end - start,
            baseText: baseLines.sublist(start, end).join(),
            currentText: GitRepositoryApply._renderChangeAgainstBaseSegment(
              baseLines,
              currentChange,
              start,
              end,
            ),
            incomingText: GitRepositoryApply._renderChangeAgainstBaseSegment(
              baseLines,
              incomingChange,
              start,
              end,
            ),
          ),
        );
      }
    }
    if (conflicts.isNotEmpty) {
      return _GitThreeWayMergeResult(
        mergedText: currentText,
        conflicts: conflicts,
      );
    }

    final mergedChanges = <_GitTextChange>[
      ...currentChanges,
      for (final incomingChange in incomingChanges)
        if (!currentChanges.any(
          (currentChange) => GitRepositoryApply._textChangesEquivalent(
            currentChange,
            incomingChange,
          ),
        ))
          incomingChange,
    ]..sort(GitRepositoryApply._compareTextChanges);

    final mergedLines = <String>[];
    var baseCursor = 0;
    for (final change in mergedChanges) {
      mergedLines.addAll(baseLines.sublist(baseCursor, change.baseStart));
      mergedLines.addAll(change.replacement);
      baseCursor = change.baseEnd;
    }
    mergedLines.addAll(baseLines.sublist(baseCursor));
    return _GitThreeWayMergeResult(
      mergedText: mergedLines.join(),
      conflicts: const [],
    );
  }

  static List<_GitTextChange> _extractTextChanges(
    String baseText,
    String updatedText,
  ) {
    final operations = GitRepositoryStatus._buildDiffOperations(
      GitRepositoryStatus._splitDiffLines(baseText),
      GitRepositoryStatus._splitDiffLines(updatedText),
    );

    final changes = <_GitTextChange>[];
    var baseCursor = 0;
    int? changeStart;
    var replacement = <String>[];

    void flushChange() {
      if (changeStart == null) {
        return;
      }
      changes.add(
        _GitTextChange(
          baseStart: changeStart!,
          baseEnd: baseCursor,
          replacement: List<String>.unmodifiable(replacement),
        ),
      );
      changeStart = null;
      replacement = <String>[];
    }

    for (final operation in operations) {
      switch (operation.type) {
        case GitDiffLineType.context:
          flushChange();
          baseCursor++;
        case GitDiffLineType.deletion:
          changeStart ??= baseCursor;
          baseCursor++;
        case GitDiffLineType.addition:
          changeStart ??= baseCursor;
          replacement.add(operation.text);
      }
    }
    flushChange();
    return changes;
  }

  static bool _textChangesEquivalent(
    _GitTextChange left,
    _GitTextChange right,
  ) {
    if (left.baseStart != right.baseStart || left.baseEnd != right.baseEnd) {
      return false;
    }
    if (left.replacement.length != right.replacement.length) {
      return false;
    }
    for (var index = 0; index < left.replacement.length; index++) {
      if (left.replacement[index] != right.replacement[index]) {
        return false;
      }
    }
    return true;
  }

  static bool _textChangesConflict(_GitTextChange left, _GitTextChange right) {
    final leftInsertion = left.baseStart == left.baseEnd;
    final rightInsertion = right.baseStart == right.baseEnd;
    if (leftInsertion && rightInsertion) {
      return left.baseStart == right.baseStart;
    }
    if (leftInsertion) {
      return left.baseStart == right.baseStart ||
          (left.baseStart > right.baseStart && left.baseStart < right.baseEnd);
    }
    if (rightInsertion) {
      return right.baseStart == left.baseStart ||
          (right.baseStart > left.baseStart && right.baseStart < left.baseEnd);
    }
    return left.baseStart < right.baseEnd && right.baseStart < left.baseEnd;
  }

  static String _renderChangeAgainstBaseSegment(
    List<String> baseLines,
    _GitTextChange change,
    int start,
    int end,
  ) => [
    ...baseLines.sublist(start, change.baseStart),
    ...change.replacement,
    ...baseLines.sublist(change.baseEnd, end),
  ].join();

  static int _compareTextChanges(_GitTextChange left, _GitTextChange right) {
    final startComparison = left.baseStart - right.baseStart;
    if (startComparison != 0) {
      return startComparison;
    }
    return left.baseEnd - right.baseEnd;
  }

  static int _compareDiffHunks(GitDiffHunk left, GitDiffHunk right) {
    final oldStartComparison = left.oldStart - right.oldStart;
    if (oldStartComparison != 0) {
      return oldStartComparison;
    }
    return left.newStart - right.newStart;
  }

  /// Один проход по тексту патча: хвостовые пробелы в строках `+` (как `git apply --whitespace`).
  static ({int errorLineCount, List<String> messages})
  _scanPatchTrailingWhitespace(
    String patchText, {
    String patchFileLabel = 'p.patch',
  }) {
    final lines = const LineSplitter().convert(patchText);
    final messages = <String>[];
    var count = 0;
    for (
      var patchLineNumber = 0;
      patchLineNumber < lines.length;
      patchLineNumber++
    ) {
      final raw = lines[patchLineNumber];
      if (raw.isEmpty || raw[0] != '+') {
        continue;
      }
      var payload = raw.substring(1);
      if (payload.endsWith('\r')) {
        payload = payload.substring(0, payload.length - 1);
      }
      if (payload == r'\ No newline at end of file') {
        continue;
      }
      if (GitRepositoryApply._patchLineHasTrailingWs(payload)) {
        count++;
        messages.add(
          '$patchFileLabel:${patchLineNumber + 1}: trailing whitespace.',
        );
      }
    }
    return (errorLineCount: count, messages: messages);
  }

  static bool _patchLineHasTrailingWs(String text) =>
      RegExp(r'[ \t]+$').hasMatch(text);

  static String _fixPatchTrailingWhitespace(String patchText) {
    final lines = const LineSplitter().convert(patchText);
    final out = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      if (line.isNotEmpty && line[0] == '+') {
        var payload = line.substring(1);
        final hadCr = payload.endsWith('\r');
        if (hadCr) {
          payload = payload.substring(0, payload.length - 1);
        }
        if (payload != r'\ No newline at end of file') {
          payload = payload.replaceAll(RegExp(r'[ \t]+$'), '');
        }
        line = '+$payload${hadCr ? '\r' : ''}';
      }
      out.writeln(line);
    }
    var result = out.toString();
    if (!patchText.endsWith('\n') && result.endsWith('\n')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  Future<void> _writeApplyRejectFiles(
    List<GitDiffEntry> entries,
    List<GitApplyFileResult> results,
  ) async {
    for (
      var index = 0;
      index < entries.length && index < results.length;
      index++
    ) {
      if (results[index].status != GitApplyStatus.conflict) {
        continue;
      }
      final entry = entries[index];
      final patchText = const GitDiffCodec().encode([entry]);
      final rejPath = '${resolveWorkTreePath(entry.path)}.rej';
      final file = File(rejPath);
      await file.parent.create(recursive: true);
      await file.writeAsString(
        patchText.endsWith('\n') ? patchText : '$patchText\n',
        flush: true,
      );
    }
  }

  Future<void> _executeApplyWritePlan(_GitApplyWritePlan writePlan) async {
    final absolutePath = resolveWorkTreePath(writePlan.path);
    final entityType = await FileSystemEntity.type(
      absolutePath,
      followLinks: false,
    );

    if (writePlan.delete) {
      if (entityType == FileSystemEntityType.file) {
        await File(absolutePath).delete();
      } else if (entityType == FileSystemEntityType.link) {
        await Link(absolutePath).delete();
      }
      return;
    }

    if (entityType == FileSystemEntityType.file ||
        entityType == FileSystemEntityType.link) {
      if (entityType == FileSystemEntityType.file) {
        await File(absolutePath).delete();
      } else {
        await Link(absolutePath).delete();
      }
    }

    final parentDirectory = Directory(p.dirname(absolutePath));
    await parentDirectory.create(recursive: true);

    if (writePlan.mode == '120000') {
      await Link(absolutePath)
          .create(String.fromCharCodes(writePlan.bytes ?? const <int>[]));
      return;
    }

    await File(absolutePath)
        .writeAsBytes(writePlan.bytes ?? const <int>[], flush: true);
  }

  Future<void> _writeApplyConflictsToIndex(
    List<GitDiffEntry> entries, {
    required GitIndex currentIndex,
  }) async {
    final algorithm = currentIndex.checksumAlgorithm;
    final conflictEntries =
        <
          String,
          ({
            _GitTreeSnapshotEntry? baseEntry,
            _GitTreeSnapshotEntry? currentEntry,
            _GitTreeSnapshotEntry? incomingEntry,
          })
        >{};

    for (final entry in entries) {
      final absolutePath = resolveWorkTreePath(entry.path);
      final entityType = await FileSystemEntity.type(
        absolutePath,
        followLinks: false,
      );
      final currentEntry = entityType == FileSystemEntityType.notFound
          ? null
          : await _snapshotEntryFromWorkTreePath(
              entry.path,
              algorithm: algorithm,
            );
      conflictEntries[entry.path] = (
        baseEntry: await _treeSnapshotEntryFromDiffSide(
          entry.oldObjectId,
          entry.oldBytes,
          entry.oldMode,
          algorithm: algorithm,
        ),
        currentEntry: currentEntry,
        incomingEntry: await _incomingTreeSnapshotEntryFromDiff(
          entry,
          algorithm: algorithm,
        ),
      );
    }

    final updatedIndex = await _buildIndexWithConflictUpdates(
      currentIndex,
      algorithm: algorithm,
      resolvedCandidatePaths: const <String>{},
      resolvedEntries: const <String, _GitTreeSnapshotEntry>{},
      conflictEntries: conflictEntries,
    );
    await writeIndex(
      updatedIndex,
      codec: GitIndexCodec(checksumAlgorithm: updatedIndex.checksumAlgorithm),
    );
  }

  Future<_GitTreeSnapshotEntry?> _treeSnapshotEntryFromDiffSide(
    GitObjectId? objectId,
    List<int>? bytes,
    String? mode, {
    required GitHashAlgorithm algorithm,
  }) async {
    if (mode == null) {
      return null;
    }
    if (objectId != null && await readObject(objectId) != null) {
      return _GitTreeSnapshotEntry(objectId: objectId, mode: mode);
    }
    if (bytes == null) {
      return null;
    }

    return _GitTreeSnapshotEntry(
      objectId: await writeLooseObject(
        GitObject.blob(bytes),
        algorithm: algorithm,
      ),
      mode: mode,
    );
  }

  Future<_GitTreeSnapshotEntry?> _incomingTreeSnapshotEntryFromDiff(
    GitDiffEntry entry, {
    required GitHashAlgorithm algorithm,
  }) async {
    if (entry.newMode == null) {
      return null;
    }
    if (entry.binary) {
      return _treeSnapshotEntryFromDiffSide(
        entry.newObjectId,
        entry.newBytes,
        entry.newMode,
        algorithm: algorithm,
      );
    }
    if (entry.newObjectId != null &&
        await readObject(entry.newObjectId!) != null) {
      return _GitTreeSnapshotEntry(
        objectId: entry.newObjectId!,
        mode: entry.newMode!,
      );
    }

    final baseText = switch (entry.changeType) {
      GitDiffChangeType.added => '',
      GitDiffChangeType.modified || GitDiffChangeType.deleted =>
        entry.oldObjectId == null
            ? null
            : GitRepositoryApply._decodeApplyText(
                await _readBlobObjectBytes(entry.oldObjectId!),
              ),
    };
    if (baseText == null) {
      return null;
    }

    final incomingText = entry.changeType == GitDiffChangeType.deleted
        ? null
        : GitRepositoryApply._applyDiffHunksToText(
            baseText,
            entry.hunks,
            whitespaceMode: GitApplyWhitespaceMode.exact,
            applyContextLines: 3,
          );
    if (incomingText == null) {
      return null;
    }

    return _GitTreeSnapshotEntry(
      objectId: await writeLooseObject(
        GitObject.blob(utf8.encode(incomingText)),
        algorithm: algorithm,
      ),
      mode: entry.newMode!,
    );
  }
}

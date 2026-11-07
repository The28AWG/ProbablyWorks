// ignore_for_file: cascade_invocations
// ignore_for_file: avoid-substring
// Причина: разбор hex и каскады оставлены как в git_core.
part of '../git_repository.dart';

/// status, diff, ls-files, pathspec и gitignore.
extension GitRepositoryStatus on GitRepository {
  Future<GitStatus> status({
    String referenceName = 'HEAD',
    GitIndex? index,
    Iterable<String>? pathspecs,
    bool includeIgnored = false,
    GitCommitCodec commitCodec = const GitCommitCodec(),
    GitTreeCodec? treeCodec,
  }) async {
    if (bare) {
      throw StateError('Bare repositories do not have a working tree.');
    }

    final effectiveIndex = index ?? await readIndex() ?? const GitIndex();
    final stagedEntries = {
      for (final entry in effectiveIndex.entries)
        if (entry.stage == 0) entry.path: entry,
    };
    final conflictedEntries = GitRepositoryIndex._groupConflictedIndexEntries(
      effectiveIndex.entries,
    );

    // Ревизия, не только имя ссылки: `commit --amend --dry-run` сравнивает
    // индекс с `HEAD^`. Нет объекта — пустое дерево, как у первого коммита.
    final baselineId = await revParse(referenceName, commitCodec: commitCodec);
    final headEntries = baselineId == null
        ? <String, _GitTreeSnapshotEntry>{}
        : await _readCommitTreeEntries(
            baselineId,
            commitCodec: commitCodec,
            treeCodec: treeCodec,
          );
    final workTreeEntries = await _readWorkTreeEntries(
      effectiveIndex: effectiveIndex,
    );
    final paths = <String>{
      ...headEntries.keys,
      ...stagedEntries.keys,
      ...conflictedEntries.keys,
      ...workTreeEntries.keys,
    }.toList()..sort();
    final filteredPaths = GitRepositoryStatus._filterPathsByPathspecs(
      paths,
      pathspecs,
    );

    final statusEntries = <GitStatusEntry>[];
    for (final path in filteredPaths) {
      final conflictEntries = conflictedEntries[path];
      final workTreeEntry = workTreeEntries[path];
      late final GitFileStatus indexStatus;
      late final GitFileStatus workTreeStatus;
      GitConflictEntry? conflict;

      if (conflictEntries != null) {
        indexStatus = GitFileStatus.conflicted;
        workTreeStatus = GitRepositoryStatus._compareWorkTreeStatus(
          GitRepositoryIndex._preferredConflictIndexEntryForWorkTree(
            conflictEntries,
          ),
          workTreeEntry,
        );
        conflict = GitRepositoryIndex._toConflictEntry(path, conflictEntries);
      } else {
        final indexEntry = stagedEntries[path];
        indexStatus = GitRepositoryIndex._compareIndexStatus(
          headEntries[path],
          indexEntry,
        );
        var resolvedWorkTreeStatus = GitRepositoryStatus._compareWorkTreeStatus(
          indexEntry,
          workTreeEntry,
        );
        if (resolvedWorkTreeStatus == GitFileStatus.untracked) {
          final ignoreMatches = await checkIgnore([path]);
          if (ignoreMatches.isNotEmpty) {
            if (!includeIgnored) {
              continue;
            }
            resolvedWorkTreeStatus = GitFileStatus.ignored;
          }
        }
        workTreeStatus = resolvedWorkTreeStatus;
      }

      if (conflict == null && workTreeStatus == GitFileStatus.untracked) {
        final ignoreMatches = await checkIgnore([path]);
        if (ignoreMatches.isNotEmpty) {
          if (!includeIgnored) {
            continue;
          }
          statusEntries.add(
            GitStatusEntry(
              path: path,
              indexStatus: indexStatus,
              workTreeStatus: GitFileStatus.ignored,
            ),
          );
          continue;
        }
      }

      if (conflict == null &&
          indexStatus == GitFileStatus.unchanged &&
          workTreeStatus == GitFileStatus.unchanged) {
        continue;
      }
      statusEntries.add(
        GitStatusEntry(
          path: path,
          indexStatus: indexStatus,
          workTreeStatus: workTreeStatus,
          conflict: conflict,
        ),
      );
    }

    return GitStatus(entries: statusEntries);
  }

  Future<List<GitLsFilesEntry>> lsFiles({
    GitIndex? index,
    bool includeUntracked = false,
    bool includeIgnored = false,
    Iterable<String>? pathspecs,
  }) async {
    final effectiveIndex = index ?? await readIndex() ?? const GitIndex();
    final entries = <GitLsFilesEntry>[
      for (final entry in effectiveIndex.entries)
        if (GitRepositoryStatus._pathMatchesAnyPathspec(entry.path, pathspecs))
          GitLsFilesEntry.tracked(
            path: entry.path,
            objectId: entry.objectId,
            mode: entry.mode,
            stage: entry.stage,
          ),
    ];

    if (includeUntracked || includeIgnored) {
      if (bare) {
        throw StateError('Bare repositories do not have a working tree.');
      }

      final trackedPaths = {
        for (final entry in effectiveIndex.entries) entry.path,
      };
      final workTreePaths = await _listWorkTreeFilesInDirectory('.');
      for (final path in workTreePaths) {
        if (!GitRepositoryStatus._pathMatchesAnyPathspec(path, pathspecs)) {
          continue;
        }
        if (!trackedPaths.contains(path)) {
          final ignoreMatches = await checkIgnore([path]);
          if (ignoreMatches.isNotEmpty) {
            if (includeIgnored) {
              entries.add(GitLsFilesEntry.ignored(path));
            }
          } else if (includeUntracked) {
            entries.add(GitLsFilesEntry.untracked(path));
          }
        }
      }
    }

    entries.sort(GitRepositoryStatus._compareLsFilesEntries);
    return entries;
  }

  Future<List<GitDiffEntry>> diff({
    String referenceName = 'HEAD',
    bool staged = false,
    bool includeUntracked = false,
    bool includeIgnored = false,
    Iterable<String>? pathspecs,
    GitIndex? index,
    GitCommitCodec commitCodec = const GitCommitCodec(),
    GitTreeCodec? treeCodec,
  }) async {
    final effectiveIndex = index ?? await readIndex() ?? const GitIndex();
    final stagedEntries = {
      for (final entry in effectiveIndex.entries)
        if (entry.stage == 0) entry.path: entry,
    };
    final conflictedEntries = GitRepositoryIndex._groupConflictedIndexEntries(
      effectiveIndex.entries,
    );

    if (staged) {
      final referenceEntries = await _readReferenceTreeEntries(
        referenceName,
        commitCodec: commitCodec,
        treeCodec: treeCodec,
      );
      final paths = <String>{
        ...referenceEntries.keys,
        ...stagedEntries.keys,
        ...conflictedEntries.keys,
      }.toList()..sort();
      final filteredPaths = GitRepositoryStatus._filterPathsByPathspecs(
        paths,
        pathspecs,
      );

      final diffEntries = <GitDiffEntry>[];
      for (final path in filteredPaths) {
        final referenceEntry = referenceEntries[path];
        final conflictEntries = conflictedEntries[path];
        final conflict = conflictEntries == null
            ? null
            : GitRepositoryIndex._toConflictEntry(path, conflictEntries);
        final indexEntry = conflictEntries == null
            ? stagedEntries[path]
            : GitRepositoryIndex._selectConflictIndexEntryForStagedDiff(
                referenceEntry,
                conflictEntries,
              );
        if (indexEntry == null) {
          continue;
        }
        final changeType =
            GitRepositoryStatus._toDiffChangeType(
              conflict == null
                  ? GitRepositoryIndex._compareIndexStatus(
                      referenceEntry,
                      indexEntry,
                    )
                  : GitFileStatus.conflicted,
            ) ??
            GitDiffChangeType.modified;

        final oldBytes = referenceEntry == null
            ? null
            : await _readBlobObjectBytes(referenceEntry.objectId);
        final newBytes = await _readBlobObjectBytes(indexEntry.objectId);

        diffEntries.add(
          GitRepositoryStatus._buildDiffEntry(
            path: path,
            changeType: changeType,
            oldMode: referenceEntry?.mode,
            newMode: indexEntry.treeMode,
            oldObjectId: referenceEntry?.objectId,
            newObjectId: indexEntry.objectId,
            oldBytes: oldBytes,
            newBytes: newBytes,
            conflict: conflict,
          ),
        );
      }

      return diffEntries;
    }

    if (bare) {
      throw StateError('Bare repositories do not have a working tree.');
    }

    final workTreeEntries = await _readWorkTreeEntries(
      effectiveIndex: effectiveIndex,
    );
    final paths = <String>{
      ...stagedEntries.keys,
      ...conflictedEntries.keys,
      if (includeUntracked) ...workTreeEntries.keys,
    }.toList()..sort();
    final filteredPaths = GitRepositoryStatus._filterPathsByPathspecs(
      paths,
      pathspecs,
    );

    final diffEntries = <GitDiffEntry>[];
    for (final path in filteredPaths) {
      final conflictEntries = conflictedEntries[path];
      final conflict = conflictEntries == null
          ? null
          : GitRepositoryIndex._toConflictEntry(path, conflictEntries);
      final indexEntry = conflictEntries == null
          ? stagedEntries[path]
          : GitRepositoryIndex._preferredConflictIndexEntryForWorkTree(
              conflictEntries,
            );
      final workTreeEntry = workTreeEntries[path];
      if (indexEntry == null && workTreeEntry != null) {
        final ignoreMatches = await checkIgnore([path]);
        if (ignoreMatches.isNotEmpty && !includeIgnored) {
          continue;
        }
      }
      final changeType = GitRepositoryStatus._toDiffChangeType(
        GitRepositoryStatus._compareWorkTreeStatus(indexEntry, workTreeEntry),
      );
      if (changeType == null) {
        continue;
      }

      final oldBytes = indexEntry == null
          ? null
          : await _readBlobObjectBytes(indexEntry.objectId);
      final newBytes = workTreeEntry == null
          ? null
          : await _readWorkTreeFileBytes(path);

      diffEntries.add(
        GitRepositoryStatus._buildDiffEntry(
          path: path,
          changeType: changeType,
          oldMode: indexEntry?.treeMode,
          newMode: workTreeEntry?.mode,
          oldObjectId: indexEntry?.objectId,
          newObjectId: workTreeEntry?.objectId,
          oldBytes: oldBytes,
          newBytes: newBytes,
          conflict: conflict,
        ),
      );
    }

    return diffEntries;
  }

  Future<List<GitIgnoreMatch>> checkIgnore(
    Iterable<String> relativePaths,
  ) async {
    if (bare) {
      throw StateError('Bare repositories do not have a working tree.');
    }

    final normalizedInputs = <({String rawPath, String normalizedPath})>[
      for (final relativePath in relativePaths)
        (
          rawPath: relativePath,
          normalizedPath: _normalizeRelativeWorkTreePath(relativePath),
        ),
    ];
    if (normalizedInputs.isEmpty) {
      return const <GitIgnoreMatch>[];
    }

    final inputDirectories = <String, bool>{};
    for (final input in normalizedInputs) {
      inputDirectories[input.normalizedPath] = await _pathIsDirectoryForIgnore(
        input.rawPath,
        input.normalizedPath,
      );
    }

    final sourceDirectories =
        <String>{
            '',
            for (final input in normalizedInputs)
              ...GitRepositoryStatus._ignoreSourceDirectoriesForPath(
                input.normalizedPath,
              ),
          }.toList()
          ..sort(GitRepositoryStatus._comparePathDepthThenLexicographically);
    final ignoreRules = await _loadIgnoreRules(sourceDirectories);

    final matches = <GitIgnoreMatch>[];
    for (final input in normalizedInputs) {
      final match = GitRepositoryStatus._matchIgnoredPath(
        input.normalizedPath,
        isDirectory: inputDirectories[input.normalizedPath] ?? false,
        rules: ignoreRules,
      );
      if (match != null) {
        matches.add(match);
      }
    }

    return matches;
  }

  static GitFileStatus _compareWorkTreeStatus(
    GitIndexEntry? indexEntry,
    _GitWorkTreeSnapshotEntry? workTreeEntry,
  ) {
    if (indexEntry == null && workTreeEntry == null) {
      return GitFileStatus.unchanged;
    }
    if (indexEntry == null) {
      return GitFileStatus.untracked;
    }
    if (workTreeEntry == null) {
      return GitFileStatus.deleted;
    }
    if (indexEntry.objectId == workTreeEntry.objectId &&
        indexEntry.treeMode == workTreeEntry.mode) {
      return GitFileStatus.unchanged;
    }
    return GitFileStatus.modified;
  }

  static GitDiffChangeType? _toDiffChangeType(GitFileStatus status) =>
      switch (status) {
        GitFileStatus.added ||
        GitFileStatus.untracked => GitDiffChangeType.added,
        GitFileStatus.modified ||
        GitFileStatus.conflicted => GitDiffChangeType.modified,
        GitFileStatus.deleted => GitDiffChangeType.deleted,
        GitFileStatus.unchanged || GitFileStatus.ignored => null,
      };

  static int _comparePathDepthThenLexicographically(String left, String right) {
    final leftDepth = left.isEmpty ? 0 : p.posix.split(left).length;
    final rightDepth = right.isEmpty ? 0 : p.posix.split(right).length;
    if (leftDepth != rightDepth) {
      return leftDepth - rightDepth;
    }
    return left.compareTo(right);
  }

  static bool _pathEqualsOrWithin(String path, String prefix) =>
      prefix == '.' || path == prefix || path.startsWith('$prefix/');

  static int _compareLsFilesEntries(
    GitLsFilesEntry left,
    GitLsFilesEntry right,
  ) {
    final pathComparison = left.path.compareTo(right.path);
    if (pathComparison != 0) {
      return pathComparison;
    }
    if (left.ignored != right.ignored) {
      return left.ignored ? 1 : -1;
    }
    if (left.untracked != right.untracked) {
      return left.untracked ? 1 : -1;
    }
    return left.stage - right.stage;
  }

  static List<String> _filterPathsByPathspecs(
    List<String> paths,
    Iterable<String>? pathspecs,
  ) {
    if (pathspecs == null) {
      return paths;
    }
    final normalizedPathspecs = pathspecs
        .map((pathspec) => pathspec.trim())
        .where((pathspec) => pathspec.isNotEmpty)
        .toList();
    if (normalizedPathspecs.isEmpty) {
      return paths;
    }
    return [
      for (final path in paths)
        if (GitRepositoryStatus._pathMatchesAnyPathspec(
          path,
          normalizedPathspecs,
        ))
          path,
    ];
  }

  static bool _pathMatchesAnyPathspec(
    String path,
    Iterable<String>? pathspecs,
  ) {
    if (pathspecs == null) {
      return true;
    }
    final normalizedPathspecs = pathspecs
        .map((pathspec) => pathspec.trim())
        .where((pathspec) => pathspec.isNotEmpty);
    if (normalizedPathspecs.isEmpty) {
      return true;
    }
    return normalizedPathspecs.any(
      (pathspec) => GitRepositoryStatus._pathMatchesPathspec(path, pathspec),
    );
  }

  static bool _pathMatchesPathspec(String path, String pathspec) {
    final normalizedPathspec = p.posix.joinAll(
      p.split(p.normalize(pathspec.trim())),
    );
    if (!GitRepositoryStatus._hasPathspecWildcards(normalizedPathspec)) {
      return GitRepositoryStatus._pathEqualsOrWithin(path, normalizedPathspec);
    }

    final basenameOnly = !normalizedPathspec.contains('/');
    final matcher = GitRepositoryStatus._compilePathspecPattern(
      normalizedPathspec,
      basenameOnly: basenameOnly,
    );
    final matchTarget = basenameOnly ? p.posix.basename(path) : path;
    return matcher.hasMatch(matchTarget);
  }

  static bool _hasPathspecWildcards(String value) =>
      value.contains('*') || value.contains('?');

  static RegExp _compilePathspecPattern(
    String pattern, {
    required bool basenameOnly,
  }) {
    final buffer = StringBuffer('^');
    for (var index = 0; index < pattern.length; index++) {
      final character = pattern[index];
      if (character == '*') {
        final isDoubleStar =
            index + 1 < pattern.length && pattern[index + 1] == '*';
        if (isDoubleStar) {
          buffer.write('.*');
          index++;
        } else {
          buffer.write(basenameOnly ? '.*' : '[^/]*');
        }
        continue;
      }
      if (character == '?') {
        buffer.write(basenameOnly ? '.' : '[^/]');
        continue;
      }
      buffer.write(RegExp.escape(character));
    }
    buffer.write(r'$');
    return RegExp(buffer.toString());
  }

  Future<bool> _pathIsDirectoryForIgnore(
    String rawPath,
    String normalizedPath,
  ) async {
    final trimmedPath = rawPath.trimRight();
    if (trimmedPath.endsWith('/') || trimmedPath.endsWith(r'\')) {
      return true;
    }

    final entityType = await FileSystemEntity.type(
      resolveWorkTreePath(normalizedPath),
      followLinks: false,
    );
    return entityType == FileSystemEntityType.directory;
  }

  static List<String> _ignoreSourceDirectoriesForPath(String normalizedPath) {
    final segments = p.posix.split(normalizedPath);
    if (segments.length < 2) {
      return const <String>[];
    }

    final directories = <String>[];
    for (var index = 1; index < segments.length; index++) {
      directories.add(p.posix.joinAll(segments.take(index)));
    }
    return directories;
  }

  Future<List<_GitIgnoreRule>> _loadIgnoreRules(
    List<String> sourceDirectories,
  ) async {
    final rules = <_GitIgnoreRule>[];
    final infoExcludeFile = File(
      p.join(commonDirectoryPath, 'info', 'exclude'),
    );
    if (await infoExcludeFile.exists()) {
      rules.addAll(
        GitRepositoryStatus._parseIgnoreRules(
          await infoExcludeFile.readAsString(),
          source: '.git/info/exclude',
          sourceDirectory: '',
        ),
      );
    }

    for (final sourceDirectory in sourceDirectories) {
      final ignorePath = sourceDirectory.isEmpty
          ? p.join(path, '.gitignore')
          : resolveWorkTreePath(p.posix.join(sourceDirectory, '.gitignore'));
      final ignoreFile = File(ignorePath);
      if (!await ignoreFile.exists()) {
        continue;
      }

      rules.addAll(
        GitRepositoryStatus._parseIgnoreRules(
          await ignoreFile.readAsString(),
          source: sourceDirectory.isEmpty
              ? '.gitignore'
              : p.posix.join(sourceDirectory, '.gitignore'),
          sourceDirectory: sourceDirectory,
        ),
      );
    }

    return rules;
  }

  static List<_GitIgnoreRule> _parseIgnoreRules(
    String contents, {
    required String source,
    required String sourceDirectory,
  }) {
    final rules = <_GitIgnoreRule>[];
    final lines = const LineSplitter().convert(contents);
    for (var index = 0; index < lines.length; index++) {
      final parsedRule = GitRepositoryStatus._parseIgnoreRuleLine(
        lines[index],
        source: source,
        sourceDirectory: sourceDirectory,
        lineNumber: index + 1,
      );
      if (parsedRule != null) {
        rules.add(parsedRule);
      }
    }
    return rules;
  }

  static _GitIgnoreRule? _parseIgnoreRuleLine(
    String line, {
    required String source,
    required String sourceDirectory,
    required int lineNumber,
  }) {
    if (line.isEmpty) {
      return null;
    }

    var patternText = line;
    if (patternText.startsWith(r'\#') || patternText.startsWith(r'\!')) {
      patternText = patternText.substring(1);
    } else if (patternText.startsWith('#')) {
      return null;
    }

    var negated = false;
    if (patternText.startsWith('!')) {
      negated = true;
      patternText = patternText.substring(1);
    }
    if (patternText.isEmpty) {
      return null;
    }

    var directoryOnly = false;
    if (patternText.endsWith('/')) {
      directoryOnly = true;
      patternText = patternText.substring(0, patternText.length - 1);
    }
    if (patternText.isEmpty) {
      return null;
    }

    final anchored = patternText.startsWith('/');
    if (anchored) {
      patternText = patternText.substring(1);
    }
    if (patternText.isEmpty) {
      return null;
    }

    final basenameOnly = !patternText.contains('/');
    return _GitIgnoreRule(
      pattern: line.startsWith('!') ? line.substring(1) : line,
      source: source,
      sourceDirectory: sourceDirectory,
      lineNumber: lineNumber,
      negated: negated,
      directoryOnly: directoryOnly,
      basenameOnly: basenameOnly,
      matcher: GitRepositoryStatus._compileIgnorePattern(
        patternText,
        basenameOnly: basenameOnly,
      ),
    );
  }

  static Pattern _compileIgnorePattern(
    String pattern, {
    required bool basenameOnly,
  }) {
    final buffer = StringBuffer('^');
    for (var index = 0; index < pattern.length; index++) {
      final character = pattern[index];
      if (character == r'\') {
        if (index + 1 < pattern.length) {
          buffer.write(RegExp.escape(pattern[index + 1]));
          index++;
        } else {
          buffer.write(r'\\');
        }
        continue;
      }
      if (character == '*') {
        final nextIsWildcard =
            index + 1 < pattern.length && pattern[index + 1] == '*';
        if (nextIsWildcard) {
          buffer.write('.*');
          index++;
        } else {
          buffer.write(basenameOnly ? '.*' : '[^/]*');
        }
        continue;
      }
      if (character == '?') {
        buffer.write('.');
        continue;
      }
      buffer.write(RegExp.escape(character));
    }
    buffer.write(r'$');
    return RegExp(buffer.toString());
  }

  static GitIgnoreMatch? _matchIgnoredPath(
    String path, {
    required bool isDirectory,
    required List<_GitIgnoreRule> rules,
  }) {
    GitIgnoreMatch? deepestIgnoredMatch;
    for (final subject in GitRepositoryStatus._buildIgnoreSubjects(
      path,
      isDirectory: isDirectory,
    )) {
      var ignored = false;
      _GitIgnoreRule? ignoredBy;

      for (final rule in rules) {
        if (!GitRepositoryStatus._ignoreRuleAppliesToSubject(rule, subject)) {
          continue;
        }

        final relativePath = rule.sourceDirectory.isEmpty
            ? subject.path
            : p.posix.relative(subject.path, from: rule.sourceDirectory);
        final matchTarget = rule.basenameOnly
            ? p.posix.basename(relativePath)
            : relativePath;
        if (!(rule.matcher as RegExp).hasMatch(matchTarget)) {
          continue;
        }
        if (rule.directoryOnly && !subject.isDirectory) {
          continue;
        }

        if (rule.negated) {
          ignored = false;
          ignoredBy = null;
        } else {
          ignored = true;
          ignoredBy = rule;
        }
      }

      if (ignored && ignoredBy != null) {
        deepestIgnoredMatch = GitIgnoreMatch(
          path: path,
          pattern: ignoredBy.pattern,
          source: ignoredBy.source,
          lineNumber: ignoredBy.lineNumber,
        );
      }
    }

    return deepestIgnoredMatch;
  }

  static List<_GitIgnoreSubject> _buildIgnoreSubjects(
    String path, {
    required bool isDirectory,
  }) {
    final segments = p.posix.split(path);
    final subjects = <_GitIgnoreSubject>[];
    for (var index = 1; index <= segments.length; index++) {
      subjects.add(
        _GitIgnoreSubject(
          path: p.posix.joinAll(segments.take(index)),
          isDirectory: index < segments.length || isDirectory,
        ),
      );
    }
    return subjects;
  }

  static bool _ignoreRuleAppliesToSubject(
    _GitIgnoreRule rule,
    _GitIgnoreSubject subject,
  ) {
    if (rule.sourceDirectory.isEmpty) {
      return true;
    }
    return GitRepositoryStatus._pathEqualsOrWithin(
          subject.path,
          rule.sourceDirectory,
        ) &&
        subject.path != rule.sourceDirectory;
  }

  Future<List<GitDiffEntry>> _buildDiffEntriesFromTreeSnapshots(
    Map<String, _GitTreeSnapshotEntry> oldEntries,
    Map<String, _GitTreeSnapshotEntry> newEntries,
  ) async {
    final paths = <String>{...oldEntries.keys, ...newEntries.keys}.toList()
      ..sort();
    final diffEntries = <GitDiffEntry>[];
    for (final path in paths) {
      final oldEntry = oldEntries[path];
      final newEntry = newEntries[path];
      final changeType = GitRepositoryStatus._treeSnapshotDiffChangeType(
        oldEntry,
        newEntry,
      );
      if (changeType == null) {
        continue;
      }
      diffEntries.add(
        GitRepositoryStatus._buildDiffEntry(
          path: path,
          changeType: changeType,
          oldMode: oldEntry?.mode,
          newMode: newEntry?.mode,
          oldObjectId: oldEntry?.objectId,
          newObjectId: newEntry?.objectId,
          oldBytes: oldEntry == null
              ? null
              : await _readBlobObjectBytes(oldEntry.objectId),
          newBytes: newEntry == null
              ? null
              : await _readBlobObjectBytes(newEntry.objectId),
        ),
      );
    }
    return diffEntries;
  }

  static GitDiffChangeType? _treeSnapshotDiffChangeType(
    _GitTreeSnapshotEntry? oldEntry,
    _GitTreeSnapshotEntry? newEntry,
  ) {
    if (oldEntry == null && newEntry == null) {
      return null;
    }
    if (oldEntry == null) {
      return GitDiffChangeType.added;
    }
    if (newEntry == null) {
      return GitDiffChangeType.deleted;
    }
    if (oldEntry.objectId == newEntry.objectId &&
        oldEntry.mode == newEntry.mode) {
      return null;
    }
    return GitDiffChangeType.modified;
  }

  static GitDiffEntry _buildDiffEntry({
    required String path,
    required GitDiffChangeType changeType,
    required String? oldMode,
    required String? newMode,
    required GitObjectId? oldObjectId,
    required GitObjectId? newObjectId,
    required List<int>? oldBytes,
    required List<int>? newBytes,
    GitConflictEntry? conflict,
  }) {
    final binary =
        GitRepositoryStatus._isBinaryDiffBytes(oldBytes) ||
        GitRepositoryStatus._isBinaryDiffBytes(newBytes);
    return GitDiffEntry(
      path: path,
      changeType: changeType,
      oldMode: oldMode,
      newMode: newMode,
      oldObjectId: oldObjectId,
      newObjectId: newObjectId,
      oldBytes: binary ? oldBytes : null,
      newBytes: binary ? newBytes : null,
      binary: binary,
      hunks: binary
          ? const []
          : GitRepositoryStatus._buildUnifiedDiffHunks(
              oldBytes == null
                  ? ''
                  : GitRepositoryStatus._decodeDiffText(oldBytes),
              newBytes == null
                  ? ''
                  : GitRepositoryStatus._decodeDiffText(newBytes),
            ),
      conflict: conflict,
    );
  }

  static bool _isBinaryDiffBytes(List<int>? bytes) {
    if (bytes == null) {
      return false;
    }
    if (bytes.contains(0)) {
      return true;
    }
    try {
      utf8.decode(bytes);
      return false;
    } on FormatException {
      return true;
    }
  }

  static String _decodeDiffText(List<int> bytes) => utf8.decode(bytes);

  static List<GitDiffHunk> _buildUnifiedDiffHunks(
    String oldText,
    String newText, {
    int contextLines = 3,
  }) {
    final oldLines = GitRepositoryStatus._splitDiffLines(oldText);
    final newLines = GitRepositoryStatus._splitDiffLines(newText);
    final operations = GitRepositoryStatus._buildDiffOperations(
      oldLines,
      newLines,
    );
    final changedIndices = <int>[
      for (var index = 0; index < operations.length; index++)
        if (operations[index].type != GitDiffLineType.context) index,
    ];
    if (changedIndices.isEmpty) {
      return const [];
    }

    final hunks = <GitDiffHunk>[];
    var groupStart = changedIndices.first;
    var previousChange = changedIndices.first;

    for (final changedIndex in changedIndices.skip(1)) {
      if (changedIndex - previousChange > (contextLines * 2) + 1) {
        hunks.add(
          GitRepositoryStatus._buildDiffHunkFromOperationRange(
            operations,
            start: groupStart,
            end: previousChange,
            contextLines: contextLines,
          ),
        );
        groupStart = changedIndex;
      }
      previousChange = changedIndex;
    }

    hunks.add(
      GitRepositoryStatus._buildDiffHunkFromOperationRange(
        operations,
        start: groupStart,
        end: previousChange,
        contextLines: contextLines,
      ),
    );
    return hunks;
  }

  static GitDiffHunk _buildDiffHunkFromOperationRange(
    List<_GitDiffOperation> operations, {
    required int start,
    required int end,
    required int contextLines,
  }) {
    final hunkStart = start - contextLines < 0 ? 0 : start - contextLines;
    final hunkEnd = end + contextLines + 1 > operations.length
        ? operations.length
        : end + contextLines + 1;
    final hunkOperations = operations.sublist(hunkStart, hunkEnd);
    final oldLineCount = hunkOperations
        .where((operation) => operation.type != GitDiffLineType.addition)
        .length;
    final newLineCount = hunkOperations
        .where((operation) => operation.type != GitDiffLineType.deletion)
        .length;
    // Пустая сторона — старт 0 (`@@ -0,0` / `+0,0`), как у git. Иначе
    // новый файл получал `-1,0`: номер «строки 1», которой в файле нет.
    return GitDiffHunk(
      oldStart: oldLineCount == 0 ? 0 : operations[hunkStart].oldLineNumber,
      oldLineCount: oldLineCount,
      newStart: newLineCount == 0 ? 0 : operations[hunkStart].newLineNumber,
      newLineCount: newLineCount,
      lines: [
        for (final operation in hunkOperations)
          GitDiffLine(type: operation.type, text: operation.text),
      ],
    );
  }

  static List<String> _splitDiffLines(String text) {
    if (text.isEmpty) {
      return const [];
    }

    final lines = <String>[];
    var start = 0;
    for (var index = 0; index < text.length; index++) {
      if (text.codeUnitAt(index) != 0x0a) {
        continue;
      }
      lines.add(text.substring(start, index + 1));
      start = index + 1;
    }
    if (start < text.length) {
      lines.add(text.substring(start));
    }
    return lines;
  }

  static List<_GitDiffOperation> _buildDiffOperations(
    List<String> oldLines,
    List<String> newLines,
  ) {
    final matrix = List.generate(
      oldLines.length + 1,
      (_) => List<int>.filled(newLines.length + 1, 0),
    );

    for (var oldIndex = oldLines.length - 1; oldIndex >= 0; oldIndex--) {
      for (var newIndex = newLines.length - 1; newIndex >= 0; newIndex--) {
        if (oldLines[oldIndex] == newLines[newIndex]) {
          matrix[oldIndex][newIndex] = matrix[oldIndex + 1][newIndex + 1] + 1;
        } else {
          final skipOld = matrix[oldIndex + 1][newIndex];
          final skipNew = matrix[oldIndex][newIndex + 1];
          matrix[oldIndex][newIndex] = skipOld >= skipNew ? skipOld : skipNew;
        }
      }
    }

    final operations = <_GitDiffOperation>[];
    var oldIndex = 0;
    var newIndex = 0;
    var oldLineNumber = 1;
    var newLineNumber = 1;

    while (oldIndex < oldLines.length || newIndex < newLines.length) {
      if (oldIndex < oldLines.length &&
          newIndex < newLines.length &&
          oldLines[oldIndex] == newLines[newIndex]) {
        operations.add(
          _GitDiffOperation(
            type: GitDiffLineType.context,
            text: oldLines[oldIndex],
            oldLineNumber: oldLineNumber,
            newLineNumber: newLineNumber,
          ),
        );
        oldIndex++;
        newIndex++;
        oldLineNumber++;
        newLineNumber++;
        continue;
      }

      final preferDeletion =
          newIndex == newLines.length ||
          (oldIndex < oldLines.length &&
              matrix[oldIndex + 1][newIndex] >= matrix[oldIndex][newIndex + 1]);
      if (preferDeletion) {
        operations.add(
          _GitDiffOperation(
            type: GitDiffLineType.deletion,
            text: oldLines[oldIndex],
            oldLineNumber: oldLineNumber,
            newLineNumber: newLineNumber,
          ),
        );
        oldIndex++;
        oldLineNumber++;
        continue;
      }

      operations.add(
        _GitDiffOperation(
          type: GitDiffLineType.addition,
          text: newLines[newIndex],
          oldLineNumber: oldLineNumber,
          newLineNumber: newLineNumber,
        ),
      );
      newIndex++;
      newLineNumber++;
    }

    return operations;
  }
}

// ignore_for_file: cascade_invocations
// ignore_for_file: avoid-substring
// Причина: разбор hex и каскады оставлены как в git_core.
part of '../git_repository.dart';

/// Снимки деревьев, рабочий каталог, attributes и LFS.
extension GitRepositoryTree on GitRepository {
  Future<Map<String, _GitTreeSnapshotEntry>> _readCommitTreeEntries(
    GitObjectId commitId, {
    required GitCommitCodec commitCodec,
    GitTreeCodec? treeCodec,
  }) async {
    final object = await readObject(commitId);
    // Пустое дерево git известно по хешу, даже если объекта в базе нет:
    // корневой коммит сравнивают с ним, не записывая blob в репозиторий.
    if (object == null) {
      if (commitId.hex == '4b825dc642cb6eb9a060e54bf8d69288fbee4904') {
        return const {};
      }
      throw StateError('Missing commit object for $commitId.');
    }
    if (object.type == GitObjectType.tree) {
      return _readTreeEntries(
        commitId,
        codec: treeCodec ?? GitTreeCodec(algorithm: commitId.algorithm),
      );
    }
    final treeId = await _readCommitTreeId(commitId, codec: commitCodec);
    return _readTreeEntries(
      treeId,
      codec: treeCodec ?? GitTreeCodec(algorithm: treeId.algorithm),
    );
  }

  Future<
    ({GitHashAlgorithm algorithm, Map<String, _GitTreeSnapshotEntry> entries})
  >
  _readRevisionTreeEntries(
    String revision, {
    required GitCommitCodec commitCodec,
    GitTreeCodec? treeCodec,
  }) async {
    final objectId = await revParse(revision, commitCodec: commitCodec);
    if (objectId == null) {
      throw StateError('Could not resolve revision: $revision.');
    }

    return (
      algorithm: objectId.algorithm,
      entries: await _readCommitTreeEntries(
        objectId,
        commitCodec: commitCodec,
        treeCodec: treeCodec,
      ),
    );
  }

  static Map<String, _GitTreeSnapshotEntry> _selectTreeEntries(
    Map<String, _GitTreeSnapshotEntry> entries,
    Iterable<String> requestedPaths,
  ) {
    final selected = <String, _GitTreeSnapshotEntry>{};
    for (final entry in entries.entries) {
      if (requestedPaths.any(
        (path) => GitRepositoryStatus._pathEqualsOrWithin(entry.key, path),
      )) {
        selected[entry.key] = entry.value;
      }
    }
    return selected;
  }

  static Map<String, _GitTreeSnapshotEntry> _treeEntriesFromIndex(
    GitIndex index,
  ) => <String, _GitTreeSnapshotEntry>{
    for (final entry in index.entries)
      if (entry.stage == 0)
        entry.path: _GitTreeSnapshotEntry(
          objectId: entry.objectId,
          mode: entry.treeMode,
        ),
  };

  Future<Map<String, _GitTreeSnapshotEntry>> _treeEntriesFromTrackedWorkTree(
    GitIndex index,
    Map<String, _GitWorkTreeSnapshotEntry> workTreeEntries,
  ) async {
    final selected = <String, _GitTreeSnapshotEntry>{};
    for (final entry in index.entries) {
      if (entry.stage != 0) {
        continue;
      }
      final workTree = workTreeEntries[entry.path];
      if (workTree == null) {
        continue;
      }
      final objectId = await writeLooseObject(
        GitObject.blob(workTree.bytes),
        algorithm: workTree.objectId.algorithm,
      );
      selected[entry.path] = _GitTreeSnapshotEntry(
        objectId: objectId,
        mode: workTree.mode,
      );
    }
    return selected;
  }

  Future<Map<String, _GitTreeSnapshotEntry>> _selectWorkTreeSnapshotEntries(
    Map<String, _GitWorkTreeSnapshotEntry> workTreeEntries,
    Iterable<String> requestedPaths,
  ) async {
    final selected = <String, _GitTreeSnapshotEntry>{};
    for (final path in requestedPaths.toSet().toList()..sort()) {
      final entry = workTreeEntries[path];
      if (entry == null) {
        continue;
      }
      final objectId = await writeLooseObject(
        GitObject.blob(entry.bytes),
        algorithm: entry.objectId.algorithm,
      );
      selected[path] = _GitTreeSnapshotEntry(
        objectId: objectId,
        mode: entry.mode,
      );
    }
    return selected;
  }

  Future<GitObjectId> _writeSnapshotCommit(
    Map<String, _GitTreeSnapshotEntry> entries, {
    required GitCommitSignature author,
    required GitCommitSignature committer,
    required String message,
    required List<GitObjectId> parents,
    required GitHashAlgorithm algorithm,
    GitTreeCodec? treeCodec,
    required GitCommitCodec commitCodec,
  }) async {
    final index = await _buildIndexForTreeEntries(
      entries,
      algorithm: algorithm,
      currentIndex: GitIndex(checksumAlgorithm: algorithm),
    );
    final treeId = await writeTreeFromIndex(index, codec: treeCodec);
    return writeCommitFromTree(
      treeId,
      author: author,
      committer: committer,
      message: message,
      parents: parents,
      codec: commitCodec,
    );
  }

  Future<GitIndex> _readOrBuildIndexForTreeEntries(
    Map<String, _GitTreeSnapshotEntry> treeEntries, {
    required GitHashAlgorithm algorithm,
  }) async {
    final existingIndex = await readIndex();
    if (existingIndex != null) {
      return existingIndex;
    }
    return _buildIndexForTreeEntries(
      treeEntries,
      algorithm: algorithm,
      currentIndex: GitIndex(checksumAlgorithm: algorithm),
    );
  }

  Future<void> _writeTreeSnapshotEntryToWorkTree(
    String relativePath,
    _GitTreeSnapshotEntry entry,
  ) async {
    if (!await _sparseCheckoutAllows(relativePath)) return;
    final absolutePath = resolveWorkTreePath(relativePath);
    final entityType = await FileSystemEntity.type(
      absolutePath,
      followLinks: false,
    );
    if (entityType == FileSystemEntityType.file) {
      await File(absolutePath).delete();
    } else if (entityType == FileSystemEntityType.link) {
      await Link(absolutePath).delete();
    } else if (entityType == FileSystemEntityType.directory) {
      await Directory(absolutePath).delete(recursive: true);
    }

    await _ensureWorkTreeParentDirectories(relativePath);
    final bytes = await _readBlobObjectBytes(entry.objectId);
    if (entry.mode == '120000') {
      await Link(absolutePath).create(String.fromCharCodes(bytes));
      return;
    }
    final cleaned = await _smudgeWorkTreeBytes(
      relativePath,
      Uint8List.fromList(bytes),
    );
    await File(absolutePath).writeAsBytes(cleaned, flush: true);
  }

  /// `text`, `eol` и `ident` из `.gitattributes`, плюс clean-фильтр LFS.
  Future<Uint8List> _cleanWorkTreeBytes(
    String relativePath,
    Uint8List bytes,
  ) async {
    final rules = await _attributeRules();
    var next = bytes;
    if (_attributeMatches(rules, relativePath, 'text') ||
        _attributeValue(rules, relativePath, 'eol') == 'lf') {
      next = Uint8List.fromList(
        utf8.encode(
          utf8.decode(next, allowMalformed: true).replaceAll('\r\n', '\n'),
        ),
      );
    }
    if (_attributeValue(rules, relativePath, 'ident') == '' ||
        _attributeMatches(rules, relativePath, 'ident')) {
      final text = utf8
          .decode(next, allowMalformed: true)
          .replaceAll(RegExp(r'\$Id(:[^$]*)?\$'), r'$Id$');
      next = Uint8List.fromList(utf8.encode(text));
    }
    if (_attributeValue(rules, relativePath, 'filter') == 'lfs') {
      return _storeLfsPointer(next);
    }
    return next;
  }

  /// Smudge LFS: указатель заменяется байтами из локального хранилища, если они есть.
  Future<Uint8List> _smudgeWorkTreeBytes(
    String relativePath,
    Uint8List bytes,
  ) async {
    final rules = await _attributeRules();
    if (_attributeValue(rules, relativePath, 'filter') != 'lfs') return bytes;
    final text = utf8.decode(bytes, allowMalformed: true);
    final oid = RegExp(r'oid sha256:([0-9a-f]{64})').firstMatch(text);
    if (oid == null) return bytes;
    final hex = oid.group(1)!;
    final file = File(
      p.join(
        p.join(commonDirectoryPath, 'lfs', 'objects'),
        p.join(hex.substring(0, 2), hex.substring(2)),
      ),
    );
    if (!await file.exists()) return bytes;
    return file.readAsBytes();
  }

  Future<Uint8List> _storeLfsPointer(Uint8List bytes) async {
    final hex = GitObjectId.compute(
      bytes,
      algorithm: GitHashAlgorithm.sha256,
    ).hex;
    final file = File(
      p.join(
        p.join(commonDirectoryPath, 'lfs', 'objects'),
        p.join(hex.substring(0, 2), hex.substring(2)),
      ),
    );
    await file.parent.create(recursive: true);
    if (!await file.exists()) await file.writeAsBytes(bytes, flush: true);
    final pointer =
        'version https://git-lfs.github.com/spec/v1\noid sha256:$hex\nsize ${bytes.length}\n';
    return Uint8List.fromList(utf8.encode(pointer));
  }

  Future<List<({String pattern, Map<String, String> values})>>
  _attributeRules() async {
    final file = File(resolveWorkTreePath('.gitattributes'));
    if (!await file.exists()) return const [];
    final rules = <({String pattern, Map<String, String> values})>[];
    for (final line in const LineSplitter().convert(
      await file.readAsString(),
    )) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      final values = <String, String>{};
      for (var index = 1; index < parts.length; index++) {
        final token = parts[index];
        final eq = token.indexOf('=');
        if (eq < 0) {
          values[token] = '';
        } else {
          values[token.substring(0, eq)] = token.substring(eq + 1);
        }
      }
      rules.add((pattern: parts.first, values: values));
    }
    return rules;
  }

  bool _attributeMatches(
    List<({String pattern, Map<String, String> values})> rules,
    String path,
    String key,
  ) => _attributeValue(rules, path, key) != null;

  String? _attributeValue(
    List<({String pattern, Map<String, String> values})> rules,
    String path,
    String key,
  ) {
    String? value;
    for (final rule in rules) {
      if (!_attributePatternMatches(rule.pattern, path)) continue;
      if (!rule.values.containsKey(key)) continue;
      value = rule.values[key];
    }
    return value;
  }

  bool _attributePatternMatches(String pattern, String path) {
    if (pattern == path) return true;
    if (pattern.startsWith('*.')) {
      return path.endsWith(pattern.substring(1));
    }
    if (pattern.endsWith('/')) return path.startsWith(pattern);
    return false;
  }

  Future<bool> _sparseCheckoutAllows(String relativePath) async {
    final file = File(p.join(commonDirectoryPath, 'info', 'sparse-checkout'));
    if (!await file.exists()) return true;
    final lines = const LineSplitter().convert(await file.readAsString());
    final patterns = [
      for (final line in lines)
        if (line.trim().isNotEmpty &&
            !line.trim().startsWith('#') &&
            !line.trim().startsWith('!'))
          line.trim(),
    ];
    if (patterns.isEmpty) return true;
    for (final pattern in patterns) {
      if (pattern == '*' || pattern == '/*') return true;
      final bare = pattern.endsWith('/')
          ? pattern.substring(0, pattern.length - 1)
          : pattern;
      if (relativePath == bare || relativePath.startsWith('$bare/')) {
        return true;
      }
    }
    return false;
  }

  Future<void> _ensureWorkTreeParentDirectories(String relativePath) async {
    final parts = p.posix.split(relativePath);
    for (var index = 1; index < parts.length; index++) {
      final parentPath = p.posix.joinAll(parts.take(index));
      final absoluteParentPath = resolveWorkTreePath(parentPath);
      final entityType = await FileSystemEntity.type(
        absoluteParentPath,
        followLinks: false,
      );
      switch (entityType) {
        case FileSystemEntityType.file:
          await File(absoluteParentPath).delete();
        case FileSystemEntityType.link:
          await Link(absoluteParentPath).delete();
        case FileSystemEntityType.directory:
        case FileSystemEntityType.notFound:
          break;
      }
    }
    await Directory(p.dirname(resolveWorkTreePath(relativePath)))
        .create(recursive: true);
  }

  Future<_GitTreeSnapshotEntry?> _snapshotEntryFromWorkTreePath(
    String relativePath, {
    required GitHashAlgorithm algorithm,
  }) async {
    final absolutePath = resolveWorkTreePath(relativePath);
    final entityType = await FileSystemEntity.type(
      absolutePath,
      followLinks: false,
    );
    if (entityType == FileSystemEntityType.notFound) {
      return null;
    }

    final entry = await _readWorkTreeEntry(relativePath, algorithm: algorithm);
    return _GitTreeSnapshotEntry(
      objectId: await writeLooseObject(
        GitObject.blob(entry.bytes),
        algorithm: algorithm,
      ),
      mode: entry.mode,
    );
  }

  Future<void> _restoreWorkTreePaths({
    required Set<String> candidatePaths,
    required Map<String, _GitTreeSnapshotEntry> sourceEntries,
  }) async {
    final pathsToDelete =
        candidatePaths
            .where((path) => !sourceEntries.containsKey(path))
            .toList()
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

    final pathsToWrite = sourceEntries.keys.toList()
      ..sort(GitRepositoryStatus._comparePathDepthThenLexicographically);
    for (final path in pathsToWrite) {
      await _writeTreeSnapshotEntryToWorkTree(path, sourceEntries[path]!);
    }
  }

  Future<Map<String, _GitTreeSnapshotEntry>> _readReferenceTreeEntries(
    String referenceName, {
    required GitCommitCodec commitCodec,
    GitTreeCodec? treeCodec,
  }) async {
    final commitId = await resolveReferenceObjectId(referenceName);
    if (commitId == null) {
      return <String, _GitTreeSnapshotEntry>{};
    }

    final treeId = await _readCommitTreeId(commitId, codec: commitCodec);
    return _readTreeEntries(
      treeId,
      codec: treeCodec ?? GitTreeCodec(algorithm: treeId.algorithm),
    );
  }

  Future<Map<String, _GitTreeSnapshotEntry>> _readTreeEntries(
    GitObjectId treeId, {
    required GitTreeCodec codec,
    String prefix = '',
  }) async {
    final treeObject = await readObject(treeId);
    if (treeObject == null || treeObject.type != GitObjectType.tree) {
      throw StateError('Missing tree object for $treeId.');
    }

    final entries = codec.decode(treeObject.bytes);
    final snapshots = <String, _GitTreeSnapshotEntry>{};
    for (final entry in entries) {
      final entryPath = prefix.isEmpty
          ? entry.utf8Name
          : '$prefix/${entry.utf8Name}';
      if (GitRepositoryObjects._treeModeIsDirectory(entry.mode)) {
        snapshots.addAll(
          await _readTreeEntries(
            entry.objectId,
            codec: codec,
            prefix: entryPath,
          ),
        );
      } else {
        snapshots[entryPath] = _GitTreeSnapshotEntry(
          objectId: entry.objectId,
          mode: entry.mode,
        );
      }
    }
    return snapshots;
  }

  Future<Map<String, _GitWorkTreeSnapshotEntry>> _readWorkTreeEntries({
    required GitIndex effectiveIndex,
  }) async {
    final paths = await _listWorkTreeFilesInDirectory('.');
    final entries = <String, _GitWorkTreeSnapshotEntry>{};
    for (final path in paths) {
      final indexEntry = effectiveIndex.entryForPath(path);
      final algorithm =
          indexEntry?.objectId.algorithm ?? effectiveIndex.checksumAlgorithm;
      entries[path] = await _readWorkTreeEntry(path, algorithm: algorithm);
    }
    return entries;
  }

  Future<_GitWorkTreeSnapshotEntry> _readWorkTreeEntry(
    String relativePath, {
    required GitHashAlgorithm algorithm,
  }) async {
    final absolutePath = resolveWorkTreePath(relativePath);
    final entityType = await FileSystemEntity.type(
      absolutePath,
      followLinks: false,
    );
    final stat = await FileStat.stat(absolutePath);
    if (entityType == FileSystemEntityType.file) {
      final bytes = await File(absolutePath).readAsBytes();
      return _GitWorkTreeSnapshotEntry(
        objectId: GitObject.blob(bytes).id(algorithm: algorithm),
        mode: switch (GitRepositoryIndex._fileModeFromStat(stat)) {
          GitIndexEntry.regularFileMode => '100644',
          GitIndexEntry.executableFileMode => '100755',
          _ => throw StateError('Unsupported file mode for $relativePath.'),
        },
        bytes: bytes,
      );
    }
    if (entityType == FileSystemEntityType.link) {
      final bytes = (await Link(absolutePath).target()).codeUnits;
      return _GitWorkTreeSnapshotEntry(
        objectId: GitObject.blob(bytes).id(algorithm: algorithm),
        mode: '120000',
        bytes: bytes,
      );
    }
    throw StateError(
      'Working tree snapshot paths must resolve to files or symbolic links.',
    );
  }

  Future<List<int>> _readWorkTreeFileBytes(String relativePath) async {
    final absolutePath = resolveWorkTreePath(relativePath);
    final entityType = await FileSystemEntity.type(
      absolutePath,
      followLinks: false,
    );

    return switch (entityType) {
      FileSystemEntityType.file => await File(absolutePath).readAsBytes(),
      FileSystemEntityType.link => (await Link(
        absolutePath,
      ).target()).codeUnits,
      _ => throw StateError(
        'Working tree diff paths must resolve to files or symbolic links.',
      ),
    };
  }

  Future<List<String>> _listWorkTreeFilesInDirectory(
    String relativeDirectoryPath,
  ) async {
    final absoluteDirectoryPath = resolveWorkTreePath(relativeDirectoryPath);
    final directory = Directory(absoluteDirectoryPath);
    if (!await directory.exists()) {
      return <String>[];
    }

    final paths = <String>[];
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      final relativePath = _toRepositoryRelativePath(entity.path);
      if (GitRepositoryStatus._pathEqualsOrWithin(relativePath, '.git')) {
        continue;
      }
      if (entity is File || entity is Link) {
        paths.add(relativePath);
      }
    }
    paths.sort();
    return paths;
  }

  String _toRepositoryRelativePath(String absolutePath) => p.posix.joinAll(
    p.split(
      p.relative(
        p.normalize(p.absolute(absolutePath)),
        from: p.normalize(p.absolute(path)),
      ),
    ),
  );
}

// ignore_for_file: cascade_invocations
// ignore_for_file: avoid-substring
// Причина: разбор hex и каскады оставлены как в git_core.
part of '../git_repository.dart';

/// Объекты репозитория: loose-файлы, pack, shallow и чтение коммита.
extension GitRepositoryObjects on GitRepository {
  Future<bool> isValid() async {
    final headExists = await File(headFilePath).exists();
    final objectsExist = await Directory(objectDirectoryPath).exists();
    final refsExist = await Directory(referenceDirectoryPath).exists();
    return headExists && objectsExist && refsExist;
  }

  Future<GitObject?> readLooseObject(
    GitObjectId objectId, {
    GitLooseObjectCodec codec = const GitLooseObjectCodec(),
  }) async {
    final objectFile = File(resolveLooseObjectPath(objectId));
    if (!await objectFile.exists()) {
      return null;
    }

    final compressedBytes = await objectFile.readAsBytes();
    final rawBytes = zlib.decode(compressedBytes);
    return codec.decode(rawBytes);
  }

  Future<GitObject?> readObject(
    GitObjectId objectId, {
    GitLooseObjectCodec looseCodec = const GitLooseObjectCodec(),
    GitPackCodec? packCodec,
    GitPackIndexCodec? packIndexCodec,
    GitPackResolver? packResolver,
  }) async {
    final resolved = await _replacedObjectId(objectId);
    return _readObjectInternal(
      resolved,
      looseCodec: looseCodec,
      packCodec: packCodec,
      packIndexCodec: packIndexCodec,
      packResolver: packResolver,
      activePackPaths: const <String>{},
    );
  }

  /// `refs/replace` подменяет объект при чтении, как git без `--no-replace-objects`.
  Future<GitObjectId> _replacedObjectId(GitObjectId objectId) async {
    final reference = await readReference('refs/replace/${objectId.hex}');
    final target = reference?.objectId;
    if (target == null || target == objectId) return objectId;
    return target;
  }

  Future<List<int>> exportPack(Iterable<GitObjectId> objectIds) =>
      _exportPackForObjectIds(objectIds.toList(), objectReader: readObject);

  Stream<List<int>> exportPackStream(
    Iterable<GitObjectId> objectIds, {
    int chunkSize = 64 * 1024,
  }) async* {
    if (chunkSize <= 0) {
      throw ArgumentError.value(
        chunkSize,
        'chunkSize',
        'Chunk size must be positive.',
      );
    }

    final packBytes = await exportPack(objectIds);
    for (var offset = 0; offset < packBytes.length; offset += chunkSize) {
      final end = offset + chunkSize < packBytes.length
          ? offset + chunkSize
          : packBytes.length;
      yield packBytes.sublist(offset, end);
    }
  }

  Future<int> importPackBytes(List<int> packBytes) =>
      _importPackBytes(packBytes);

  Future<int> importPackStream(Stream<List<int>> packByteStream) async {
    final chunks = <int>[];
    await for (final chunk in packByteStream) {
      chunks.addAll(chunk);
    }
    return _importPackBytes(chunks);
  }

  Future<GitObjectId> writeLooseObject(
    GitObject object, {
    GitHashAlgorithm? algorithm,
    GitLooseObjectCodec codec = const GitLooseObjectCodec(),
  }) async {
    final effective = algorithm ?? hashAlgorithm;
    final objectId = object.id(algorithm: effective);
    final objectFile = File(resolveLooseObjectPath(objectId));
    if (await objectFile.exists()) {
      return objectId;
    }

    await objectFile.parent.create(recursive: true);
    final rawBytes = codec.encode(object);
    final compressedBytes = zlib.encode(rawBytes);
    await objectFile.writeAsBytes(compressedBytes, flush: true);
    return objectId;
  }

  Future<GitObject?> _readObjectInternal(
    GitObjectId objectId, {
    required GitLooseObjectCodec looseCodec,
    GitPackCodec? packCodec,
    GitPackIndexCodec? packIndexCodec,
    GitPackResolver? packResolver,
    required Set<String> activePackPaths,
  }) async {
    final looseObject = await readLooseObject(objectId, codec: looseCodec);
    if (looseObject != null) {
      return looseObject;
    }

    final packDirectory = Directory(p.join(objectDirectoryPath, 'pack'));
    if (!await packDirectory.exists()) {
      return null;
    }

    final effectivePackCodec =
        packCodec?.checksumAlgorithm == objectId.algorithm
        ? packCodec!
        : GitPackCodec(checksumAlgorithm: objectId.algorithm);
    final effectivePackIndexCodec =
        packIndexCodec?.checksumAlgorithm == objectId.algorithm
        ? packIndexCodec!
        : GitPackIndexCodec(checksumAlgorithm: objectId.algorithm);
    final effectivePackResolver =
        packResolver?.objectIdAlgorithm == objectId.algorithm
        ? packResolver!
        : GitPackResolver(objectIdAlgorithm: objectId.algorithm);
    final indexFiles =
        await packDirectory
              .list(followLinks: false)
              .where((entity) => entity is File && entity.path.endsWith('.idx'))
              .cast<File>()
              .toList()
          ..sort((left, right) => left.path.compareTo(right.path));

    for (final indexFile in indexFiles) {
      final packPath = p.setExtension(indexFile.path, '.pack');
      if (activePackPaths.contains(packPath)) {
        continue;
      }

      final index = effectivePackIndexCodec.decode(
        await indexFile.readAsBytes(),
      );
      if (index.entryForObjectId(objectId) == null) {
        continue;
      }

      final packFile = File(packPath);
      if (!await packFile.exists()) {
        continue;
      }

      final pack = effectivePackCodec.decode(await packFile.readAsBytes());
      final resolvedEntries = await effectivePackResolver.resolve(
        pack,
        externalBaseResolver: (baseObjectId) => _readObjectInternal(
          baseObjectId,
          looseCodec: looseCodec,
          packCodec: effectivePackCodec,
          packIndexCodec: effectivePackIndexCodec,
          packResolver: effectivePackResolver,
          activePackPaths: {...activePackPaths, packPath},
        ),
      );
      for (final resolvedEntry in resolvedEntries) {
        if (resolvedEntry.objectId == objectId) {
          return resolvedEntry.object;
        }
      }
    }

    return null;
  }

  Future<int> _copyReachableObjectsToRepository(
    _GitRemoteTransport destinationRepository,
    GitObjectId rootObjectId, {
    bool dryRun = false,
    required GitCommitCodec commitCodec,
    GitTreeCodec? treeCodec,
  }) async {
    final missingObjectIds = await _collectMissingReachableObjectIds(
      rootObjectId,
      sourceObjectReader: readObject,
      destinationObjectReader: destinationRepository.readObject,
      missingSourceDescription: 'Local repository',
      commitCodec: commitCodec,
      treeCodec: treeCodec,
      sparseBlobAllows: null,
    );
    if (!dryRun && missingObjectIds.isNotEmpty) {
      await destinationRepository.importPackBytes(
        await _exportPackForObjectIds(
          missingObjectIds,
          objectReader: readObject,
        ),
      );
    }
    return missingObjectIds.length;
  }

  Future<int> _copyReachableObjectsFromRepository(
    _GitRemoteTransport remoteRepository,
    GitObjectId rootObjectId, {
    bool dryRun = false,
    int? commitDepth,
    String? objectFilter,
    Set<GitObjectId>? shallowCommits,
    required GitCommitCodec commitCodec,
    GitTreeCodec? treeCodec,
  }) async {
    final missingObjectIds = await _collectMissingReachableObjectIds(
      rootObjectId,
      sourceObjectReader: remoteRepository.readObject,
      destinationObjectReader: readObject,
      missingSourceDescription: 'Remote',
      commitDepth: commitDepth,
      objectFilter: objectFilter,
      shallowCommits: shallowCommits,
      commitCodec: commitCodec,
      treeCodec: treeCodec,
      sparseBlobAllows: null,
    );
    if (!dryRun && missingObjectIds.isNotEmpty) {
      await _importPackBytes(
        await remoteRepository.exportPackForObjectIds(missingObjectIds),
      );
    }
    return missingObjectIds.length;
  }

  Future<List<GitObjectId>> _collectMissingReachableObjectIds(
    GitObjectId rootObjectId, {
    required Future<GitObject?> Function(GitObjectId) sourceObjectReader,
    required Future<GitObject?> Function(GitObjectId) destinationObjectReader,
    required String missingSourceDescription,
    required GitCommitCodec commitCodec,
    GitTreeCodec? treeCodec,
    int? commitDepth,
    String? objectFilter,
    Set<GitObjectId>? shallowCommits,
    bool Function(String relativePath)? sparseBlobAllows,
  }) async {
    final queue = <({GitObjectId objectId, String treePathPrefix})>[
      (objectId: rootObjectId, treePathPrefix: ''),
    ];
    final visited = <GitObjectId>{};
    final missingObjectIds = <GitObjectId>[];
    final generations = <GitObjectId, int>{rootObjectId: 0};

    while (queue.isNotEmpty) {
      final item = queue.removeLast();
      final objectId = item.objectId;
      if (!visited.add(objectId)) {
        continue;
      }

      final sourceObject = await sourceObjectReader(objectId);
      if (sourceObject == null) {
        throw StateError(
          '$missingSourceDescription is missing object $objectId.',
        );
      }
      final destinationObject = await destinationObjectReader(objectId);
      if (destinationObject == null) {
        missingObjectIds.add(objectId);
      }

      switch (sourceObject.type) {
        case GitObjectType.blob:
          break;
        case GitObjectType.commit:
          final commit = commitCodec.decode(sourceObject.bytes);
          queue.add((objectId: commit.tree, treePathPrefix: ''));
          final generation = generations[objectId] ?? 0;
          final cutParents =
              commitDepth != null &&
              generation + 1 >= commitDepth &&
              commit.parents.isNotEmpty;
          if (cutParents) {
            shallowCommits?.add(objectId);
          } else {
            for (final parent in commit.parents) {
              generations[parent] = generation + 1;
              queue.add((objectId: parent, treePathPrefix: ''));
            }
          }
        case GitObjectType.tree:
          final effectiveTreeCodec = treeCodec?.algorithm == objectId.algorithm
              ? treeCodec!
              : GitTreeCodec(algorithm: objectId.algorithm);
          final entries = effectiveTreeCodec.decode(sourceObject.bytes);
          for (final entry in entries) {
            final childPath = item.treePathPrefix.isEmpty
                ? entry.utf8Name
                : '${item.treePathPrefix}/${entry.utf8Name}';
            if (objectFilter == 'blob:none' &&
                GitRepositoryObjects._treeModeIsBlob(entry.mode)) {
              continue;
            }
            if (GitRepositoryObjects._treeModeIsBlob(entry.mode) &&
                sparseBlobAllows != null &&
                !sparseBlobAllows(childPath)) {
              continue;
            }
            queue.add((objectId: entry.objectId, treePathPrefix: childPath));
          }
        case GitObjectType.tag:
          queue.add((
            objectId: GitRepositoryReferences._readTagTargetObjectId(
              sourceObject.bytes,
            ),
            treePathPrefix: '',
          ));
      }
    }

    return missingObjectIds;
  }

  Future<List<int>> _exportPackForObjectIds(
    List<GitObjectId> objectIds, {
    required Future<GitObject?> Function(GitObjectId) objectReader,
  }) async {
    if (objectIds.isEmpty) {
      return const <int>[];
    }

    final algorithm = objectIds.first.algorithm;
    final entries = <GitPackObjectEntry>[];
    for (final objectId in objectIds) {
      if (objectId.algorithm != algorithm) {
        throw StateError(
          'Pack export requires all object ids to use the same algorithm.',
        );
      }
      final object = await objectReader(objectId);
      if (object == null) {
        throw StateError('Missing object for pack export: $objectId.');
      }
      entries.add(GitPackObjectEntry(object));
    }

    return GitPackCodec(checksumAlgorithm: algorithm)
        .encode(GitPack(checksumAlgorithm: algorithm, entries: entries));
  }

  Future<int> _importPackBytes(List<int> packBytes) async {
    if (packBytes.isEmpty) {
      return 0;
    }

    final algorithm = GitRepositoryObjects._detectPackChecksumAlgorithm(
      packBytes,
    );
    final packCodec = GitPackCodec(checksumAlgorithm: algorithm);
    final pack = packCodec.decode(packBytes);
    final packResolver = GitPackResolver(objectIdAlgorithm: algorithm);
    final resolvedEntries = await packResolver.resolve(
      pack,
      externalBaseResolver: readObject,
    );
    if (packBytes.length > gitFs.limits.maxFileBytes) {
      throw StateError('Pack is larger than the virtual host file limit.');
    }
    await _storePackFile(packBytes, resolvedEntries, algorithm);
    for (final entry in resolvedEntries) {
      await writeLooseObject(entry.object, algorithm: algorithm);
    }
    return resolvedEntries.length;
  }

  /// Кладёт pack и idx в `.git/objects/pack`, если файл уже прошёл лимит.
  Future<void> _storePackFile(
    List<int> packBytes,
    List<GitPackResolvedEntry> resolvedEntries,
    GitHashAlgorithm algorithm,
  ) async {
    final checksum = GitObjectId.fromBytes(
      packBytes.sublist(packBytes.length - algorithm.digestLength),
    );
    final directory = Directory(p.join(objectDirectoryPath, 'pack'));
    await directory.create(recursive: true);
    final base = p.join(directory.path, 'pack-${checksum.hex}');
    await File('$base.pack').writeAsBytes(packBytes, flush: true);
    final indexEntries = <GitPackIndexEntry>[
      for (final entry in resolvedEntries)
        if (entry.packEntry.offset != null)
          GitPackIndexEntry(
            objectId: entry.objectId,
            offset: entry.packEntry.offset!,
            crc32: 0,
          ),
    ]..sort((left, right) => left.objectId.hex.compareTo(right.objectId.hex));
    final index = GitPackIndex(
      checksumAlgorithm: algorithm,
      entries: indexEntries,
      packChecksum: checksum,
    );
    await File('$base.idx').writeAsBytes(
      GitPackIndexCodec(checksumAlgorithm: algorithm).encode(index),
      flush: true,
    );
  }

  static bool _treeModeIsBlob(String mode) =>
      mode == '100644' || mode == '100755' || mode == '120000';

  /// Каталог в дереве. Git пишет `40000`, этот пакет при записи — `040000`.
  static bool _treeModeIsDirectory(String mode) =>
      mode == '40000' || mode == '040000';

  static GitHashAlgorithm _detectPackChecksumAlgorithm(List<int> packBytes) {
    if (packBytes.length < GitHashAlgorithm.sha1.digestLength + 12) {
      throw const FormatException('Pack file is too short.');
    }
    if (packBytes.length >= GitHashAlgorithm.sha256.digestLength + 12) {
      final sha256Checksum = GitObjectId.compute(
        packBytes.sublist(
          0,
          packBytes.length - GitHashAlgorithm.sha256.digestLength,
        ),
        algorithm: GitHashAlgorithm.sha256,
      );
      final actualSha256Checksum = GitObjectId.fromBytes(
        packBytes.sublist(
          packBytes.length - GitHashAlgorithm.sha256.digestLength,
        ),
      );
      if (sha256Checksum == actualSha256Checksum) {
        return GitHashAlgorithm.sha256;
      }
    }

    final sha1Checksum = GitObjectId.compute(
      packBytes.sublist(
        0,
        packBytes.length - GitHashAlgorithm.sha1.digestLength,
      ),
      algorithm: GitHashAlgorithm.sha1,
    );
    final actualSha1Checksum = GitObjectId.fromBytes(
      packBytes.sublist(packBytes.length - GitHashAlgorithm.sha1.digestLength),
    );
    if (sha1Checksum == actualSha1Checksum) {
      return GitHashAlgorithm.sha1;
    }
    throw const FormatException(
      'Pack checksum does not match supported algorithms.',
    );
  }

  Future<GitObject?> _readObjectFromRepositories(
    GitObjectId objectId,
    _GitRemoteTransport remoteRepository,
  ) async =>
      await readObject(objectId) ?? await remoteRepository.readObject(objectId);

  /// Граница shallow: эти коммиты читаются без родителей.
  Future<bool> _isShallowCommit(GitObjectId commitId) async {
    final file = File(p.join(gitDirectoryPath, 'shallow'));
    if (!await file.exists()) return false;
    final lines = const LineSplitter().convert(await file.readAsString());
    for (final line in lines) {
      if (line.trim() == commitId.hex) return true;
    }
    return false;
  }

  Future<void> _writeShallowCommits(Set<GitObjectId> commits) async {
    final file = File(p.join(gitDirectoryPath, 'shallow'));
    final existing = await file.exists()
        ? const LineSplitter().convert(await file.readAsString())
        : const <String>[];
    final ids = <String>{
      for (final line in existing)
        if (line.trim().isNotEmpty) line.trim(),
      for (final commit in commits) commit.hex,
    }.toList()..sort();
    await file.parent.create(recursive: true);
    await file.writeAsString('${ids.join('\n')}\n');
  }

  Future<GitCommit> _readCommit(
    GitObjectId commitId, {
    required GitCommitCodec codec,
  }) async {
    final commitObject = await readObject(commitId);
    if (commitObject == null || commitObject.type != GitObjectType.commit) {
      throw StateError('Missing commit object for $commitId.');
    }
    final commit = codec.decode(commitObject.bytes);
    if (!await _isShallowCommit(commitId) || commit.parents.isEmpty) {
      return commit;
    }
    return GitCommit(
      tree: commit.tree,
      author: commit.author,
      committer: commit.committer,
      message: commit.message,
      extraHeaders: commit.extraHeaders,
    );
  }

  Future<List<int>> _readBlobObjectBytes(GitObjectId objectId) async {
    final object = await readObject(objectId);
    if (object == null || object.type != GitObjectType.blob) {
      throw StateError('Missing blob object for $objectId.');
    }
    return object.bytes;
  }

  Future<GitCommit> _readCommitCached(
    GitObjectId commitId, {
    required GitCommitCodec codec,
    required Map<GitObjectId, GitCommit> cache,
  }) async {
    final cachedCommit = cache[commitId];
    if (cachedCommit != null) {
      return cachedCommit;
    }

    final commit = await _readCommit(commitId, codec: codec);
    cache[commitId] = commit;
    return commit;
  }

  Future<GitObjectId> _readCommitTreeId(
    GitObjectId commitId, {
    required GitCommitCodec codec,
  }) async => (await _readCommit(commitId, codec: codec)).tree;

  Future<GitObjectId?> _resolveCommitParent(
    GitObjectId commitId,
    int parentNumber, {
    required GitCommitCodec codec,
  }) async {
    final commit = await _readCommit(commitId, codec: codec);
    if (parentNumber < 1 || parentNumber > commit.parents.length) {
      return null;
    }
    return commit.parents[parentNumber - 1];
  }

  Future<GitCommit> _readCommitCachedAcrossRepositories(
    GitObjectId commitId, {
    required _GitRemoteTransport remoteTransport,
    required GitCommitCodec codec,
    required Map<GitObjectId, GitCommit> cache,
  }) async {
    final cachedCommit = cache[commitId];
    if (cachedCommit != null) {
      return cachedCommit;
    }

    final object = await _readObjectFromRepositories(commitId, remoteTransport);
    if (object == null || object.type != GitObjectType.commit) {
      throw StateError('Missing commit object for $commitId.');
    }

    final commit = codec.decode(object.bytes);
    cache[commitId] = commit;
    return commit;
  }
}

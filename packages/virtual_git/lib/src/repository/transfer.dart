// ignore_for_file: cascade_invocations
// ignore_for_file: avoid-substring
// Причина: разбор hex и каскады оставлены как в git_core.
part of '../git_repository.dart';

/// fetch, push, pull, refspec и копирование объектов между репозиториями.
extension GitRepositoryTransfer on GitRepository {
  Future<GitFetchResult> fetch(
    String remoteName, {
    Iterable<GitRefSpec>? refSpecs,
    bool dryRun = false,
    int? depth,
    String? filter,
    Map<String, String> httpHeaders = const {},
    GitCommitCodec commitCodec = const GitCommitCodec(),
    GitTreeCodec? treeCodec,
  }) async {
    final normalizedRemoteName = GitRepositoryConfig._normalizeRemoteName(
      remoteName,
    );
    final configuredRemote = await remote(normalizedRemoteName);
    if (configuredRemote == null) {
      throw StateError('Remote is not configured: $normalizedRemoteName.');
    }

    final remoteTransport = await GitRepositoryTransfer._openRemoteTransport(
      configuredRemote.url,
      basePath: path,
      operation: 'fetch(...)',
      httpHeaders: {...configuredRemote.httpHeaders, ...httpHeaders},
      sshPrivateKeyPath: configuredRemote.sshPrivateKeyPath,
      sshPrivateKey: configuredRemote.sshPrivateKey,
      sshPrivateKeyPassphrase: configuredRemote.sshPrivateKeyPassphrase,
      sshPassword: configuredRemote.sshPassword,
      sshKnownHostsPath: configuredRemote.sshKnownHostsPath,
      sshHostKeyFingerprints: configuredRemote.sshHostKeyFingerprints,
    );
    final mappings = await _expandFetchRefSpecs(
      refSpecs?.toList() ?? configuredRemote.fetchRefSpecs,
      remoteTransport,
    );
    final commitCache = <GitObjectId, GitCommit>{};
    final fetchedReferences = <GitFetchedReference>[];
    final shallowCommits = <GitObjectId>{};
    if (depth != null) remoteTransport.uploadPackDepth = depth;
    if (filter != null) remoteTransport.uploadPackFilter = filter;

    for (final mapping in mappings) {
      final objectsFetched = await _copyReachableObjectsFromRepository(
        remoteTransport,
        mapping.objectId,
        dryRun: dryRun,
        commitDepth: depth,
        objectFilter: filter,
        shallowCommits: shallowCommits,
        commitCodec: commitCodec,
        treeCodec: treeCodec,
      );
      final previousObjectId = await resolveReferenceObjectId(
        mapping.destinationReferenceName,
      );
      final canFastForward =
          previousObjectId == null ||
          previousObjectId == mapping.objectId ||
          await _canFastForwardFetchedReference(
            previousObjectId,
            mapping.objectId,
            remoteTransport: remoteTransport,
            commitCodec: commitCodec,
            cache: commitCache,
          );
      final forcedUpdate =
          previousObjectId != null &&
          previousObjectId != mapping.objectId &&
          !canFastForward;

      late final GitFetchReferenceStatus status;
      if (previousObjectId == mapping.objectId) {
        status = GitFetchReferenceStatus.upToDate;
      } else if (!mapping.force && forcedUpdate) {
        status = GitFetchReferenceStatus.rejected;
      } else {
        status = GitFetchReferenceStatus.updated;
        if (!dryRun) {
          await writeReference(
            GitReference.direct(
              mapping.destinationReferenceName,
              mapping.objectId,
            ),
          );
        }
      }

      fetchedReferences.add(
        GitFetchedReference(
          sourceReferenceName: mapping.sourceReferenceName,
          destinationReferenceName: mapping.destinationReferenceName,
          status: status,
          objectId: mapping.objectId,
          previousObjectId: previousObjectId,
          forced: status == GitFetchReferenceStatus.updated && forcedUpdate,
          objectsFetched: objectsFetched,
        ),
      );
    }

    if (!dryRun && shallowCommits.isNotEmpty) {
      await _writeShallowCommits(shallowCommits);
    }
    if (!dryRun && filter != null) {
      final marker = File(p.join(gitDirectoryPath, 'info', 'promisor-filter'));
      await marker.parent.create(recursive: true);
      await marker.writeAsString('$filter\n');
    }
    if (!dryRun) {
      await _writeRemoteHeadSymref(remoteTransport, normalizedRemoteName);
    }

    return GitFetchResult(
      remoteName: normalizedRemoteName,
      remoteUrl: remoteTransport.remoteUrl,
      references: fetchedReferences,
      dryRun: dryRun,
    );
  }

  /// Дозагружает недостающие объекты для частичного клона (promisor) с удалённого
  /// `origin`, батчами по [minBatchSize]. Без маркера `info/promisor-filter` —
  /// завершает успешно и ничего не запрашивает.
  ///
  /// При [restrictToSparseCheckout] обход деревьев ограничен путями из
  /// `info/sparse-checkout`, как у `git backfill --sparse`.
  Future<int> backfillMissingObjects({
    int minBatchSize = 1,
    bool restrictToSparseCheckout = false,
    String remoteName = 'origin',
    Map<String, String> httpHeaders = const {},
    GitCommitCodec commitCodec = const GitCommitCodec(),
    GitTreeCodec? treeCodec,
  }) async {
    final marker = File(p.join(gitDirectoryPath, 'info', 'promisor-filter'));
    if (!await marker.exists()) {
      return 0;
    }
    final filterRaw = await marker.readAsString();
    final filter = filterRaw.split('\n').first.trim();
    if (filter.isEmpty) return 0;

    final configuredRemote = await remote(remoteName);
    if (configuredRemote == null) {
      throw StateError('Remote is not configured: $remoteName.');
    }
    final transport = await GitRepositoryTransfer._openRemoteTransport(
      configuredRemote.url,
      basePath: path,
      operation: 'backfill(...)',
      httpHeaders: {...configuredRemote.httpHeaders, ...httpHeaders},
      sshPrivateKeyPath: configuredRemote.sshPrivateKeyPath,
      sshPrivateKey: configuredRemote.sshPrivateKey,
      sshPrivateKeyPassphrase: configuredRemote.sshPrivateKeyPassphrase,
      sshPassword: configuredRemote.sshPassword,
      sshKnownHostsPath: configuredRemote.sshKnownHostsPath,
      sshHostKeyFingerprints: configuredRemote.sshHostKeyFingerprints,
    );
    final effectiveMin = minBatchSize < 1 ? 1 : minBatchSize;
    final sparseAllows = restrictToSparseCheckout
        ? await _loadSparseCheckoutPathMatcher()
        : null;

    var total = 0;
    while (true) {
      final headId = await resolveReferenceObjectId('HEAD');
      if (headId == null) break;
      final missing = await _collectMissingReachableObjectIds(
        headId,
        sourceObjectReader: transport.readObject,
        destinationObjectReader: readObject,
        missingSourceDescription: 'Remote',
        objectFilter: filter,
        commitCodec: commitCodec,
        treeCodec: treeCodec,
        sparseBlobAllows: sparseAllows,
      );
      if (missing.isEmpty) break;
      final chunk = missing.length <= effectiveMin
          ? missing
          : missing.sublist(0, effectiveMin);
      await _importPackBytes(await transport.exportPackForObjectIds(chunk));
      total += chunk.length;
    }
    return total;
  }

  /// Запуск задач обслуживания: [gc] — уплотнение через [pruneUnreachable],
  /// иначе no-op с кодом успеха (остальные задачи требуют внешнего планировщика).
  Future<void> runMaintenanceTask(String task) async {
    if (task == 'gc') {
      await pruneUnreachable();
    }
  }

  Future<bool Function(String relativePath)>
  _loadSparseCheckoutPathMatcher() async {
    final file = File(p.join(commonDirectoryPath, 'info', 'sparse-checkout'));
    if (!await file.exists()) {
      return (_) => true;
    }
    final lines = const LineSplitter().convert(await file.readAsString());
    final patterns = [
      for (final line in lines)
        if (line.trim().isNotEmpty &&
            !line.trim().startsWith('#') &&
            !line.trim().startsWith('!'))
          line.trim(),
    ];
    if (patterns.isEmpty) {
      return (_) => true;
    }
    bool allows(String relativePath) {
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

    return allows;
  }

  Future<GitPushResult> push(
    String remoteName, {
    Iterable<GitRefSpec>? refSpecs,
    bool dryRun = false,
    bool force = false,
    bool setUpstream = false,
    Map<String, String> httpHeaders = const {},
    GitCommitCodec commitCodec = const GitCommitCodec(),
    GitTreeCodec? treeCodec,
  }) async {
    final normalizedRemoteName = GitRepositoryConfig._normalizeRemoteName(
      remoteName,
    );
    final configuredRemote = await remote(normalizedRemoteName);
    if (configuredRemote == null) {
      throw StateError('Remote is not configured: $normalizedRemoteName.');
    }

    final pushRemoteUrl = configuredRemote.pushUrl ?? configuredRemote.url;
    final remoteTransport = await GitRepositoryTransfer._openRemoteTransport(
      pushRemoteUrl,
      basePath: path,
      operation: 'push(...)',
      httpHeaders: {...configuredRemote.httpHeaders, ...httpHeaders},
      sshPrivateKeyPath: configuredRemote.sshPrivateKeyPath,
      sshPrivateKey: configuredRemote.sshPrivateKey,
      sshPrivateKeyPassphrase: configuredRemote.sshPrivateKeyPassphrase,
      sshPassword: configuredRemote.sshPassword,
      sshKnownHostsPath: configuredRemote.sshKnownHostsPath,
      sshHostKeyFingerprints: configuredRemote.sshHostKeyFingerprints,
    );
    final remoteReferenceNames = await remoteTransport.listReferenceNamesUnder(
      'refs',
    );
    final mappings = await _expandPushRefSpecs(
      refSpecs: refSpecs,
      remoteReferenceNames: remoteReferenceNames,
      force: force,
      commitCodec: commitCodec,
    );
    final commitCache = <GitObjectId, GitCommit>{};
    final pushedReferences = <GitPushedReference>[];

    for (final mapping in mappings) {
      final previousObjectId = await remoteTransport.resolveReferenceObjectId(
        mapping.destinationReferenceName,
      );
      late final GitPushReferenceStatus status;
      var objectsPushed = 0;
      var forcedUpdate = false;
      if (mapping.isDeletion) {
        if (previousObjectId == null) {
          status = GitPushReferenceStatus.upToDate;
        } else {
          await _ensurePushDestinationSafe(
            remoteTransport,
            mapping.destinationReferenceName,
          );
          status = GitPushReferenceStatus.deleted;
          if (!dryRun) {
            await remoteTransport.deleteReference(
              mapping.destinationReferenceName,
            );
          }
        }
      } else if (previousObjectId == mapping.objectId) {
        status = GitPushReferenceStatus.upToDate;
      } else {
        final objectId = mapping.objectId!;
        final canFastForward =
            previousObjectId == null ||
            previousObjectId == objectId ||
            await _canFastForwardFetchedReference(
              previousObjectId,
              objectId,
              remoteTransport: remoteTransport,
              commitCodec: commitCodec,
              cache: commitCache,
            );
        forcedUpdate =
            previousObjectId != null &&
            previousObjectId != objectId &&
            !canFastForward;

        if (!mapping.force && forcedUpdate) {
          status = GitPushReferenceStatus.rejected;
        } else {
          await _ensurePushDestinationSafe(
            remoteTransport,
            mapping.destinationReferenceName,
          );
          objectsPushed = await _copyReachableObjectsToRepository(
            remoteTransport,
            objectId,
            dryRun: dryRun,
            commitCodec: commitCodec,
            treeCodec: treeCodec,
          );
          status = GitPushReferenceStatus.updated;
          if (!dryRun) {
            await remoteTransport.writeReference(
              GitReference.direct(mapping.destinationReferenceName, objectId),
            );
          }
        }
      }

      pushedReferences.add(
        GitPushedReference(
          sourceReferenceName: mapping.sourceReferenceName,
          destinationReferenceName: mapping.destinationReferenceName,
          status: status,
          objectId: mapping.objectId,
          previousObjectId: previousObjectId,
          forced: status == GitPushReferenceStatus.updated && forcedUpdate,
          objectsPushed: objectsPushed,
        ),
      );
    }

    GitBranchTracking? tracking;
    if (setUpstream && !dryRun) {
      final inferredTracking = await _inferBranchTrackingForPush(
        remoteName: normalizedRemoteName,
        mappings: mappings,
      );
      if (inferredTracking == null) {
        throw StateError(
          'push(..., setUpstream: true) requires exactly one branch mapping.',
        );
      }
      final matchingReference = pushedReferences.singleWhere(
        (reference) =>
            reference.destinationReferenceName ==
            inferredTracking.mergeReferenceName,
      );
      if (matchingReference.status != GitPushReferenceStatus.rejected) {
        tracking = await setBranchTracking(inferredTracking);
      }
    }

    return GitPushResult(
      remoteName: normalizedRemoteName,
      remoteUrl: remoteTransport.remoteUrl,
      references: pushedReferences,
      tracking: tracking,
      dryRun: dryRun,
    );
  }

  Future<GitPullResult> pull(
    String remoteName, {
    bool dryRun = false,
    GitPullStrategy strategy = GitPullStrategy.fastForward,
    GitCommitSignature? author,
    GitCommitSignature? committer,
    String? message,
    GitCommitSignature? reflogActor,
    Map<String, String> httpHeaders = const {},
    GitCommitCodec commitCodec = const GitCommitCodec(),
    GitTreeCodec? treeCodec,
  }) async {
    if (bare) {
      throw StateError('Bare repositories do not have a working tree.');
    }

    final headReference = await readReference('HEAD');
    final localReferenceName = headReference?.targetReferenceName;
    if (localReferenceName == null ||
        !localReferenceName.startsWith('refs/heads/')) {
      throw StateError('pull(...) requires HEAD to point to a local branch.');
    }

    final tracking = await _resolvePullTracking(
      localReferenceName,
      requestedRemoteName: remoteName,
    );
    final normalizedRemoteName = tracking.remoteName;
    final configuredRemote = await remote(normalizedRemoteName);
    if (configuredRemote == null) {
      throw StateError('Remote is not configured: $normalizedRemoteName.');
    }

    final remoteReferenceName = tracking.mergeReferenceName;
    final remoteTrackingReferenceName = tracking.remoteTrackingReferenceName;
    final fetchResult = await fetch(
      normalizedRemoteName,
      refSpecs: [
        GitRefSpec(
          source: remoteReferenceName,
          destination: remoteTrackingReferenceName,
        ),
      ],
      dryRun: dryRun,
      httpHeaders: httpHeaders,
      commitCodec: commitCodec,
      treeCodec: treeCodec,
    );
    if (fetchResult.references.isEmpty) {
      throw StateError(
        'Remote branch does not exist: '
        '$normalizedRemoteName/${GitRepositoryReferences._branchShortName(localReferenceName)}.',
      );
    }

    final fetchedReference = fetchResult.references.single;
    final currentObjectId = await resolveReferenceObjectId(localReferenceName);
    final targetObjectId = fetchedReference.objectId;
    final commitCache = <GitObjectId, GitCommit>{};
    final dryRunRemoteTransport = dryRun
        ? await GitRepositoryTransfer._openRemoteTransport(
            configuredRemote.url,
            basePath: path,
            operation: 'pull(...)',
            httpHeaders: {...configuredRemote.httpHeaders, ...httpHeaders},
            sshPrivateKeyPath: configuredRemote.sshPrivateKeyPath,
            sshPrivateKey: configuredRemote.sshPrivateKey,
            sshPrivateKeyPassphrase: configuredRemote.sshPrivateKeyPassphrase,
            sshPassword: configuredRemote.sshPassword,
            sshKnownHostsPath: configuredRemote.sshKnownHostsPath,
            sshHostKeyFingerprints: configuredRemote.sshHostKeyFingerprints,
          )
        : null;

    late GitPullStatus status;
    if (fetchedReference.status == GitFetchReferenceStatus.rejected) {
      status = GitPullStatus.rejected;
    } else if (currentObjectId == targetObjectId) {
      status = GitPullStatus.upToDate;
    } else if (currentObjectId == null) {
      status = GitPullStatus.updated;
    } else {
      final canFastForward = dryRun
          ? await _canFastForwardFetchedReference(
              currentObjectId,
              targetObjectId,
              remoteTransport: dryRunRemoteTransport!,
              commitCodec: commitCodec,
              cache: commitCache,
            )
          : await _isCommitAncestorOf(
              currentObjectId,
              targetObjectId,
              codec: commitCodec,
              cache: commitCache,
            );
      if (canFastForward) {
        status = GitPullStatus.updated;
      } else {
        final remoteIsAncestor = dryRun
            ? await _canFastForwardFetchedReference(
                targetObjectId,
                currentObjectId,
                remoteTransport: dryRunRemoteTransport!,
                commitCodec: commitCodec,
                cache: commitCache,
              )
            : await _isCommitAncestorOf(
                targetObjectId,
                currentObjectId,
                codec: commitCodec,
                cache: commitCache,
              );
        if (remoteIsAncestor) {
          status = GitPullStatus.localAhead;
        } else if (strategy == GitPullStrategy.merge && !dryRun) {
          status = GitPullStatus.merged;
        } else {
          status = GitPullStatus.divergent;
        }
      }
    }

    GitMergeResult? mergeResult;
    if (status == GitPullStatus.updated && !dryRun) {
      final currentIndex =
          await readIndex() ??
          GitIndex(checksumAlgorithm: targetObjectId.algorithm);
      final targetTreeEntries = await _readCommitTreeEntries(
        targetObjectId,
        commitCodec: commitCodec,
        treeCodec: treeCodec,
      );
      await _ensureCheckoutSafe(
        targetPaths: targetTreeEntries.keys.toSet(),
        currentIndex: currentIndex,
        commitCodec: commitCodec,
        treeCodec: treeCodec,
      );
      await _writeCheckoutTreeEntries(
        targetTreeEntries,
        currentIndex: currentIndex,
      );
      await _writeIndexForTreeEntries(
        targetTreeEntries,
        algorithm: targetObjectId.algorithm,
        currentIndex: currentIndex,
      );
      await _writeReferenceWithReflog(
        GitReference.direct(localReferenceName, targetObjectId),
        actor: _resolveReflogActor(reflogActor),
        message:
            'pull: fast-forward '
            '$normalizedRemoteName/${GitRepositoryReferences._branchShortName(remoteReferenceName)}',
      );
    } else if (status == GitPullStatus.merged && !dryRun) {
      mergeResult = await merge(
        remoteTrackingReferenceName,
        author: author ?? _resolveReflogActor(reflogActor),
        committer: committer,
        message:
            message ??
            'Merge $normalizedRemoteName/${GitRepositoryReferences._branchShortName(remoteReferenceName)}\n',
        commitCodec: commitCodec,
        treeCodec: treeCodec,
      );
      status = switch (mergeResult.status) {
        GitMergeStatus.conflict => GitPullStatus.conflict,
        GitMergeStatus.alreadyUpToDate => GitPullStatus.upToDate,
        GitMergeStatus.fastForward ||
        GitMergeStatus.merged => GitPullStatus.merged,
      };
    }

    return GitPullResult(
      remoteName: normalizedRemoteName,
      remoteUrl: configuredRemote.url,
      localReferenceName: localReferenceName,
      remoteReferenceName: remoteReferenceName,
      remoteTrackingReferenceName: remoteTrackingReferenceName,
      status: status,
      currentObjectId: currentObjectId,
      targetObjectId: targetObjectId,
      fetchResult: fetchResult,
      strategy: strategy,
      mergeResult: mergeResult,
      tracking: tracking.branchTracking,
      dryRun: dryRun,
    );
  }

  Future<GitPullResult> pullCurrent({
    bool dryRun = false,
    GitPullStrategy strategy = GitPullStrategy.fastForward,
    GitCommitSignature? author,
    GitCommitSignature? committer,
    String? message,
    GitCommitSignature? reflogActor,
    Map<String, String> httpHeaders = const {},
    GitCommitCodec commitCodec = const GitCommitCodec(),
    GitTreeCodec? treeCodec,
  }) async {
    if (bare) {
      throw StateError('Bare repositories do not have a working tree.');
    }

    final headReference = await readReference('HEAD');
    final localReferenceName = headReference?.targetReferenceName;
    if (localReferenceName == null ||
        !localReferenceName.startsWith('refs/heads/')) {
      throw StateError(
        'pullCurrent(...) requires HEAD to point to a local branch.',
      );
    }

    final tracking = await _resolvePullTracking(localReferenceName);
    return pull(
      tracking.remoteName,
      dryRun: dryRun,
      strategy: strategy,
      author: author,
      committer: committer,
      message: message,
      reflogActor: reflogActor,
      httpHeaders: httpHeaders,
      commitCodec: commitCodec,
      treeCodec: treeCodec,
    );
  }

  static Future<_GitRemoteTransport> _openRemoteTransport(
    String remoteUrl, {
    required String basePath,
    required String operation,
    Map<String, String> httpHeaders = const {},
    String? sshPrivateKeyPath,
    String? sshPrivateKey,
    String? sshPrivateKeyPassphrase,
    String? sshPassword,
    String? sshKnownHostsPath,
    Iterable<String> sshHostKeyFingerprints = const <String>[],
  }) => _GitRemoteTransport.open(
    remoteUrl,
    basePath: basePath,
    operation: operation,
    httpHeaders: httpHeaders,
    sshPrivateKeyPath: sshPrivateKeyPath,
    sshPrivateKey: sshPrivateKey,
    sshPrivateKeyPassphrase: sshPrivateKeyPassphrase,
    sshPassword: sshPassword,
    sshKnownHostsPath: sshKnownHostsPath,
    sshHostKeyFingerprints: sshHostKeyFingerprints,
  );

  Future<List<_GitFetchMapping>> _expandFetchRefSpecs(
    List<GitRefSpec> fetchRefSpecs,
    _GitRemoteTransport remoteTransport,
  ) async {
    final mappingsByDestination = <String, _GitFetchMapping>{};
    final remoteReferenceNames = await remoteTransport.listReferenceNamesUnder(
      'refs',
    );

    for (final fetchRefSpec in fetchRefSpecs) {
      final sourcePattern = fetchRefSpec.source;
      if (sourcePattern == null) {
        continue;
      }

      if (sourcePattern.contains('*')) {
        final destinationPattern = fetchRefSpec.destination;
        if (destinationPattern == null || !destinationPattern.contains('*')) {
          throw UnsupportedError(
            'Wildcard fetch refspecs require a wildcard destination.',
          );
        }

        for (final sourceReferenceName in remoteReferenceNames) {
          final wildcardValues = GitRepositoryTransfer._matchRefSpecPattern(
            sourcePattern,
            sourceReferenceName,
          );
          if (wildcardValues == null) {
            continue;
          }

          final objectId = await remoteTransport.resolveReferenceObjectId(
            sourceReferenceName,
          );
          if (objectId == null) {
            continue;
          }

          final destinationReferenceName =
              GitRepositoryTransfer._expandRefSpecPattern(
                destinationPattern,
                wildcardValues,
              );
          mappingsByDestination[destinationReferenceName] = _GitFetchMapping(
            sourceReferenceName: sourceReferenceName,
            destinationReferenceName: destinationReferenceName,
            objectId: objectId,
            force: fetchRefSpec.force,
          );
        }
      } else {
        final objectId = await remoteTransport.resolveReferenceObjectId(
          sourcePattern,
        );
        if (objectId == null) {
          continue;
        }

        final destinationReferenceName =
            fetchRefSpec.destination ?? sourcePattern;
        mappingsByDestination[destinationReferenceName] = _GitFetchMapping(
          sourceReferenceName: sourcePattern,
          destinationReferenceName: destinationReferenceName,
          objectId: objectId,
          force: fetchRefSpec.force,
        );
      }
    }

    return mappingsByDestination.values.toList()..sort((left, right) {
      final destinationComparison = left.destinationReferenceName.compareTo(
        right.destinationReferenceName,
      );
      if (destinationComparison != 0) {
        return destinationComparison;
      }
      return left.sourceReferenceName.compareTo(right.sourceReferenceName);
    });
  }

  Future<List<_GitPushMapping>> _expandPushRefSpecs({
    Iterable<GitRefSpec>? refSpecs,
    required Iterable<String> remoteReferenceNames,
    required bool force,
    required GitCommitCodec commitCodec,
  }) async {
    final effectiveRefSpecs =
        refSpecs?.toList() ?? await _defaultPushRefSpecs();
    final mappingsByDestination = <String, _GitPushMapping>{};
    final localReferenceNames = await _listReferenceNamesUnder('refs');

    for (final refSpec in effectiveRefSpecs) {
      final source = refSpec.source;
      if (source == null) {
        final destination = refSpec.destination;
        if (destination == null) {
          throw ArgumentError.value(
            refSpec,
            'refSpecs',
            'Delete push refspecs require a destination reference.',
          );
        }
        final destinationReferenceNamePattern = destination.contains('*')
            ? GitRepositoryTransfer._normalizePushDestinationPattern(
                destination,
              )
            : GitRepositoryTransfer._normalizePushDestinationReferenceName(
                destination,
              );
        if (destinationReferenceNamePattern.contains('*')) {
          for (final remoteReferenceName in remoteReferenceNames) {
            final wildcardValues = GitRepositoryTransfer._matchRefSpecPattern(
              destinationReferenceNamePattern,
              remoteReferenceName,
            );
            if (wildcardValues == null) {
              continue;
            }
            mappingsByDestination[remoteReferenceName] = _GitPushMapping(
              sourceReferenceName: null,
              destinationReferenceName: remoteReferenceName,
              objectId: null,
              force: force || refSpec.force,
            );
          }
          continue;
        }

        mappingsByDestination[destinationReferenceNamePattern] =
            _GitPushMapping(
              sourceReferenceName: null,
              destinationReferenceName: destinationReferenceNamePattern,
              objectId: null,
              force: force || refSpec.force,
            );
        continue;
      }

      final normalizedSource = source.trim();
      final sourceHasWildcard = normalizedSource.contains('*');
      final destination = refSpec.destination;
      final destinationHasWildcard = destination?.contains('*') ?? false;
      if (sourceHasWildcard || destinationHasWildcard) {
        final sourcePattern = GitRepositoryTransfer._normalizePushSourcePattern(
          normalizedSource,
        );
        final destinationPattern = destination == null
            ? sourcePattern
            : GitRepositoryTransfer._normalizePushDestinationPattern(
                destination,
              );
        final normalizedDestinationHasWildcard = destinationPattern.contains(
          '*',
        );
        if (!sourcePattern.contains('*') || !normalizedDestinationHasWildcard) {
          throw UnsupportedError(
            'Wildcard push refspecs require matching source and destination wildcards.',
          );
        }

        for (final sourceReferenceName in localReferenceNames) {
          final wildcardValues = GitRepositoryTransfer._matchRefSpecPattern(
            sourcePattern,
            sourceReferenceName,
          );
          if (wildcardValues == null) {
            continue;
          }

          final objectId = await resolveReferenceObjectId(sourceReferenceName);
          if (objectId == null) {
            continue;
          }

          final destinationReferenceName =
              GitRepositoryTransfer._expandRefSpecPattern(
                destinationPattern,
                wildcardValues,
              );
          mappingsByDestination[destinationReferenceName] = _GitPushMapping(
            sourceReferenceName: sourceReferenceName,
            destinationReferenceName: destinationReferenceName,
            objectId: objectId,
            force: force || refSpec.force,
          );
        }
        continue;
      }

      final resolvedSource = await _resolvePushSource(
        normalizedSource,
        commitCodec: commitCodec,
      );
      final destinationReferenceName = refSpec.destination == null
          ? resolvedSource.defaultDestinationReferenceName
          : GitRepositoryTransfer._normalizePushDestinationReferenceName(
              refSpec.destination!,
            );
      mappingsByDestination[destinationReferenceName] = _GitPushMapping(
        sourceReferenceName: resolvedSource.sourceReferenceName,
        destinationReferenceName: destinationReferenceName,
        objectId: resolvedSource.objectId,
        force: force || refSpec.force,
      );
    }

    return mappingsByDestination.values.toList()..sort((left, right) {
      final destinationComparison = left.destinationReferenceName.compareTo(
        right.destinationReferenceName,
      );
      if (destinationComparison != 0) {
        return destinationComparison;
      }
      return (left.sourceReferenceName ?? '').compareTo(
        right.sourceReferenceName ?? '',
      );
    });
  }

  Future<List<GitRefSpec>> _defaultPushRefSpecs() async {
    final headReference = await readReference('HEAD');
    final sourceReferenceName = headReference?.targetReferenceName;
    if (sourceReferenceName == null ||
        !sourceReferenceName.startsWith('refs/heads/')) {
      throw StateError(
        'push(...) without refspecs requires HEAD to point to a local branch.',
      );
    }
    return [
      GitRefSpec(source: sourceReferenceName, destination: sourceReferenceName),
    ];
  }

  Future<
    ({
      String sourceReferenceName,
      String defaultDestinationReferenceName,
      GitObjectId objectId,
    })
  >
  _resolvePushSource(
    String source, {
    required GitCommitCodec commitCodec,
  }) async {
    final normalizedSource = source.trim();
    if (normalizedSource.isEmpty) {
      throw ArgumentError.value(
        source,
        'source',
        'Push source must not be empty.',
      );
    }

    final directCandidates = <String>[
      normalizedSource,
      if (!normalizedSource.startsWith('refs/')) 'refs/heads/$normalizedSource',
      if (!normalizedSource.startsWith('refs/')) 'refs/tags/$normalizedSource',
    ];
    for (final candidate in directCandidates) {
      final objectId = await resolveReferenceObjectId(candidate);
      if (objectId != null) {
        return (
          sourceReferenceName: candidate,
          defaultDestinationReferenceName: candidate,
          objectId: objectId,
        );
      }
    }

    final objectId = await revParse(normalizedSource, commitCodec: commitCodec);
    if (objectId == null) {
      throw StateError('Could not resolve push source: $source.');
    }

    if (normalizedSource == 'HEAD') {
      final headReference = await readReference('HEAD');
      final targetReferenceName = headReference?.targetReferenceName;
      if (targetReferenceName != null) {
        return (
          sourceReferenceName: normalizedSource,
          defaultDestinationReferenceName: targetReferenceName,
          objectId: objectId,
        );
      }
    }

    throw StateError(
      'Push source $source requires an explicit destination reference.',
    );
  }

  static String _normalizePushDestinationReferenceName(String destination) {
    final trimmed = destination.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(
        destination,
        'destination',
        'Push destination must not be empty.',
      );
    }
    return trimmed.startsWith('refs/') ? trimmed : 'refs/heads/$trimmed';
  }

  static String _normalizePushSourcePattern(String sourcePattern) {
    final trimmed = sourcePattern.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(
        sourcePattern,
        'sourcePattern',
        'Push source pattern must not be empty.',
      );
    }
    return trimmed.startsWith('refs/') ? trimmed : 'refs/heads/$trimmed';
  }

  static String _normalizePushDestinationPattern(String destinationPattern) {
    final trimmed = destinationPattern.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(
        destinationPattern,
        'destinationPattern',
        'Push destination pattern must not be empty.',
      );
    }
    return trimmed.startsWith('refs/') ? trimmed : 'refs/heads/$trimmed';
  }

  static List<String>? _matchRefSpecPattern(
    String pattern,
    String referenceName,
  ) {
    final wildcardCount = '*'.allMatches(pattern).length;
    if (wildcardCount == 0) {
      return pattern == referenceName ? const <String>[] : null;
    }

    final buffer = StringBuffer('^');
    var cursor = 0;
    while (true) {
      final wildcardIndex = pattern.indexOf('*', cursor);
      if (wildcardIndex == -1) {
        buffer.write(RegExp.escape(pattern.substring(cursor)));
        break;
      }
      buffer.write(RegExp.escape(pattern.substring(cursor, wildcardIndex)));
      buffer.write('(.*?)');
      cursor = wildcardIndex + 1;
    }
    buffer.write(r'$');

    final match = RegExp(buffer.toString()).firstMatch(referenceName);
    if (match == null) {
      return null;
    }
    return [
      for (var index = 1; index <= match.groupCount; index++)
        match.group(index)!,
    ];
  }

  static String _expandRefSpecPattern(
    String pattern,
    List<String> wildcardValues,
  ) {
    final wildcardCount = '*'.allMatches(pattern).length;
    if (wildcardCount == 0) {
      return pattern;
    }
    if (wildcardCount != wildcardValues.length) {
      throw ArgumentError.value(
        wildcardValues,
        'wildcardValues',
        'Wildcard count did not match the destination pattern.',
      );
    }

    final buffer = StringBuffer();
    var cursor = 0;
    var wildcardIndex = 0;
    while (true) {
      final nextWildcard = pattern.indexOf('*', cursor);
      if (nextWildcard == -1) {
        buffer.write(pattern.substring(cursor));
        break;
      }
      buffer.write(pattern.substring(cursor, nextWildcard));
      buffer.write(wildcardValues[wildcardIndex]);
      wildcardIndex++;
      cursor = nextWildcard + 1;
    }
    return buffer.toString();
  }

  Future<void> _ensurePushDestinationSafe(
    _GitRemoteTransport remoteRepository,
    String destinationReferenceName,
  ) async {
    if (remoteRepository.bare) {
      return;
    }

    final headReference = await remoteRepository.readReference('HEAD');
    if (headReference?.targetReferenceName == destinationReferenceName) {
      throw StateError(
        'Cannot push to the checked out branch of a non-bare remote repository.',
      );
    }
  }

  Future<bool> _canFastForwardFetchedReference(
    GitObjectId currentObjectId,
    GitObjectId nextObjectId, {
    required _GitRemoteTransport remoteTransport,
    required GitCommitCodec commitCodec,
    required Map<GitObjectId, GitCommit> cache,
  }) async {
    final currentObject = await _readObjectFromRepositories(
      currentObjectId,
      remoteTransport,
    );
    final nextObject = await _readObjectFromRepositories(
      nextObjectId,
      remoteTransport,
    );
    if (currentObject == null ||
        nextObject == null ||
        currentObject.type != GitObjectType.commit ||
        nextObject.type != GitObjectType.commit) {
      return false;
    }

    return _isCommitAncestorAcrossRepositories(
      currentObjectId,
      nextObjectId,
      remoteTransport: remoteTransport,
      codec: commitCodec,
      cache: cache,
    );
  }

  /// Пишет `refs/remotes/<remote>/HEAD` на ветку удалённого HEAD.
  ///
  /// Так `git branch -a` печатает `remotes/origin/HEAD -> origin/main`.
  /// Clone тоже получает эту ссылку: он копирует историю через fetch.
  Future<void> _writeRemoteHeadSymref(
    _GitRemoteTransport remoteTransport,
    String remoteName,
  ) async {
    final head = await remoteTransport.readReference('HEAD');
    final target = head?.targetReferenceName;
    if (target == null || !target.startsWith('refs/heads/')) {
      return;
    }
    final short = GitRepositoryReferences._branchShortName(target);
    await writeReference(
      GitReference.symbolic(
        'refs/remotes/$remoteName/HEAD',
        'refs/remotes/$remoteName/$short',
      ),
    );
  }

  Future<
    ({
      String remoteName,
      String mergeReferenceName,
      String remoteTrackingReferenceName,
      GitBranchTracking? branchTracking,
    })
  >
  _resolvePullTracking(
    String localReferenceName, {
    String? requestedRemoteName,
  }) async {
    final existingTracking = await branchTracking(localReferenceName);
    final branchName = GitRepositoryReferences._branchShortName(
      localReferenceName,
    );
    final normalizedRequestedRemoteName = requestedRemoteName == null
        ? null
        : GitRepositoryConfig._normalizeRemoteName(requestedRemoteName);
    final remoteName =
        normalizedRequestedRemoteName ??
        existingTracking?.remoteName ??
        'origin';
    final mergeReferenceName =
        existingTracking != null &&
            (normalizedRequestedRemoteName == null ||
                existingTracking.remoteName == normalizedRequestedRemoteName)
        ? existingTracking.mergeReferenceName
        : 'refs/heads/$branchName';
    final remoteTrackingReferenceName =
        'refs/remotes/$remoteName/${GitRepositoryReferences._branchShortName(mergeReferenceName)}';
    return (
      remoteName: remoteName,
      mergeReferenceName: mergeReferenceName,
      remoteTrackingReferenceName: remoteTrackingReferenceName,
      branchTracking:
          existingTracking != null &&
              existingTracking.remoteName == remoteName &&
              existingTracking.mergeReferenceName == mergeReferenceName
          ? existingTracking
          : GitBranchTracking(
              branchName: branchName,
              referenceName: localReferenceName,
              remoteName: remoteName,
              mergeReferenceName: mergeReferenceName,
            ),
    );
  }

  Future<GitBranchTracking?> _inferBranchTrackingForPush({
    required String remoteName,
    required List<_GitPushMapping> mappings,
  }) async {
    final branchMappings = [
      for (final mapping in mappings)
        if (!mapping.isDeletion &&
            mapping.destinationReferenceName.startsWith('refs/heads/'))
          mapping,
    ];
    if (branchMappings.length != 1) {
      return null;
    }

    final mapping = branchMappings.single;
    final sourceReferenceName = mapping.sourceReferenceName;
    String? localReferenceName;
    if (sourceReferenceName == 'HEAD') {
      final headReference = await readReference('HEAD');
      final headTargetReferenceName = headReference?.targetReferenceName;
      if (headTargetReferenceName != null &&
          headTargetReferenceName.startsWith('refs/heads/')) {
        localReferenceName = headTargetReferenceName;
      }
    } else if (sourceReferenceName != null &&
        sourceReferenceName.startsWith('refs/heads/')) {
      localReferenceName = sourceReferenceName;
    }
    if (localReferenceName == null) {
      return null;
    }

    return GitBranchTracking(
      branchName: GitRepositoryReferences._branchShortName(localReferenceName),
      referenceName: localReferenceName,
      remoteName: remoteName,
      mergeReferenceName: mapping.destinationReferenceName,
    );
  }
}

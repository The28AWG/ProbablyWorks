// ignore_for_file: cascade_invocations
// ignore_for_file: avoid-substring
// Причина: разбор hex и каскады оставлены как в git_core.
/// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Файлы идут в виртуальную ФС, SSH отключён.
library;

import 'dart:convert';

import 'package:virtual_git/src/git_apply.dart';
import 'package:virtual_git/src/git_branch.dart';
import 'package:virtual_git/src/git_branch_tracking.dart';
import 'package:virtual_git/src/git_checkout.dart';
import 'package:virtual_git/src/git_clone.dart';
import 'package:virtual_git/src/git_commit.dart';
import 'package:virtual_git/src/git_commit_codec.dart';
import 'package:virtual_git/src/git_conflict.dart';
import 'package:virtual_git/src/git_diff.dart';
import 'package:virtual_git/src/git_diff_codec.dart';
import 'package:virtual_git/src/git_fetch.dart';
import 'package:virtual_git/src/git_hash_algorithm.dart';
import 'package:virtual_git/src/git_host_io.dart';
import 'package:virtual_git/src/git_ignore.dart';
import 'package:virtual_git/src/git_index.dart';
import 'package:virtual_git/src/git_index_codec.dart';
import 'package:virtual_git/src/git_log.dart';
import 'package:virtual_git/src/git_loose_object_codec.dart';
import 'package:virtual_git/src/git_ls_files.dart';
import 'package:virtual_git/src/git_merge.dart';
import 'package:virtual_git/src/git_object.dart';
import 'package:virtual_git/src/git_object_id.dart';
import 'package:virtual_git/src/git_object_type.dart';
import 'package:virtual_git/src/git_pack.dart';
import 'package:virtual_git/src/git_pack_codec.dart';
import 'package:virtual_git/src/git_pack_index_codec.dart';
import 'package:virtual_git/src/git_pack_resolver.dart';
import 'package:virtual_git/src/git_path.dart' as p;
import 'package:virtual_git/src/git_pull.dart';
import 'package:virtual_git/src/git_push.dart';
import 'package:virtual_git/src/git_recovery.dart';
import 'package:virtual_git/src/git_reference.dart';
import 'package:virtual_git/src/git_reference_info.dart';
import 'package:virtual_git/src/git_reflog.dart';
import 'package:virtual_git/src/git_reflog_codec.dart';
import 'package:virtual_git/src/git_refspec.dart';
import 'package:virtual_git/src/git_remote.dart';
import 'package:virtual_git/src/git_remote_reference.dart';
import 'package:virtual_git/src/git_reset.dart';
import 'package:virtual_git/src/git_restore.dart';
import 'package:virtual_git/src/git_stash.dart';
import 'package:virtual_git/src/git_status.dart';
import 'package:virtual_git/src/git_tag.dart';
import 'package:virtual_git/src/git_tag_codec.dart';
import 'package:virtual_git/src/git_tree.dart';
import 'package:virtual_git/src/git_tree_codec.dart';
import 'package:virtual_git/src/git_worktree.dart';
import 'package:virtual_git/src/git_write_tree.dart';

final class GitRepository {
  GitRepository._({
    required this.path,
    required this.gitDirectoryPath,
    required this.commonDirectoryPath,
    required this.bare,
  });

  factory GitRepository.workTree(String path) {
    final normalized = _normalizePath(path);
    return GitRepository._(
      path: normalized,
      gitDirectoryPath: p.join(normalized, '.git'),
      commonDirectoryPath: p.join(normalized, '.git'),
      bare: false,
    );
  }

  factory GitRepository.bare(String path) {
    final normalized = _normalizePath(path);
    return GitRepository._(
      path: normalized,
      gitDirectoryPath: normalized,
      commonDirectoryPath: normalized,
      bare: true,
    );
  }

  final String path;
  final String gitDirectoryPath;
  final String commonDirectoryPath;
  final bool bare;

  String get headFilePath => p.join(gitDirectoryPath, 'HEAD');

  String get objectDirectoryPath => p.join(commonDirectoryPath, 'objects');

  String get referenceDirectoryPath => p.join(commonDirectoryPath, 'refs');

  String get indexFilePath => p.join(gitDirectoryPath, 'index');

  String get configFilePath => p.join(commonDirectoryPath, 'config');

  String get worktreesDirectoryPath => p.join(commonDirectoryPath, 'worktrees');

  String get origHeadFilePath => p.join(gitDirectoryPath, 'ORIG_HEAD');

  String get mergeHeadFilePath => p.join(gitDirectoryPath, 'MERGE_HEAD');

  String get mergeMessageFilePath => p.join(gitDirectoryPath, 'MERGE_MSG');

  String get mergeStateFilePath =>
      p.join(gitDirectoryPath, 'git_core_merge_state.json');

  String get applyStateFilePath =>
      p.join(gitDirectoryPath, 'git_core_apply_state.json');

  String resolveWorkTreePath(String relativePath) {
    if (bare) {
      throw StateError('Bare repositories do not have a working tree.');
    }

    final normalized = p.normalize(relativePath.trim());
    if (normalized.isEmpty || p.isAbsolute(normalized)) {
      throw ArgumentError.value(
        relativePath,
        'relativePath',
        'Working tree paths must be non-empty relative paths.',
      );
    }

    final absolutePath = p.normalize(p.absolute(p.join(path, normalized)));
    final repositoryRoot = p.normalize(p.absolute(path));
    if (absolutePath != repositoryRoot &&
        !p.isWithin(repositoryRoot, absolutePath)) {
      throw ArgumentError.value(
        relativePath,
        'relativePath',
        'Working tree paths must stay within the repository root.',
      );
    }

    return absolutePath;
  }

  String resolveLooseObjectPath(GitObjectId objectId) {
    final directoryName = objectId.hex.substring(0, 2);
    final fileName = objectId.hex.substring(2);
    return p.join(objectDirectoryPath, directoryName, fileName);
  }

  static Future<GitRepository?> discover(String startPath) async {
    var currentPath = p.normalize(p.absolute(_normalizePath(startPath)));

    while (true) {
      final workTreeRepository = await _discoverWorkTree(currentPath);
      if (workTreeRepository != null) {
        return workTreeRepository;
      }

      final bareRepository = await _discoverBare(currentPath);
      if (bareRepository != null) {
        return bareRepository;
      }

      final parentPath = p.dirname(currentPath);
      if (parentPath == currentPath) {
        return null;
      }
      currentPath = parentPath;
    }
  }

  static Future<GitCloneResult> clone(
    String remoteUrl,
    String path, {
    String remoteName = 'origin',
    String? branchName,
    Map<String, String> httpHeaders = const {},
    String? sshPrivateKeyPath,
    String? sshPrivateKey,
    String? sshPrivateKeyPassphrase,
    String? sshPassword,
    String? sshKnownHostsPath,
    Iterable<String> sshHostKeyFingerprints = const <String>[],
    GitCommitCodec commitCodec = const GitCommitCodec(),
    GitTreeCodec? treeCodec,
  }) async {
    final normalizedPath = _normalizePath(path);
    await _ensureCloneTargetReady(normalizedPath);

    final repository = GitRepository.workTree(normalizedPath);
    await _initializeRepositoryLayout(repository.gitDirectoryPath);

    final normalizedRemoteName = _normalizeRemoteName(remoteName);
    final remoteTransport = await _openRemoteTransport(
      remoteUrl,
      basePath: Directory.current.path,
      operation: 'clone(...)',
      httpHeaders: httpHeaders,
      sshPrivateKeyPath: sshPrivateKeyPath,
      sshPrivateKey: sshPrivateKey,
      sshPrivateKeyPassphrase: sshPrivateKeyPassphrase,
      sshPassword: sshPassword,
      sshKnownHostsPath: sshKnownHostsPath,
      sshHostKeyFingerprints: sshHostKeyFingerprints,
    );
    final remoteHeadReference = await remoteTransport.readReference('HEAD');
    final targetReferenceName = branchName == null
        ? remoteHeadReference?.targetReferenceName
        : _normalizeBranchReferenceName(branchName);
    if (targetReferenceName == null ||
        !targetReferenceName.startsWith('refs/heads/')) {
      throw StateError(
        'clone(...) requires the remote HEAD or branchName to resolve '
        'to a branch.',
      );
    }

    await repository.setRemote(
      GitRemote(
        name: normalizedRemoteName,
        url: remoteUrl.trim(),
        httpHeaders: httpHeaders,
        sshPrivateKeyPath: sshPrivateKeyPath,
        sshPrivateKey: sshPrivateKey,
        sshPrivateKeyPassphrase: sshPrivateKeyPassphrase,
        sshPassword: sshPassword,
        sshKnownHostsPath: sshKnownHostsPath,
        sshHostKeyFingerprints: sshHostKeyFingerprints.toList(),
      ),
    );
    final fetchResult = await repository.fetch(
      normalizedRemoteName,
      commitCodec: commitCodec,
      treeCodec: treeCodec,
    );
    final branchShortName = _branchShortName(targetReferenceName);
    final trackingReferenceName =
        'refs/remotes/$normalizedRemoteName/$branchShortName';
    final trackingObjectId = await repository.resolveReferenceObjectId(
      trackingReferenceName,
    );
    if (trackingObjectId == null) {
      throw StateError(
        'Remote branch does not exist: $normalizedRemoteName/$branchShortName.',
      );
    }

    final checkoutResult = await repository.checkout(
      branchShortName,
      create: true,
      startPoint: trackingReferenceName,
      track: true,
      trackingRemoteName: normalizedRemoteName,
      force: true,
      commitCodec: commitCodec,
      treeCodec: treeCodec,
    );

    return GitCloneResult(
      path: normalizedPath,
      gitDirectoryPath: repository.gitDirectoryPath,
      remoteName: normalizedRemoteName,
      remoteUrl: remoteUrl.trim(),
      referenceName: checkoutResult.referenceName!,
      objectId: checkoutResult.objectId,
      fetchResult: fetchResult,
    );
  }

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
  }) => _readObjectInternal(
    objectId,
    looseCodec: looseCodec,
    packCodec: packCodec,
    packIndexCodec: packIndexCodec,
    packResolver: packResolver,
    activePackPaths: const <String>{},
  );

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
    GitHashAlgorithm algorithm = GitHashAlgorithm.sha1,
    GitLooseObjectCodec codec = const GitLooseObjectCodec(),
  }) async {
    final objectId = object.id(algorithm: algorithm);
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

  Future<GitReference?> readReference(String referenceName) async {
    final referenceFile = File(resolveReferencePath(referenceName));
    if (!await referenceFile.exists()) {
      return null;
    }

    final contents = await referenceFile.readAsString();
    return GitReference.fromStorageValue(referenceName, contents);
  }

  Future<void> writeReference(GitReference reference) async {
    final referenceFile = File(resolveReferencePath(reference.name));
    await referenceFile.parent.create(recursive: true);
    await referenceFile.writeAsString(
      '${reference.storageValue}\n',
      flush: true,
    );
  }

  Future<bool> deleteReference(String referenceName) async {
    final referenceFile = File(resolveReferencePath(referenceName));
    if (!await referenceFile.exists()) {
      return false;
    }

    await referenceFile.delete();
    return true;
  }

  Future<List<GitReferenceInfo>> references({
    String prefix = 'refs',
    bool peelTags = false,
    GitTagCodec tagCodec = const GitTagCodec(),
  }) async {
    final referenceNames = await _listReferenceNames(prefix);
    final references = <GitReferenceInfo>[];

    for (final referenceName in referenceNames) {
      final objectId = await resolveReferenceObjectId(referenceName);
      if (objectId == null) {
        continue;
      }

      references.add(
        GitReferenceInfo(
          referenceName: referenceName,
          name: _referenceShortName(referenceName),
          objectId: objectId,
          peeledObjectId: peelTags
              ? await _peelTagObjectId(objectId, tagCodec: tagCodec)
              : null,
        ),
      );
    }

    references.sort(
      (left, right) => left.referenceName.compareTo(right.referenceName),
    );
    return references;
  }

  Future<List<GitTag>> tags({GitTagCodec codec = const GitTagCodec()}) async {
    final tagReferences = await references(
      prefix: 'refs/tags',
      peelTags: true,
      tagCodec: codec,
    );
    final tags = <GitTag>[];

    for (final reference in tagReferences) {
      final object = await readObject(reference.objectId);
      if (object == null) {
        continue;
      }

      if (object.type == GitObjectType.tag) {
        final tagObject = codec.decode(object.bytes);
        tags.add(
          GitTag(
            name: reference.name,
            referenceName: reference.referenceName,
            objectId: reference.objectId,
            targetObjectId: tagObject.targetObjectId,
            targetType: tagObject.targetType,
            tagger: tagObject.tagger,
            message: tagObject.message,
            annotated: true,
          ),
        );
      } else {
        tags.add(
          GitTag(
            name: reference.name,
            referenceName: reference.referenceName,
            objectId: reference.objectId,
            targetObjectId: reference.objectId,
            targetType: object.type,
          ),
        );
      }
    }

    tags.sort((left, right) => left.name.compareTo(right.name));
    return tags;
  }

  Future<List<GitConflictEntry>> conflicts({
    GitIndex? index,
    Iterable<String>? pathspecs,
  }) async {
    final effectiveIndex = index ?? await readIndex() ?? const GitIndex();
    final grouped = <String, List<GitIndexEntry>>{};
    for (final entry in effectiveIndex.entries) {
      if (entry.stage == 0 || !_pathMatchesAnyPathspec(entry.path, pathspecs)) {
        continue;
      }
      grouped.putIfAbsent(entry.path, () => []).add(entry);
    }

    return <GitConflictEntry>[
      for (final path in grouped.keys.toList()..sort())
        GitConflictEntry(
          path: path,
          base: _toConflictStageEntry(grouped[path], 1),
          ours: _toConflictStageEntry(grouped[path], 2),
          theirs: _toConflictStageEntry(grouped[path], 3),
        ),
    ];
  }

  Future<GitTag> tag(
    String name, {
    String target = 'HEAD',
    String? message,
    bool force = false,
    GitCommitSignature? tagger,
    GitCommitCodec commitCodec = const GitCommitCodec(),
    GitTagCodec tagCodec = const GitTagCodec(),
  }) async {
    final referenceName = _normalizeTagReferenceName(name);
    if (!force && await readReference(referenceName) != null) {
      throw StateError('Tag already exists: ${_tagShortName(referenceName)}.');
    }

    final targetObjectId = await revParse(target, commitCodec: commitCodec);
    if (targetObjectId == null) {
      throw StateError('Could not resolve tag target: $target.');
    }

    final targetObject = await readObject(targetObjectId);
    if (targetObject == null) {
      throw StateError('Could not read tag target object: $targetObjectId.');
    }

    var objectId = targetObjectId;
    GitCommitSignature? effectiveTagger;
    if (message != null) {
      effectiveTagger = tagger ?? _resolveReflogActor(null);
      final tagObject = GitTagObject(
        targetObjectId: targetObjectId,
        targetType: targetObject.type,
        name: _tagShortName(referenceName),
        tagger: effectiveTagger,
        message: message,
      );
      objectId = await writeLooseObject(
        GitObject.tag(tagCodec.encode(tagObject)),
        algorithm: targetObjectId.algorithm,
      );
    }

    await writeReference(GitReference.direct(referenceName, objectId));

    return GitTag(
      name: _tagShortName(referenceName),
      referenceName: referenceName,
      objectId: objectId,
      targetObjectId: targetObjectId,
      targetType: targetObject.type,
      tagger: effectiveTagger,
      message: message,
      annotated: message != null,
    );
  }

  Future<List<GitReflogEntry>> reflog({
    String referenceName = 'HEAD',
    bool newestFirst = true,
    GitReflogCodec codec = const GitReflogCodec(),
  }) async {
    final normalizedReferenceName = _normalizeReflogReferenceName(
      referenceName,
    );
    final reflogFile = File(resolveReflogPath(normalizedReferenceName));
    if (!await reflogFile.exists()) {
      return const <GitReflogEntry>[];
    }

    final entries = codec.decode(await reflogFile.readAsString());
    if (!newestFirst) {
      return entries;
    }
    return entries.reversed.toList();
  }

  Future<List<GitRemote>> remotes() async {
    final document = await _readConfigDocument();
    return <GitRemote>[
      for (final section in document.sections)
        if (_isRemoteConfigSection(section)) _remoteFromConfigSection(section),
    ]..sort((left, right) => left.name.compareTo(right.name));
  }

  Future<GitRemote?> remote(String name) async {
    final normalizedName = _normalizeRemoteName(name);
    final document = await _readConfigDocument();
    for (final section in document.sections) {
      if (_isRemoteConfigSection(section) &&
          section.subsection == normalizedName) {
        return _remoteFromConfigSection(section);
      }
    }
    return null;
  }

  Future<GitRemote> setRemote(GitRemote remote) async {
    final normalizedName = _normalizeRemoteName(remote.name);
    final normalizedUrl = remote.url.trim();
    if (normalizedUrl.isEmpty) {
      throw ArgumentError.value(
        remote.url,
        'remote.url',
        'URL must not be empty.',
      );
    }

    final fetchRefSpecs = remote.fetchRefSpecs.isEmpty
        ? [GitRefSpec.parse('+refs/heads/*:refs/remotes/$normalizedName/*')]
        : remote.fetchRefSpecs;
    final normalizedRemote = GitRemote(
      name: normalizedName,
      url: normalizedUrl,
      fetchRefSpecs: fetchRefSpecs,
      pushUrl: remote.pushUrl?.trim().isEmpty ?? true
          ? null
          : remote.pushUrl!.trim(),
      httpHeaders: remote.httpHeaders,
      sshPrivateKeyPath: remote.sshPrivateKeyPath?.trim().isEmpty ?? true
          ? null
          : remote.sshPrivateKeyPath!.trim(),
      sshPrivateKey: remote.sshPrivateKey?.trim().isEmpty ?? true
          ? null
          : remote.sshPrivateKey,
      sshPrivateKeyPassphrase: remote.sshPrivateKeyPassphrase?.isEmpty ?? true
          ? null
          : remote.sshPrivateKeyPassphrase,
      sshPassword: remote.sshPassword?.isEmpty ?? true
          ? null
          : remote.sshPassword,
      sshKnownHostsPath: remote.sshKnownHostsPath?.trim().isEmpty ?? true
          ? null
          : remote.sshKnownHostsPath!.trim(),
      sshHostKeyFingerprints: [
        for (final fingerprint in remote.sshHostKeyFingerprints)
          if (fingerprint.trim().isNotEmpty) fingerprint.trim(),
      ],
    );

    final document = await _readConfigDocument();
    final updatedSections = <_GitConfigSection>[];
    var replaced = false;
    for (final section in document.sections) {
      if (_isRemoteConfigSection(section) &&
          section.subsection == normalizedName) {
        if (!replaced) {
          updatedSections.add(_buildRemoteConfigSection(normalizedRemote));
          replaced = true;
        }
      } else {
        updatedSections.add(section);
      }
    }
    if (!replaced) {
      updatedSections.add(_buildRemoteConfigSection(normalizedRemote));
    }

    await _writeConfigDocument(
      _GitConfigDocument(
        preamble: document.preamble,
        sections: updatedSections,
      ),
    );
    return normalizedRemote;
  }

  Future<bool> deleteRemote(String name) async {
    final normalizedName = _normalizeRemoteName(name);
    final document = await _readConfigDocument();
    final updatedSections = [
      for (final section in document.sections)
        if (!(_isRemoteConfigSection(section) &&
            section.subsection == normalizedName))
          section,
    ];
    if (updatedSections.length == document.sections.length) {
      return false;
    }

    await _writeConfigDocument(
      _GitConfigDocument(
        preamble: document.preamble,
        sections: updatedSections,
      ),
    );
    return true;
  }

  Future<GitBranchTracking?> branchTracking(String branchName) async {
    final referenceName = _normalizeBranchReferenceName(branchName);
    final document = await _readConfigDocument();
    for (final section in document.sections) {
      if (_isBranchConfigSection(section) &&
          section.subsection == _branchShortName(referenceName)) {
        return _branchTrackingFromConfigSection(section);
      }
    }
    return null;
  }

  Future<GitBranchTracking> setBranchTracking(
    GitBranchTracking tracking,
  ) async {
    final referenceName = _normalizeBranchReferenceName(tracking.branchName);
    final normalizedRemoteName = _normalizeRemoteName(tracking.remoteName);
    final normalizedMergeReferenceName =
        tracking.mergeReferenceName.trim().startsWith('refs/')
        ? tracking.mergeReferenceName.trim()
        : _normalizeBranchReferenceName(tracking.mergeReferenceName);
    final normalizedTracking = GitBranchTracking(
      branchName: _branchShortName(referenceName),
      referenceName: referenceName,
      remoteName: normalizedRemoteName,
      mergeReferenceName: normalizedMergeReferenceName,
    );

    final document = await _readConfigDocument();
    final updatedSections = <_GitConfigSection>[];
    var replaced = false;
    for (final section in document.sections) {
      if (_isBranchConfigSection(section) &&
          section.subsection == normalizedTracking.branchName) {
        if (!replaced) {
          updatedSections.add(_buildBranchConfigSection(normalizedTracking));
          replaced = true;
        }
      } else {
        updatedSections.add(section);
      }
    }
    if (!replaced) {
      updatedSections.add(_buildBranchConfigSection(normalizedTracking));
    }

    await _writeConfigDocument(
      _GitConfigDocument(
        preamble: document.preamble,
        sections: updatedSections,
      ),
    );
    return normalizedTracking;
  }

  Future<bool> deleteBranchTracking(String branchName) async {
    final normalizedBranchName = _branchShortName(
      _normalizeBranchReferenceName(branchName),
    );
    final document = await _readConfigDocument();
    final updatedSections = [
      for (final section in document.sections)
        if (!(_isBranchConfigSection(section) &&
            section.subsection == normalizedBranchName))
          section,
    ];
    if (updatedSections.length == document.sections.length) {
      return false;
    }

    await _writeConfigDocument(
      _GitConfigDocument(
        preamble: document.preamble,
        sections: updatedSections,
      ),
    );
    return true;
  }

  Future<List<GitRemoteReference>> remoteReferences([
    String? remoteName,
  ]) async {
    final remotesDirectory = Directory(
      p.join(referenceDirectoryPath, 'remotes'),
    );
    if (!await remotesDirectory.exists()) {
      return const <GitRemoteReference>[];
    }

    final normalizedRemoteName = remoteName == null
        ? null
        : _normalizeRemoteName(remoteName);
    final targetDirectoryPath = normalizedRemoteName == null
        ? remotesDirectory.path
        : p.join(remotesDirectory.path, normalizedRemoteName);
    final targetDirectory = Directory(targetDirectoryPath);
    if (!await targetDirectory.exists()) {
      return const <GitRemoteReference>[];
    }

    final references = <GitRemoteReference>[];
    await for (final entity in targetDirectory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) {
        continue;
      }

      final relativePath = p.posix.joinAll(
        p.split(p.relative(entity.path, from: remotesDirectory.path)),
      );
      final parts = p.posix.split(relativePath);
      if (parts.length < 2) {
        continue;
      }
      final resolvedRemoteName = parts.first;
      final name = p.posix.joinAll(parts.skip(1));
      final referenceName = 'refs/remotes/$resolvedRemoteName/$name';
      final objectId = await resolveReferenceObjectId(referenceName);
      if (objectId == null) {
        continue;
      }
      references.add(
        GitRemoteReference(
          remoteName: resolvedRemoteName,
          name: name,
          referenceName: referenceName,
          objectId: objectId,
        ),
      );
    }

    references.sort(
      (left, right) => left.referenceName.compareTo(right.referenceName),
    );
    return references;
  }

  Future<GitRemoteReference> writeRemoteReference(
    String remoteName,
    String name,
    GitObjectId objectId,
  ) async {
    final normalizedRemoteName = _normalizeRemoteName(remoteName);
    final normalizedName = _normalizeRemoteReferenceName(name);
    final referenceName = 'refs/remotes/$normalizedRemoteName/$normalizedName';
    await writeReference(GitReference.direct(referenceName, objectId));
    return GitRemoteReference(
      remoteName: normalizedRemoteName,
      name: normalizedName,
      referenceName: referenceName,
      objectId: objectId,
    );
  }

  Future<bool> deleteRemoteReference(String remoteName, String name) {
    final normalizedRemoteName = _normalizeRemoteName(remoteName);
    final normalizedName = _normalizeRemoteReferenceName(name);
    return deleteReference(
      'refs/remotes/$normalizedRemoteName/$normalizedName',
    );
  }

  Future<GitFetchResult> fetch(
    String remoteName, {
    Iterable<GitRefSpec>? refSpecs,
    bool dryRun = false,
    Map<String, String> httpHeaders = const {},
    GitCommitCodec commitCodec = const GitCommitCodec(),
    GitTreeCodec? treeCodec,
  }) async {
    final normalizedRemoteName = _normalizeRemoteName(remoteName);
    final configuredRemote = await remote(normalizedRemoteName);
    if (configuredRemote == null) {
      throw StateError('Remote is not configured: $normalizedRemoteName.');
    }

    final remoteTransport = await _openRemoteTransport(
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

    for (final mapping in mappings) {
      final objectsFetched = await _copyReachableObjectsFromRepository(
        remoteTransport,
        mapping.objectId,
        dryRun: dryRun,
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

    return GitFetchResult(
      remoteName: normalizedRemoteName,
      remoteUrl: remoteTransport.remoteUrl,
      references: fetchedReferences,
      dryRun: dryRun,
    );
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
    final normalizedRemoteName = _normalizeRemoteName(remoteName);
    final configuredRemote = await remote(normalizedRemoteName);
    if (configuredRemote == null) {
      throw StateError('Remote is not configured: $normalizedRemoteName.');
    }

    final pushRemoteUrl = configuredRemote.pushUrl ?? configuredRemote.url;
    final remoteTransport = await _openRemoteTransport(
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
        '$normalizedRemoteName/${_branchShortName(localReferenceName)}.',
      );
    }

    final fetchedReference = fetchResult.references.single;
    final currentObjectId = await resolveReferenceObjectId(localReferenceName);
    final targetObjectId = fetchedReference.objectId;
    final commitCache = <GitObjectId, GitCommit>{};
    final dryRunRemoteTransport = dryRun
        ? await _openRemoteTransport(
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
            '$normalizedRemoteName/${_branchShortName(remoteReferenceName)}',
      );
    } else if (status == GitPullStatus.merged && !dryRun) {
      mergeResult = await merge(
        remoteTrackingReferenceName,
        author: author ?? _resolveReflogActor(reflogActor),
        committer: committer,
        message:
            message ??
            'Merge $normalizedRemoteName/${_branchShortName(remoteReferenceName)}\n',
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

  Future<GitObjectId?> resolveReferenceObjectId(String referenceName) =>
      _resolveReferenceObjectId(referenceName, <String>{});

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
        final fileBytes = await File(absolutePath).readAsBytes();
        object = GitObject.blob(fileBytes);
        mode = _fileModeFromStat(stat);
        fileSize = stat.size;
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
    final groupedConflicts = _groupConflictedIndexEntries(index.entries);
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
    await _writeReferenceWithReflog(
      GitReference.direct(writableReferenceName, commitId),
      actor: committer ?? author,
      message: 'commit: ${_summarizeReflogMessage(message)}',
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
      treeCodec: treeCodec,
      commitCodec: commitCodec,
    );
  }

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
    final conflictedEntries = _groupConflictedIndexEntries(
      effectiveIndex.entries,
    );

    final headEntries = await _readReferenceTreeEntries(
      referenceName,
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
    final filteredPaths = _filterPathsByPathspecs(paths, pathspecs);

    final statusEntries = <GitStatusEntry>[];
    for (final path in filteredPaths) {
      final conflictEntries = conflictedEntries[path];
      final workTreeEntry = workTreeEntries[path];
      late final GitFileStatus indexStatus;
      late final GitFileStatus workTreeStatus;
      GitConflictEntry? conflict;

      if (conflictEntries != null) {
        indexStatus = GitFileStatus.conflicted;
        workTreeStatus = _compareWorkTreeStatus(
          _preferredConflictIndexEntryForWorkTree(conflictEntries),
          workTreeEntry,
        );
        conflict = _toConflictEntry(path, conflictEntries);
      } else {
        final indexEntry = stagedEntries[path];
        indexStatus = _compareIndexStatus(headEntries[path], indexEntry);
        var resolvedWorkTreeStatus = _compareWorkTreeStatus(
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
        if (_pathMatchesAnyPathspec(entry.path, pathspecs))
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
        if (!_pathMatchesAnyPathspec(path, pathspecs)) {
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

    entries.sort(_compareLsFilesEntries);
    return entries;
  }

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
    final conflictedEntries = _groupConflictedIndexEntries(
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
      final filteredPaths = _filterPathsByPathspecs(paths, pathspecs);

      final diffEntries = <GitDiffEntry>[];
      for (final path in filteredPaths) {
        final referenceEntry = referenceEntries[path];
        final conflictEntries = conflictedEntries[path];
        final conflict = conflictEntries == null
            ? null
            : _toConflictEntry(path, conflictEntries);
        final indexEntry = conflictEntries == null
            ? stagedEntries[path]
            : _selectConflictIndexEntryForStagedDiff(
                referenceEntry,
                conflictEntries,
              );
        if (indexEntry == null) {
          continue;
        }
        final changeType =
            _toDiffChangeType(
              conflict == null
                  ? _compareIndexStatus(referenceEntry, indexEntry)
                  : GitFileStatus.conflicted,
            ) ??
            GitDiffChangeType.modified;

        final oldBytes = referenceEntry == null
            ? null
            : await _readBlobObjectBytes(referenceEntry.objectId);
        final newBytes = await _readBlobObjectBytes(indexEntry.objectId);

        diffEntries.add(
          _buildDiffEntry(
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
    final filteredPaths = _filterPathsByPathspecs(paths, pathspecs);

    final diffEntries = <GitDiffEntry>[];
    for (final path in filteredPaths) {
      final conflictEntries = conflictedEntries[path];
      final conflict = conflictEntries == null
          ? null
          : _toConflictEntry(path, conflictEntries);
      final indexEntry = conflictEntries == null
          ? stagedEntries[path]
          : _preferredConflictIndexEntryForWorkTree(conflictEntries);
      final workTreeEntry = workTreeEntries[path];
      if (indexEntry == null && workTreeEntry != null) {
        final ignoreMatches = await checkIgnore([path]);
        if (ignoreMatches.isNotEmpty && !includeIgnored) {
          continue;
        }
      }
      final changeType = _toDiffChangeType(
        _compareWorkTreeStatus(indexEntry, workTreeEntry),
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
        _buildDiffEntry(
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

  Future<GitBranch> branch(
    String branchName, {
    String startPoint = 'HEAD',
    bool force = false,
    GitCommitSignature? reflogActor,
    GitCommitCodec commitCodec = const GitCommitCodec(),
  }) async {
    final referenceName = _normalizeBranchReferenceName(branchName);
    final objectId = await revParse(startPoint, commitCodec: commitCodec);
    if (objectId == null) {
      throw StateError('Could not resolve branch start point: $startPoint.');
    }

    final existing = await readReference(referenceName);
    if (existing != null && !force) {
      throw StateError(
        'Branch already exists: ${_branchShortName(referenceName)}.',
      );
    }

    final reference = GitReference.direct(referenceName, objectId);
    await _writeReferenceWithReflog(
      reference,
      actor: _resolveReflogActor(reflogActor),
      message: force && existing != null
          ? 'branch: Reset to ${startPoint.trim()}'
          : 'branch: Created from ${startPoint.trim()}',
    );
    final headReference = await readReference('HEAD');
    return GitBranch(
      name: _branchShortName(referenceName),
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
    GitCommitSignature? reflogActor,
    GitCommitCodec commitCodec = const GitCommitCodec(),
    GitTreeCodec? treeCodec,
  }) async {
    if (bare) {
      throw StateError('Bare repositories do not have a working tree.');
    }

    final currentIndex = await readIndex() ?? const GitIndex();
    final targetReferenceName = create
        ? _normalizeBranchReferenceName(target)
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
            '${_describeReflogLocation(currentHeadReference, currentHeadObjectId)} '
            'to ${_branchShortName(targetReferenceName)}',
      );
    } else {
      await _writeReferenceWithReflog(
        GitReference.direct('HEAD', targetObjectId),
        actor: _resolveReflogActor(reflogActor),
        message:
            'checkout: moving from '
            '${_describeReflogLocation(currentHeadReference, currentHeadObjectId)} '
            'to ${targetObjectId.hex}',
      );
    }

    if (track && targetReferenceName != null) {
      final inferredTracking = _inferBranchTrackingForCheckout(
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
        : _selectTreeEntries(sourceSnapshot.entries, normalizedPaths);
    final selectedCurrentIndexEntries = _selectTreeEntries(
      _treeEntriesFromIndex(currentIndex),
      normalizedPaths,
    );
    final selectedHeadEntries = _selectTreeEntries(
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
          ? _selectTreeEntries(
              _treeEntriesFromIndex(updatedIndex),
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
    final headSummary = _stashHeadSummary(
      baseObjectId.hex,
      _summarizeReflogMessage(baseCommit.message),
    );
    final stashMessage = _buildStashMessage(
      branchName: branchName,
      message: message,
      defaultSummary: headSummary,
    );
    // Индексный коммит всегда описывает HEAD, а не текст -m.
    final indexMessage = 'index on $branchName: $headSummary';
    final indexEntries = _treeEntriesFromIndex(currentIndex);
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
              '${_summarizeReflogMessage(stashMessage)}',
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
      message: 'stash: ${_summarizeReflogMessage(stashMessage)}',
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
          (left, right) => _comparePathDepthThenLexicographically(right, left),
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
    final selection = _selectStashStackEntry(stack, revision);
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
    final selection = _selectStashStackEntry(
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
      referenceName = _normalizeBranchReferenceName(branchName);
      if (await readReference(referenceName) != null) {
        throw StateError(
          'Branch already exists: ${_branchShortName(referenceName)}.',
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
      for (final directoryPath in _collectParentDirectories(
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

  Future<GitApplyResult> apply(
    Iterable<GitDiffEntry> entries, {
    bool check = false,
    bool threeWay = false,
    bool recordConflictsInIndex = false,
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

    final orderedEntries = entries.toList()
      ..sort((left, right) => left.path.compareTo(right.path));
    if (orderedEntries.isEmpty) {
      return GitApplyResult(files: const [], check: check);
    }

    final fileResults = <GitApplyFileResult>[];
    final writePlans = <_GitApplyWritePlan>[];
    for (final entry in orderedEntries) {
      final plan = await _planApplyEntry(entry, threeWay: threeWay);
      fileResults.add(plan.result);
      if (plan.writePlan case final writePlan?) {
        writePlans.add(writePlan);
      }
    }

    final result = GitApplyResult(files: fileResults, check: check);
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
    GitDiffCodec codec = const GitDiffCodec(),
  }) => apply(
    codec.decode(patchText),
    check: check,
    threeWay: threeWay,
    recordConflictsInIndex: recordConflictsInIndex,
  );

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

    final sourceDirectories = <String>{
      '',
      for (final input in normalizedInputs)
        ..._ignoreSourceDirectoriesForPath(input.normalizedPath),
    }.toList()..sort(_comparePathDepthThenLexicographically);
    final ignoreRules = await _loadIgnoreRules(sourceDirectories);

    final matches = <GitIgnoreMatch>[];
    for (final input in normalizedInputs) {
      final match = _matchIgnoredPath(
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
          'merge ${revision.trim()}: ${_summarizeReflogMessage(message ?? 'Merge ${revision.trim()}\n')}',
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
      message: 'merge --continue: ${_summarizeReflogMessage(mergeMessage)}',
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

  String resolveReferencePath(String referenceName) {
    final normalized = referenceName.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(
        referenceName,
        'referenceName',
        'Reference name must not be empty.',
      );
    }
    return normalized == 'HEAD'
        ? headFilePath
        : p.join(commonDirectoryPath, normalized);
  }

  String resolveReflogPath(String referenceName) {
    final normalized = _normalizeReflogReferenceName(referenceName);
    return normalized == 'HEAD'
        ? p.join(gitDirectoryPath, 'logs', 'HEAD')
        : p.join(commonDirectoryPath, 'logs', normalized);
  }

  Future<void> _writeReferenceWithReflog(
    GitReference reference, {
    required GitCommitSignature actor,
    required String message,
    GitReflogCodec codec = const GitReflogCodec(),
  }) async {
    final headReference = await readReference('HEAD');
    final headTargetReferenceName = headReference?.targetReferenceName;
    final oldReferenceObjectId = await resolveReferenceObjectId(reference.name);
    final oldHeadObjectId =
        reference.name == 'HEAD' || headTargetReferenceName == reference.name
        ? await resolveReferenceObjectId('HEAD')
        : null;

    await writeReference(reference);

    final newReferenceObjectId = await resolveReferenceObjectId(reference.name);
    await _appendReflogEntry(
      reference.name,
      GitReflogEntry(
        previousObjectId: oldReferenceObjectId,
        newObjectId: newReferenceObjectId,
        actor: actor,
        message: message,
      ),
      codec: codec,
    );
    if (reference.name != 'HEAD' && headTargetReferenceName == reference.name) {
      await _appendReflogEntry(
        'HEAD',
        GitReflogEntry(
          previousObjectId: oldHeadObjectId,
          newObjectId: newReferenceObjectId,
          actor: actor,
          message: message,
        ),
        codec: codec,
      );
    }
  }

  Future<void> _appendReflogEntry(
    String referenceName,
    GitReflogEntry entry, {
    GitReflogCodec codec = const GitReflogCodec(),
  }) async {
    final normalized = _normalizeReflogReferenceName(referenceName);
    if (!_shouldWriteReflogForReference(normalized)) {
      return;
    }

    final reflogFile = File(resolveReflogPath(normalized));
    await reflogFile.parent.create(recursive: true);
    await reflogFile.writeAsString(
      codec.encodeLine(entry),
      mode: FileMode.writeOnlyAppend,
      flush: true,
    );
  }

  Future<void> _writeReflogEntries(
    String referenceName,
    List<GitReflogEntry> entries, {
    GitReflogCodec codec = const GitReflogCodec(),
  }) async {
    final normalized = _normalizeReflogReferenceName(referenceName);
    if (!_shouldWriteReflogForReference(normalized)) {
      return;
    }

    final reflogFile = File(resolveReflogPath(normalized));
    if (entries.isEmpty) {
      if (await reflogFile.exists()) {
        await reflogFile.delete();
      }
      return;
    }

    await reflogFile.parent.create(recursive: true);
    await reflogFile.writeAsString(codec.encode(entries), flush: true);
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

    return _selectStashStackEntry(
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

  static String _describeReflogLocation(
    GitReference? headReference,
    GitObjectId? objectId,
  ) {
    final targetReferenceName = headReference?.targetReferenceName;
    if (targetReferenceName != null &&
        targetReferenceName.startsWith('refs/heads/')) {
      return _branchShortName(targetReferenceName);
    }
    return objectId?.hex ?? 'unborn';
  }

  static String _summarizeReflogMessage(String message) {
    final trimmed = message.trimRight();
    if (trimmed.isEmpty) {
      return 'update';
    }
    return LineSplitter.split(trimmed).first.trim();
  }

  static bool _shouldWriteReflogForReference(String referenceName) =>
      referenceName == 'HEAD' ||
      referenceName == 'refs/stash' ||
      referenceName.startsWith('refs/heads/');

  static String _normalizeReflogReferenceName(String referenceName) {
    final trimmed = referenceName.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(
        referenceName,
        'referenceName',
        'Reflog reference name must not be empty.',
      );
    }
    if (trimmed == 'HEAD') {
      return 'HEAD';
    }
    if (trimmed == 'stash') {
      return 'refs/stash';
    }
    return trimmed.startsWith('refs/') ? trimmed : 'refs/heads/$trimmed';
  }

  Future<GitObjectId> _peelTagObjectId(
    GitObjectId objectId, {
    GitTagCodec tagCodec = const GitTagCodec(),
  }) async {
    var currentObjectId = objectId;
    while (true) {
      final object = await readObject(currentObjectId);
      if (object == null || object.type != GitObjectType.tag) {
        return currentObjectId;
      }

      currentObjectId = tagCodec.decode(object.bytes).targetObjectId;
    }
  }

  static String _normalizeRemoteName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Remote name must not be empty.');
    }
    if (trimmed.contains(RegExp(r'[\s/\\]'))) {
      throw ArgumentError.value(
        name,
        'name',
        'Remote name must not contain whitespace or path separators.',
      );
    }
    return trimmed;
  }

  String _normalizeRemoteReferenceName(String name) {
    final normalized = _normalizeRelativeWorkTreePath(name);
    if (normalized == '.' || normalized.isEmpty) {
      throw ArgumentError.value(
        name,
        'name',
        'Remote reference name must not be empty.',
      );
    }
    return normalized;
  }

  Future<_GitConfigDocument> _readConfigDocument() async {
    final configFile = File(configFilePath);
    if (!await configFile.exists()) {
      return const _GitConfigDocument(
        preamble: <String>[],
        sections: <_GitConfigSection>[],
      );
    }

    final lines = await configFile.readAsLines();
    final preamble = <String>[];
    final sections = <_GitConfigSection>[];
    _GitConfigSection? currentSection;

    for (final line in lines) {
      if (_parseConfigSectionHeader(line) case final parsedHeader?) {
        if (currentSection != null) {
          sections.add(currentSection);
        }
        currentSection = _GitConfigSection(
          headerLine: line,
          name: parsedHeader.name,
          subsection: parsedHeader.subsection,
          bodyLines: const [],
        );
        continue;
      }

      if (currentSection == null) {
        preamble.add(line);
      } else {
        currentSection = currentSection.copyWith(
          bodyLines: [...currentSection.bodyLines, line],
        );
      }
    }

    if (currentSection != null) {
      sections.add(currentSection);
    }

    return _GitConfigDocument(preamble: preamble, sections: sections);
  }

  Future<void> _writeConfigDocument(_GitConfigDocument document) async {
    final lines = <String>[...document.preamble];

    for (final section in document.sections) {
      if (lines.isNotEmpty && lines.last.trim().isNotEmpty) {
        lines.add('');
      }
      lines.add(section.headerLine);
      lines.addAll(section.bodyLines);
    }

    final configFile = File(configFilePath);
    await configFile.parent.create(recursive: true);
    final contents = lines.isEmpty
        ? ''
        : '${lines.join('\n')}${lines.isEmpty ? '' : '\n'}';
    await configFile.writeAsString(contents, flush: true);
  }

  static ({String name, String? subsection})? _parseConfigSectionHeader(
    String line,
  ) {
    final match = RegExp(r'^\s*\[([^\s"\]]+)(?:\s+"([^"]+)")?\]\s*$')
        .firstMatch(line);
    if (match == null) {
      return null;
    }
    return (
      name: match.group(1)!.trim().toLowerCase(),
      subsection: match.group(2),
    );
  }

  static ({String key, String value})? _parseConfigKeyValue(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#') || trimmed.startsWith(';')) {
      return null;
    }

    final separatorIndex = trimmed.indexOf('=');
    if (separatorIndex == -1) {
      return (key: trimmed.toLowerCase(), value: 'true');
    }

    return (
      key: trimmed.substring(0, separatorIndex).trim().toLowerCase(),
      value: trimmed.substring(separatorIndex + 1).trim(),
    );
  }

  static bool _isRemoteConfigSection(_GitConfigSection section) =>
      section.name == 'remote' && section.subsection != null;

  static bool _isBranchConfigSection(_GitConfigSection section) =>
      section.name == 'branch' && section.subsection != null;

  static GitBranchTracking? _branchTrackingFromConfigSection(
    _GitConfigSection section,
  ) {
    String? remoteName;
    String? mergeReferenceName;

    for (final line in section.bodyLines) {
      final keyValue = _parseConfigKeyValue(line);
      if (keyValue == null) {
        continue;
      }
      switch (keyValue.key) {
        case 'remote':
          remoteName = keyValue.value;
        case 'merge':
          mergeReferenceName = keyValue.value;
      }
    }

    if (remoteName == null ||
        remoteName.isEmpty ||
        mergeReferenceName == null ||
        mergeReferenceName.isEmpty) {
      return null;
    }

    final referenceName = _normalizeBranchReferenceName(section.subsection!);
    return GitBranchTracking(
      branchName: section.subsection!,
      referenceName: referenceName,
      remoteName: remoteName,
      mergeReferenceName: mergeReferenceName,
    );
  }

  static GitRemote _remoteFromConfigSection(_GitConfigSection section) {
    final fetchRefSpecs = <GitRefSpec>[];
    final httpHeaders = <String, String>{};
    final sshHostKeyFingerprints = <String>[];
    String? url;
    String? pushUrl;
    String? sshPrivateKeyPath;
    String? sshPrivateKey;
    String? sshPrivateKeyPassphrase;
    String? sshPassword;
    String? sshKnownHostsPath;

    for (final line in section.bodyLines) {
      final keyValue = _parseConfigKeyValue(line);
      if (keyValue == null) {
        continue;
      }
      switch (keyValue.key) {
        case 'url':
          url = keyValue.value;
        case 'pushurl':
          pushUrl = keyValue.value;
        case 'fetch':
          fetchRefSpecs.add(GitRefSpec.parse(keyValue.value));
        case 'httpheader':
          final headerSeparator = keyValue.value.indexOf(':');
          if (headerSeparator <= 0) {
            continue;
          }
          final name = keyValue.value.substring(0, headerSeparator).trim();
          final value = keyValue.value.substring(headerSeparator + 1).trim();
          if (name.isEmpty) {
            continue;
          }
          httpHeaders[name] = value;
        case 'sshprivatekeypath':
          sshPrivateKeyPath = keyValue.value;
        case 'sshprivatekey':
          sshPrivateKey = keyValue.value;
        case 'sshprivatekeybase64':
          sshPrivateKey = utf8.decode(base64.decode(keyValue.value));
        case 'sshprivatekeypassphrase':
          sshPrivateKeyPassphrase = keyValue.value;
        case 'sshpassword':
          sshPassword = keyValue.value;
        case 'sshknownhostspath':
          sshKnownHostsPath = keyValue.value;
        case 'sshhostkeyfingerprint':
          sshHostKeyFingerprints.add(keyValue.value);
      }
    }

    if (url == null || url.isEmpty) {
      throw FormatException(
        'Remote config section is missing a url entry.',
        section.subsection,
      );
    }

    return GitRemote(
      name: section.subsection!,
      url: url,
      fetchRefSpecs: fetchRefSpecs,
      pushUrl: pushUrl,
      httpHeaders: httpHeaders,
      sshPrivateKeyPath: sshPrivateKeyPath,
      sshPrivateKey: sshPrivateKey,
      sshPrivateKeyPassphrase: sshPrivateKeyPassphrase,
      sshPassword: sshPassword,
      sshKnownHostsPath: sshKnownHostsPath,
      sshHostKeyFingerprints: sshHostKeyFingerprints,
    );
  }

  static _GitConfigSection _buildRemoteConfigSection(
    GitRemote remote,
  ) => _GitConfigSection(
    headerLine: '[remote "${remote.name}"]',
    name: 'remote',
    subsection: remote.name,
    bodyLines: [
      '\turl = ${remote.url}',
      if (remote.pushUrl != null) '\tpushurl = ${remote.pushUrl}',
      for (final header in remote.httpHeaders.entries)
        '\thttpHeader = ${header.key}: ${header.value}',
      if (remote.sshPrivateKeyPath != null)
        '\tsshPrivateKeyPath = ${remote.sshPrivateKeyPath}',
      if (remote.sshPrivateKey != null)
        '\tsshPrivateKeyBase64 = ${base64.encode(utf8.encode(remote.sshPrivateKey!))}',
      if (remote.sshPrivateKeyPassphrase != null)
        '\tsshPrivateKeyPassphrase = ${remote.sshPrivateKeyPassphrase}',
      if (remote.sshPassword != null) '\tsshPassword = ${remote.sshPassword}',
      if (remote.sshKnownHostsPath != null)
        '\tsshKnownHostsPath = ${remote.sshKnownHostsPath}',
      for (final fingerprint in remote.sshHostKeyFingerprints)
        '\tsshHostKeyFingerprint = $fingerprint',
      for (final fetchRefSpec in remote.fetchRefSpecs)
        '\tfetch = ${fetchRefSpec.storageValue}',
    ],
  );

  static _GitConfigSection _buildBranchConfigSection(
    GitBranchTracking tracking,
  ) => _GitConfigSection(
    headerLine: '[branch "${tracking.branchName}"]',
    name: 'branch',
    subsection: tracking.branchName,
    bodyLines: [
      '\tremote = ${tracking.remoteName}',
      '\tmerge = ${tracking.mergeReferenceName}',
    ],
  );

  static Future<void> _ensureCloneTargetReady(String targetPath) async {
    final entityType = await FileSystemEntity.type(
      targetPath,
      followLinks: false,
    );
    if (entityType == FileSystemEntityType.notFound) {
      await Directory(targetPath).create(recursive: true);
      return;
    }
    if (entityType == FileSystemEntityType.directory) {
      final entries = await Directory(targetPath)
          .list(followLinks: false)
          .toList();
      if (entries.isNotEmpty) {
        throw StateError('Clone target directory must be empty: $targetPath.');
      }
      return;
    }
    throw StateError(
      'Clone target path must be an empty directory: $targetPath.',
    );
  }

  static Future<void> _initializeRepositoryLayout(
    String gitDirectoryPath,
  ) async {
    final gitDirectory = Directory(gitDirectoryPath);
    await Directory(p.join(gitDirectory.path, 'objects'))
        .create(recursive: true);
    await Directory(p.join(gitDirectory.path, 'refs')).create(recursive: true);
    await Directory(p.join(gitDirectory.path, 'info')).create(recursive: true);
    await File(p.join(gitDirectory.path, 'HEAD'))
        .writeAsString('ref: refs/heads/main\n', flush: true);
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
          final wildcardValues = _matchRefSpecPattern(
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

          final destinationReferenceName = _expandRefSpecPattern(
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
            ? _normalizePushDestinationPattern(destination)
            : _normalizePushDestinationReferenceName(destination);
        if (destinationReferenceNamePattern.contains('*')) {
          for (final remoteReferenceName in remoteReferenceNames) {
            final wildcardValues = _matchRefSpecPattern(
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
        final sourcePattern = _normalizePushSourcePattern(normalizedSource);
        final destinationPattern = destination == null
            ? sourcePattern
            : _normalizePushDestinationPattern(destination);
        final normalizedDestinationHasWildcard = destinationPattern.contains(
          '*',
        );
        if (!sourcePattern.contains('*') || !normalizedDestinationHasWildcard) {
          throw UnsupportedError(
            'Wildcard push refspecs require matching source and destination wildcards.',
          );
        }

        for (final sourceReferenceName in localReferenceNames) {
          final wildcardValues = _matchRefSpecPattern(
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

          final destinationReferenceName = _expandRefSpecPattern(
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
          : _normalizePushDestinationReferenceName(refSpec.destination!);
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

  Future<List<String>> _listReferenceNamesUnder(
    String baseReferenceName,
  ) async {
    final referenceDirectory = Directory(
      resolveReferencePath(baseReferenceName),
    );
    if (!await referenceDirectory.exists()) {
      return const <String>[];
    }

    final referenceNames = <String>[];
    await for (final entity in referenceDirectory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) {
        continue;
      }
      referenceNames.add(
        p.posix.joinAll(
          p.split(p.relative(entity.path, from: commonDirectoryPath)),
        ),
      );
    }
    referenceNames.sort();
    return referenceNames;
  }

  Future<List<String>> _listReferenceNames(String prefix) async {
    final trimmed = prefix.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(
        prefix,
        'prefix',
        'Reference prefix must not be empty.',
      );
    }

    final normalized = trimmed == 'HEAD'
        ? 'HEAD'
        : trimmed.startsWith('refs/')
        ? trimmed
        : 'refs/$trimmed';
    final exactFile = File(resolveReferencePath(normalized));
    if (await exactFile.exists()) {
      return [normalized];
    }

    return _listReferenceNamesUnder(normalized);
  }

  static String _referenceShortName(String referenceName) {
    if (referenceName == 'HEAD') {
      return 'HEAD';
    }
    if (referenceName.startsWith('refs/heads/')) {
      return referenceName.substring('refs/heads/'.length);
    }
    if (referenceName.startsWith('refs/tags/')) {
      return referenceName.substring('refs/tags/'.length);
    }
    if (referenceName.startsWith('refs/remotes/')) {
      return referenceName.substring('refs/remotes/'.length);
    }
    return referenceName.startsWith('refs/')
        ? referenceName.substring('refs/'.length)
        : referenceName;
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
    base: _toConflictStageEntry(entries, 1),
    ours: _toConflictStageEntry(entries, 2),
    theirs: _toConflictStageEntry(entries, 3),
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
            _compareIndexStatus(referenceEntry, entry) !=
                GitFileStatus.unchanged) {
          return entry;
        }
      }
    }
    return _preferredConflictIndexEntryForWorkTree(entries);
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

  Future<int> _copyReachableObjectsFromRepository(
    _GitRemoteTransport remoteRepository,
    GitObjectId rootObjectId, {
    bool dryRun = false,
    required GitCommitCodec commitCodec,
    GitTreeCodec? treeCodec,
  }) async {
    final missingObjectIds = await _collectMissingReachableObjectIds(
      rootObjectId,
      sourceObjectReader: remoteRepository.readObject,
      destinationObjectReader: readObject,
      missingSourceDescription: 'Remote',
      commitCodec: commitCodec,
      treeCodec: treeCodec,
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
  }) async {
    final queue = <GitObjectId>[rootObjectId];
    final visited = <GitObjectId>{};
    final missingObjectIds = <GitObjectId>[];

    while (queue.isNotEmpty) {
      final objectId = queue.removeLast();
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
          queue.add(commit.tree);
          queue.addAll(commit.parents);
        case GitObjectType.tree:
          final effectiveTreeCodec = treeCodec?.algorithm == objectId.algorithm
              ? treeCodec!
              : GitTreeCodec(algorithm: objectId.algorithm);
          final entries = effectiveTreeCodec.decode(sourceObject.bytes);
          queue.addAll(entries.map((entry) => entry.objectId));
        case GitObjectType.tag:
          queue.add(_readTagTargetObjectId(sourceObject.bytes));
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

    final algorithm = _detectPackChecksumAlgorithm(packBytes);
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
    for (final entry in resolvedEntries) {
      await writeLooseObject(entry.object, algorithm: algorithm);
    }
    return resolvedEntries.length;
  }

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

  Future<GitObject?> _readObjectFromRepositories(
    GitObjectId objectId,
    _GitRemoteTransport remoteRepository,
  ) async =>
      await readObject(objectId) ?? await remoteRepository.readObject(objectId);

  static GitObjectId _readTagTargetObjectId(List<int> bytes) {
    final text = utf8.decode(bytes);
    for (final line in const LineSplitter().convert(text)) {
      if (line.isEmpty) {
        break;
      }
      if (line.startsWith('object ')) {
        return GitObjectId.fromHex(line.substring('object '.length).trim());
      }
    }
    throw const FormatException(
      'Tag object is missing the target object line.',
    );
  }

  Future<GitObjectId?> _resolveReferenceObjectId(
    String referenceName,
    Set<String> visitedReferences,
  ) async {
    final normalizedReferenceName = referenceName.trim();
    if (!visitedReferences.add(normalizedReferenceName)) {
      throw StateError(
        'Detected a symbolic reference cycle at $normalizedReferenceName.',
      );
    }

    final reference = await readReference(normalizedReferenceName);
    if (reference == null) {
      return null;
    }

    switch (reference.target) {
      case GitDirectReferenceTarget(:final objectId):
        return objectId;
      case GitSymbolicReferenceTarget(:final referenceName):
        return _resolveReferenceObjectId(referenceName, visitedReferences);
    }
  }

  static Future<GitRepository?> _discoverWorkTree(String workTreePath) async {
    final gitDirectory = Directory(p.join(workTreePath, '.git'));
    if (await gitDirectory.exists()) {
      final repository = GitRepository._(
        path: workTreePath,
        gitDirectoryPath: p.normalize(p.absolute(gitDirectory.path)),
        commonDirectoryPath: p.normalize(p.absolute(gitDirectory.path)),
        bare: false,
      );
      if (await repository.isValid()) {
        return repository;
      }
    }

    final gitFile = File(p.join(workTreePath, '.git'));
    if (await gitFile.exists()) {
      final resolvedGitDirectoryPath = await _resolveGitDirectoryPath(gitFile);
      if (resolvedGitDirectoryPath != null) {
        final resolvedCommonDirectoryPath = await _resolveCommonDirectoryPath(
          resolvedGitDirectoryPath,
        );
        final repository = GitRepository._(
          path: workTreePath,
          gitDirectoryPath: resolvedGitDirectoryPath,
          commonDirectoryPath: resolvedCommonDirectoryPath,
          bare: false,
        );
        if (await repository.isValid()) {
          return repository;
        }
      }
    }

    return null;
  }

  static Future<GitRepository?> _discoverBare(String repositoryPath) async {
    final repository = GitRepository.bare(repositoryPath);
    if (await repository.isValid()) {
      return repository;
    }
    return null;
  }

  static Future<String?> _resolveGitDirectoryPath(File gitFile) async {
    final lines = await gitFile.readAsLines();
    if (lines.isEmpty) {
      return null;
    }

    final firstLine = lines.first.trim();
    if (!firstLine.startsWith('gitdir:')) {
      return null;
    }

    final rawPath = firstLine.substring('gitdir:'.length).trim();
    if (rawPath.isEmpty) {
      return null;
    }

    final resolvedPath = p.isAbsolute(rawPath)
        ? rawPath
        : p.join(p.dirname(gitFile.path), rawPath);
    return p.normalize(p.absolute(resolvedPath));
  }

  static Future<String> _resolveCommonDirectoryPath(
    String gitDirectoryPath,
  ) async {
    final commonDirectoryFile = File(p.join(gitDirectoryPath, 'commondir'));
    if (!await commonDirectoryFile.exists()) {
      return gitDirectoryPath;
    }

    final rawPath = (await commonDirectoryFile.readAsString()).trim();
    if (rawPath.isEmpty) {
      return gitDirectoryPath;
    }

    final resolvedPath = p.isAbsolute(rawPath)
        ? rawPath
        : p.join(gitDirectoryPath, rawPath);
    return p.normalize(p.absolute(resolvedPath));
  }

  static String _normalizePath(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(value, 'path', 'Path must not be empty.');
    }
    return p.normalize(trimmed);
  }

  Future<String> _normalizeNewWorkTreePath(String workTreePath) async {
    final normalized = p.normalize(p.absolute(_normalizePath(workTreePath)));
    final entityType = await FileSystemEntity.type(
      normalized,
      followLinks: false,
    );
    if (entityType != FileSystemEntityType.notFound) {
      throw StateError('Worktree path already exists: $normalized.');
    }

    final currentPath = p.normalize(p.absolute(path));
    final sharedPath = p.normalize(p.absolute(commonDirectoryPath));
    if (_pathsOverlap(normalized, currentPath) ||
        _pathsOverlap(normalized, sharedPath)) {
      throw StateError(
        'Worktree path must not overlap the current repository layout.',
      );
    }

    return normalized;
  }

  Future<String> _allocateWorktreeId(String normalizedWorkTreePath) async {
    final baseName = p.basename(normalizedWorkTreePath);
    final sanitizedBaseName = _sanitizeWorktreeId(baseName);
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

  static bool _pathsOverlap(String left, String right) =>
      left == right || p.isWithin(left, right) || p.isWithin(right, left);

  String _normalizeRelativeWorkTreePath(String relativePath) {
    final normalized = p.normalize(relativePath.trim());
    if (normalized.isEmpty || p.isAbsolute(normalized)) {
      throw ArgumentError.value(
        relativePath,
        'relativePath',
        'Working tree paths must be non-empty relative paths.',
      );
    }

    final repositoryRelativePath = p.posix.joinAll(p.split(normalized));
    final segments = p.posix.split(repositoryRelativePath);
    if (segments.isNotEmpty && segments.first == '.git') {
      throw ArgumentError.value(
        relativePath,
        'relativePath',
        'Working tree paths must not point inside the .git directory.',
      );
    }

    return repositoryRelativePath;
  }

  static List<String> _collectParentDirectories(List<String> paths) {
    final directories = <String>{};
    for (final path in paths) {
      final segments = p.posix.split(path);
      for (var index = 1; index < segments.length; index++) {
        directories.add(p.posix.joinAll(segments.take(index)));
      }
    }

    return directories.toList()..sort(_comparePathDepthThenLexicographically);
  }

  Future<String> _resolveWritableReferenceName(String referenceName) async {
    final reference = await readReference(referenceName);
    if (reference == null) {
      return referenceName;
    }

    return switch (reference.target) {
      GitSymbolicReferenceTarget(:final referenceName) => referenceName,
      _ => reference.name,
    };
  }

  Future<({List<String> pathsToStage, List<String> pathsToRemove})>
  _collectAddTargetsForPathspec(
    String pathspec,
    GitIndex index, {
    required bool includeIgnored,
  }) async {
    if (!_hasPathspecWildcards(pathspec)) {
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
      if (!_pathMatchesPathspec(path, pathspec)) {
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
          if (!_pathEqualsOrWithin(entry.path, normalizedPath)) {
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
            if (_pathEqualsOrWithin(entry.path, normalizedPath)) entry.path,
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
        if (_pathMatchesAnyPathspec(path, normalizedPathspecs)) path,
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
      (pathspec) => _pathMatchesPathspec(path, pathspec),
    );
  }

  static bool _pathMatchesPathspec(String path, String pathspec) {
    final normalizedPathspec = p.posix.joinAll(
      p.split(p.normalize(pathspec.trim())),
    );
    if (!_hasPathspecWildcards(normalizedPathspec)) {
      return _pathEqualsOrWithin(path, normalizedPathspec);
    }

    final basenameOnly = !normalizedPathspec.contains('/');
    final matcher = _compilePathspecPattern(
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

  Future<GitCommit> _readCommit(
    GitObjectId commitId, {
    required GitCommitCodec codec,
  }) async {
    final commitObject = await readObject(commitId);
    if (commitObject == null || commitObject.type != GitObjectType.commit) {
      throw StateError('Missing commit object for $commitId.');
    }
    return codec.decode(commitObject.bytes);
  }

  Future<_GitApplyPlan> _planApplyEntry(
    GitDiffEntry entry, {
    required bool threeWay,
  }) async {
    if (entry.binary) {
      return _planBinaryApplyEntry(entry);
    }

    if (!_isSupportedApplyMode(entry.oldMode) ||
        !_isSupportedApplyMode(entry.newMode)) {
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
        : _decodeApplyText(currentBytes);
    if (currentText == null) {
      return _GitApplyPlan(
        result: GitApplyFileResult(
          path: entry.path,
          status: GitApplyStatus.conflict,
          message: 'Current file contents could not be interpreted as text for this patch.',
        ),
      );
    }

    final patchedText = _applyDiffHunksToText(currentText, entry.hunks);
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
        if (!_listEquals(currentBytes, expectedOldBytes)) {
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
        if (!_listEquals(currentBytes, expectedOldBytes)) {
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
  }) async {
    if (entry.changeType != GitDiffChangeType.modified ||
        entry.oldObjectId == null) {
      return null;
    }

    final baseBytes = await _readBlobObjectBytes(entry.oldObjectId!);
    final baseText = _decodeApplyText(baseBytes);
    if (baseText == null) {
      return _GitApplyPlan(
        result: GitApplyFileResult(
          path: entry.path,
          status: GitApplyStatus.conflict,
          message: '3-way patch application could not decode the recorded base as text.',
        ),
      );
    }

    final incomingText = _applyDiffHunksToText(baseText, entry.hunks);
    if (incomingText == null) {
      return _GitApplyPlan(
        result: GitApplyFileResult(
          path: entry.path,
          status: GitApplyStatus.conflict,
          message: 'Patch hunks did not apply cleanly to their recorded base.',
        ),
      );
    }

    final mergeResult = _threeWayMergeTexts(
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
    List<GitDiffHunk> hunks,
  ) {
    if (hunks.isEmpty) {
      return currentText;
    }

    final currentLines = _splitDiffLines(currentText);
    final resultLines = <String>[];
    var currentIndex = 0;

    for (final hunk in hunks.toList()..sort(_compareDiffHunks)) {
      final expectedStart = hunk.oldStart == 0 ? 0 : hunk.oldStart - 1;
      if (expectedStart < currentIndex || expectedStart > currentLines.length) {
        return null;
      }

      resultLines.addAll(currentLines.sublist(currentIndex, expectedStart));
      currentIndex = expectedStart;

      for (final line in hunk.lines) {
        switch (line.type) {
          case GitDiffLineType.context:
            if (currentIndex >= currentLines.length ||
                currentLines[currentIndex] != line.text) {
              return null;
            }
            resultLines.add(currentLines[currentIndex]);
            currentIndex++;
          case GitDiffLineType.deletion:
            if (currentIndex >= currentLines.length ||
                currentLines[currentIndex] != line.text) {
              return null;
            }
            currentIndex++;
          case GitDiffLineType.addition:
            resultLines.add(line.text);
        }
      }
    }

    resultLines.addAll(currentLines.sublist(currentIndex));
    return resultLines.join();
  }

  static _GitThreeWayMergeResult _threeWayMergeTexts({
    required String baseText,
    required String currentText,
    required String incomingText,
  }) {
    final baseLines = _splitDiffLines(baseText);
    final currentChanges = _extractTextChanges(baseText, currentText);
    final incomingChanges = _extractTextChanges(baseText, incomingText);

    final conflicts = <GitApplyConflict>[];
    for (final currentChange in currentChanges) {
      for (final incomingChange in incomingChanges) {
        if (_textChangesEquivalent(currentChange, incomingChange)) {
          continue;
        }
        if (!_textChangesConflict(currentChange, incomingChange)) {
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
            currentText: _renderChangeAgainstBaseSegment(
              baseLines,
              currentChange,
              start,
              end,
            ),
            incomingText: _renderChangeAgainstBaseSegment(
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
          (currentChange) =>
              _textChangesEquivalent(currentChange, incomingChange),
        ))
          incomingChange,
    ]..sort(_compareTextChanges);

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
    final operations = _buildDiffOperations(
      _splitDiffLines(baseText),
      _splitDiffLines(updatedText),
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
        _parseIgnoreRules(
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
        _parseIgnoreRules(
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
      final parsedRule = _parseIgnoreRuleLine(
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
      matcher: _compileIgnorePattern(patternText, basenameOnly: basenameOnly),
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
    for (final subject in _buildIgnoreSubjects(
      path,
      isDirectory: isDirectory,
    )) {
      var ignored = false;
      _GitIgnoreRule? ignoredBy;

      for (final rule in rules) {
        if (!_ignoreRuleAppliesToSubject(rule, subject)) {
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
    return _pathEqualsOrWithin(subject.path, rule.sourceDirectory) &&
        subject.path != rule.sourceDirectory;
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

  Future<GitObjectId?> _resolveRevisionBase(String baseSpec) async {
    final reflogMatch = RegExp(r'^(.*)@\{(\d+)\}$').firstMatch(baseSpec.trim());
    if (reflogMatch != null) {
      final reflogReference = reflogMatch.group(1)!;
      final entryIndex = int.parse(reflogMatch.group(2)!);
      final normalizedReflogReference = reflogReference.isEmpty
          ? 'HEAD'
          : _normalizeReflogReferenceName(reflogReference);
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

  static String _normalizeBranchReferenceName(String branchName) {
    final trimmed = branchName.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(
        branchName,
        'branchName',
        'Branch name must not be empty.',
      );
    }

    final referenceName = trimmed.startsWith('refs/heads/')
        ? trimmed
        : 'refs/heads/$trimmed';
    return GitReference.symbolic('HEAD', referenceName).targetReferenceName!;
  }

  static String _normalizeTagReferenceName(String tagName) {
    final trimmed = tagName.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(
        tagName,
        'tagName',
        'Tag name must not be empty.',
      );
    }

    final referenceName = trimmed.startsWith('refs/tags/')
        ? trimmed
        : 'refs/tags/$trimmed';
    return GitReference.symbolic('HEAD', referenceName).targetReferenceName!;
  }

  static String _branchShortName(String referenceName) =>
      referenceName.startsWith('refs/heads/')
      ? referenceName.substring('refs/heads/'.length)
      : referenceName;

  static String _tagShortName(String referenceName) =>
      referenceName.startsWith('refs/tags/')
      ? referenceName.substring('refs/tags/'.length)
      : referenceName;

  static GitBranchTracking? _inferBranchTrackingForCheckout({
    required String targetReferenceName,
    required String startPoint,
    String? trackingRemoteName,
  }) {
    final normalizedTrackingRemoteName =
        trackingRemoteName?.trim().isEmpty ?? true
        ? null
        : _normalizeRemoteName(trackingRemoteName!);
    final normalizedStartPoint = startPoint.trim();

    if (normalizedStartPoint.startsWith('refs/remotes/')) {
      final remainder = normalizedStartPoint.substring('refs/remotes/'.length);
      final separatorIndex = remainder.indexOf('/');
      if (separatorIndex <= 0 || separatorIndex == remainder.length - 1) {
        return null;
      }
      final remoteName =
          normalizedTrackingRemoteName ??
          _normalizeRemoteName(remainder.substring(0, separatorIndex));
      final mergeReferenceName =
          'refs/heads/${remainder.substring(separatorIndex + 1)}';
      return GitBranchTracking(
        branchName: _branchShortName(targetReferenceName),
        referenceName: targetReferenceName,
        remoteName: remoteName,
        mergeReferenceName: mergeReferenceName,
      );
    }

    if (normalizedTrackingRemoteName == null) {
      return null;
    }
    return GitBranchTracking(
      branchName: _branchShortName(targetReferenceName),
      referenceName: targetReferenceName,
      remoteName: normalizedTrackingRemoteName,
      mergeReferenceName: targetReferenceName,
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
    final branchName = _branchShortName(localReferenceName);
    final normalizedRequestedRemoteName = requestedRemoteName == null
        ? null
        : _normalizeRemoteName(requestedRemoteName);
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
        'refs/remotes/$remoteName/${_branchShortName(mergeReferenceName)}';
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
      branchName: _branchShortName(localReferenceName),
      referenceName: localReferenceName,
      remoteName: remoteName,
      mergeReferenceName: mapping.destinationReferenceName,
    );
  }

  Future<String?> _resolveCheckoutBranchReferenceName(String target) async {
    final referenceName = _normalizeBranchReferenceName(target);
    final reference = await readReference(referenceName);
    if (reference == null) {
      return null;
    }
    return referenceName;
  }

  Future<Map<String, _GitTreeSnapshotEntry>> _readCommitTreeEntries(
    GitObjectId commitId, {
    required GitCommitCodec commitCodec,
    GitTreeCodec? treeCodec,
  }) async {
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
      if (requestedPaths.any((path) => _pathEqualsOrWithin(entry.key, path))) {
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
      final changeType = _treeSnapshotDiffChangeType(oldEntry, newEntry);
      if (changeType == null) {
        continue;
      }
      diffEntries.add(
        _buildDiffEntry(
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

  Future<String> _currentBranchDisplayName() async {
    final headReference = await readReference('HEAD');
    final targetReferenceName = headReference?.targetReferenceName;
    if (targetReferenceName != null &&
        targetReferenceName.startsWith('refs/heads/')) {
      return _branchShortName(targetReferenceName);
    }

    final objectId = await resolveReferenceObjectId('HEAD');
    return objectId == null
        ? 'detached HEAD'
        : 'detached HEAD at ${objectId.hex}';
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

      if (_treeSnapshotEntriesEqual(currentEntry, incomingEntry)) {
        if (currentEntry != null) {
          mergedEntries[path] = currentEntry;
        }
        continue;
      }
      if (_treeSnapshotEntriesEqual(baseEntry, currentEntry)) {
        if (incomingEntry != null) {
          mergedEntries[path] = incomingEntry;
        }
        continue;
      }
      if (_treeSnapshotEntriesEqual(baseEntry, incomingEntry)) {
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
    if (!_isMergeTextMode(currentEntry.mode)) {
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

    final mergeResult = _threeWayMergeTexts(
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
  ) async => _decodeApplyText(await _readBlobObjectBytes(entry.objectId));

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
                  _pathEqualsOrWithin(workTreePath, targetPath) ||
                  _pathEqualsOrWithin(targetPath, workTreePath),
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
        (left, right) => _comparePathDepthThenLexicographically(right, left),
      );
    for (final path in pathsToDelete) {
      await _deleteWorkTreePath(path);
    }

    final pathsToWrite = targetPaths.toList()
      ..sort(_comparePathDepthThenLexicographically);
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

  Future<void> _writeTreeSnapshotEntryToWorkTree(
    String relativePath,
    _GitTreeSnapshotEntry entry,
  ) async {
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
    await File(absolutePath).writeAsBytes(bytes, flush: true);
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
            : _decodeApplyText(await _readBlobObjectBytes(entry.oldObjectId!)),
    };
    if (baseText == null) {
      return null;
    }

    final incomingText = entry.changeType == GitDiffChangeType.deleted
        ? null
        : _applyDiffHunksToText(baseText, entry.hunks);
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
                _comparePathDepthThenLexicographically(right, left),
          );
    for (final path in pathsToDelete) {
      await _deleteWorkTreePath(path);
    }

    final pathsToWrite = sourceEntries.keys.toList()
      ..sort(_comparePathDepthThenLexicographically);
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
      if (entry.mode == '040000') {
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
        mode: switch (_fileModeFromStat(stat)) {
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
      if (_pathEqualsOrWithin(relativePath, '.git')) {
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

    directEntries.sort(_compareTreeEntries);
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
    final leftBytes = [...left.nameBytes, if (left.mode == '040000') 0x2f];
    final rightBytes = [...right.nameBytes, if (right.mode == '040000') 0x2f];
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
    final binary = _isBinaryDiffBytes(oldBytes) || _isBinaryDiffBytes(newBytes);
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
          : _buildUnifiedDiffHunks(
              oldBytes == null ? '' : _decodeDiffText(oldBytes),
              newBytes == null ? '' : _decodeDiffText(newBytes),
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
    final oldLines = _splitDiffLines(oldText);
    final newLines = _splitDiffLines(newText);
    final operations = _buildDiffOperations(oldLines, newLines);
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
          _buildDiffHunkFromOperationRange(
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
      _buildDiffHunkFromOperationRange(
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

    return GitDiffHunk(
      oldStart: operations[hunkStart].oldLineNumber,
      oldLineCount: hunkOperations
          .where((operation) => operation.type != GitDiffLineType.addition)
          .length,
      newStart: operations[hunkStart].newLineNumber,
      newLineCount: hunkOperations
          .where((operation) => operation.type != GitDiffLineType.deletion)
          .length,
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

final class _GitTreeSnapshotEntry {
  const _GitTreeSnapshotEntry({required this.objectId, required this.mode});

  final GitObjectId objectId;
  final String mode;
}

final class _GitWorkTreeSnapshotEntry {
  const _GitWorkTreeSnapshotEntry({
    required this.objectId,
    required this.mode,
    required this.bytes,
  });

  final GitObjectId objectId;
  final String mode;
  final List<int> bytes;
}

final class _GitDiffOperation {
  const _GitDiffOperation({
    required this.type,
    required this.text,
    required this.oldLineNumber,
    required this.newLineNumber,
  });

  final GitDiffLineType type;
  final String text;
  final int oldLineNumber;
  final int newLineNumber;
}

final class _GitApplyPlan {
  const _GitApplyPlan({required this.result, this.writePlan});

  final GitApplyFileResult result;
  final _GitApplyWritePlan? writePlan;
}

final class _GitApplyWritePlan {
  const _GitApplyWritePlan({
    required this.path,
    required this.mode,
    required this.delete,
    this.bytes,
  });

  final String path;
  final String? mode;
  final bool delete;
  final List<int>? bytes;
}

final class _GitThreeWayMergeResult {
  const _GitThreeWayMergeResult({
    required this.mergedText,
    required this.conflicts,
  });

  final String mergedText;
  final List<GitApplyConflict> conflicts;
}

final class _GitTextChange {
  const _GitTextChange({
    required this.baseStart,
    required this.baseEnd,
    required this.replacement,
  });

  final int baseStart;
  final int baseEnd;
  final List<String> replacement;
}

final class _GitIgnoreRule {
  const _GitIgnoreRule({
    required this.pattern,
    required this.source,
    required this.sourceDirectory,
    required this.lineNumber,
    required this.negated,
    required this.directoryOnly,
    required this.basenameOnly,
    required this.matcher,
  });

  final String pattern;
  final String source;
  final String sourceDirectory;
  final int lineNumber;
  final bool negated;
  final bool directoryOnly;
  final bool basenameOnly;
  final Pattern matcher;
}

final class _GitIgnoreSubject {
  const _GitIgnoreSubject({required this.path, required this.isDirectory});

  final String path;
  final bool isDirectory;
}

final class _GitConfigDocument {
  const _GitConfigDocument({required this.preamble, required this.sections});

  final List<String> preamble;
  final List<_GitConfigSection> sections;
}

final class _GitConfigSection {
  const _GitConfigSection({
    required this.headerLine,
    required this.name,
    required this.subsection,
    required this.bodyLines,
  });

  final String headerLine;
  final String name;
  final String? subsection;
  final List<String> bodyLines;

  _GitConfigSection copyWith({
    String? headerLine,
    String? name,
    String? subsection,
    List<String>? bodyLines,
  }) => _GitConfigSection(
    headerLine: headerLine ?? this.headerLine,
    name: name ?? this.name,
    subsection: subsection ?? this.subsection,
    bodyLines: bodyLines ?? this.bodyLines,
  );
}

final class _GitStashStackEntry {
  const _GitStashStackEntry({
    required this.revision,
    required this.referenceName,
    required this.stashObjectId,
    required this.baseObjectId,
    required this.indexObjectId,
    required this.actor,
    required this.message,
    required this.reflogMessage,
    this.untrackedObjectId,
  });

  final String revision;
  final String referenceName;
  final GitObjectId stashObjectId;
  final GitObjectId baseObjectId;
  final GitObjectId indexObjectId;
  final GitObjectId? untrackedObjectId;
  final GitCommitSignature actor;
  final String message;
  final String reflogMessage;
}

final class _GitMergeOperationState {
  const _GitMergeOperationState({
    required this.referenceName,
    required this.currentObjectId,
    required this.incomingObjectId,
    required this.message,
    this.baseObjectId,
    this.originalIndexBytes,
  });

  factory _GitMergeOperationState.fromJson(Map<String, dynamic> json) {
    final originalIndexBytesText = json['originalIndexBytes'] as String?;
    return _GitMergeOperationState(
      referenceName: json['referenceName'] as String,
      currentObjectId: GitObjectId.fromHex(json['currentObjectId'] as String),
      incomingObjectId: GitObjectId.fromHex(json['incomingObjectId'] as String),
      baseObjectId: json['baseObjectId'] == null
          ? null
          : GitObjectId.fromHex(json['baseObjectId'] as String),
      message: json['message'] as String,
      originalIndexBytes: originalIndexBytesText == null
          ? null
          : base64.decode(originalIndexBytesText),
    );
  }

  final String referenceName;
  final GitObjectId currentObjectId;
  final GitObjectId incomingObjectId;
  final GitObjectId? baseObjectId;
  final String message;
  final List<int>? originalIndexBytes;

  Map<String, Object?> toJson() => {
    'referenceName': referenceName,
    'currentObjectId': currentObjectId.hex,
    'incomingObjectId': incomingObjectId.hex,
    'baseObjectId': baseObjectId?.hex,
    'message': message,
    'originalIndexBytes': originalIndexBytes == null
        ? null
        : base64.encode(originalIndexBytes!),
  };
}

final class _GitApplyOperationState {
  const _GitApplyOperationState({
    required this.conflictPaths,
    this.originalIndexBytes,
  });

  factory _GitApplyOperationState.fromJson(Map<String, dynamic> json) {
    final originalIndexBytesText = json['originalIndexBytes'] as String?;
    return _GitApplyOperationState(
      conflictPaths: [
        for (final path in json['conflictPaths'] as List<dynamic>)
          path as String,
      ],
      originalIndexBytes: originalIndexBytesText == null
          ? null
          : base64.decode(originalIndexBytesText),
    );
  }

  final List<String> conflictPaths;
  final List<int>? originalIndexBytes;

  Map<String, Object?> toJson() => {
    'conflictPaths': conflictPaths,
    'originalIndexBytes': originalIndexBytes == null
        ? null
        : base64.encode(originalIndexBytes!),
  };
}

final class _GitRemoteTransport {
  _GitRemoteTransport._filesystem({
    required this.remoteUrl,
    required this.repository,
  }) : httpBaseUri = null,
       httpHeaders = const <String, String>{},
       sshRemote = null;

  _GitRemoteTransport._http({
    required this.remoteUrl,
    required this.httpBaseUri,
    required this.httpHeaders,
  }) : repository = null,
       sshRemote = null;

  static Future<_GitRemoteTransport> open(
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
  }) async {
    final trimmedUrl = remoteUrl.trim();
    if (trimmedUrl.isEmpty) {
      throw StateError('Remote URL must not be empty.');
    }

    if (trimmedUrl.startsWith('file://')) {
      throw UnsupportedError(
        'Unsupported remote transport for $operation: $trimmedUrl.',
      );
    }

    final parsedUri = Uri.tryParse(trimmedUrl);
    if (parsedUri != null &&
        (parsedUri.scheme == 'http' || parsedUri.scheme == 'https')) {
      return _GitRemoteTransport._http(
        remoteUrl: trimmedUrl,
        httpBaseUri: _normalizeHttpBaseUri(parsedUri),
        httpHeaders: httpHeaders,
      );
    }

    final sshRemote = _tryParseSshRemote(
      trimmedUrl,
      sshPrivateKeyPath: sshPrivateKeyPath,
      sshPrivateKey: sshPrivateKey,
      sshPrivateKeyPassphrase: sshPrivateKeyPassphrase,
      sshPassword: sshPassword,
      sshKnownHostsPath: sshKnownHostsPath,
      sshHostKeyFingerprints: sshHostKeyFingerprints,
    );
    if (sshRemote != null) {
      throw UnsupportedError(
        'Unsupported remote transport for $operation: $trimmedUrl.',
      );
    }

    if (trimmedUrl.contains('://')) {
      throw UnsupportedError(
        'Unsupported remote transport for $operation: $trimmedUrl.',
      );
    }

    final remotePath = p.isAbsolute(trimmedUrl)
        ? trimmedUrl
        : p.join(basePath, trimmedUrl);
    return _openFilesystem(trimmedUrl, remotePath);
  }

  static Future<_GitRemoteTransport> _openFilesystem(
    String remoteUrl,
    String remotePath,
  ) async {
    final repository = await GitRepository.discover(remotePath);
    if (repository == null) {
      throw StateError('Could not discover remote repository at $remoteUrl.');
    }

    return _GitRemoteTransport._filesystem(
      remoteUrl: remoteUrl,
      repository: repository,
    );
  }

  static _GitSshRemoteConfig? _tryParseSshRemote(
    String remoteUrl, {
    String? sshPrivateKeyPath,
    String? sshPrivateKey,
    String? sshPrivateKeyPassphrase,
    String? sshPassword,
    String? sshKnownHostsPath,
    Iterable<String> sshHostKeyFingerprints = const <String>[],
  }) {
    final parsedUri = Uri.tryParse(remoteUrl);
    if (parsedUri != null && parsedUri.scheme == 'ssh') {
      final host = parsedUri.host;
      if (host.isEmpty) {
        return null;
      }
      final path = parsedUri.path.isEmpty ? '/' : parsedUri.path;
      return _GitSshRemoteConfig(
        host: host,
        port: parsedUri.hasPort ? parsedUri.port : 22,
        username: parsedUri.userInfo.isEmpty
            ? Platform.environment['USER'] ??
                  Platform.environment['USERNAME'] ??
                  'git'
            : parsedUri.userInfo,
        repositoryPath: path,
        privateKeyPath: sshPrivateKeyPath,
        privateKey: sshPrivateKey,
        privateKeyPassphrase: sshPrivateKeyPassphrase,
        password: sshPassword,
        knownHostsPath: sshKnownHostsPath,
        hostKeyFingerprints: sshHostKeyFingerprints.toList(),
      );
    }

    final scpMatch = RegExp(r'^([^@]+)@([^:]+):(.+)$').firstMatch(remoteUrl);
    if (scpMatch == null) {
      return null;
    }
    return _GitSshRemoteConfig(
      host: scpMatch.group(2)!,
      port: 22,
      username: scpMatch.group(1)!,
      repositoryPath: scpMatch.group(3)!,
      privateKeyPath: sshPrivateKeyPath,
      privateKey: sshPrivateKey,
      privateKeyPassphrase: sshPrivateKeyPassphrase,
      password: sshPassword,
      knownHostsPath: sshKnownHostsPath,
      hostKeyFingerprints: sshHostKeyFingerprints.toList(),
    );
  }

  static Uri _normalizeHttpBaseUri(Uri uri) {
    final sanitized = uri.replace(query: null, fragment: null);
    final normalizedPath = sanitized.path.endsWith('/')
        ? sanitized.path
        : '${sanitized.path}/';
    return sanitized.replace(path: normalizedPath);
  }

  final String remoteUrl;
  final GitRepository? repository;
  final Uri? httpBaseUri;
  final Map<String, String> httpHeaders;
  final _GitSshRemoteConfig? sshRemote;

  final Map<String, GitObjectId> _httpReferenceObjectIdsCache = {};
  GitReference? _httpHeadReferenceCache;
  List<String>? _httpPackNamesCache;
  final Map<String, List<int>> _httpPackIndexBytesCache = {};
  final Map<String, List<int>> _httpPackBytesCache = {};
  final Map<GitObjectId, GitObject> _httpSmartObjectCache = {};
  _GitSmartHttpAdvertisement? _httpUploadPackAdvertisementCache;
  _GitSmartHttpAdvertisement? _httpReceivePackAdvertisementCache;
  bool _didProbeHttpUploadPackAdvertisement = false;
  bool _didProbeHttpReceivePackAdvertisement = false;
  List<int>? _pendingHttpReceivePackBytes;
  final Map<GitObjectId, GitObject> _sshSmartObjectCache = {};
  _GitSmartHttpAdvertisement? _sshUploadPackAdvertisementCache;
  _GitSmartHttpAdvertisement? _sshReceivePackAdvertisementCache;
  bool _didProbeSshUploadPackAdvertisement = false;
  bool _didProbeSshReceivePackAdvertisement = false;
  bool _didPopulateSshReachableObjectCache = false;
  List<int>? _pendingSshReceivePackBytes;

  bool get bare => repository?.bare ?? true;

  Future<GitReference?> readReference(String referenceName) async {
    if (repository case final repository?) {
      return repository.readReference(referenceName);
    }
    if (sshRemote != null) {
      return _readSshReference(referenceName);
    }

    if (referenceName == 'HEAD') {
      final cached = _httpHeadReferenceCache;
      if (cached != null) {
        return cached;
      }
      final advertisement = await _loadHttpSmartUploadPackAdvertisement();
      final smartHeadReference = advertisement?.headReference;
      if (smartHeadReference != null) {
        _httpHeadReferenceCache = smartHeadReference;
        return smartHeadReference;
      }
      final contents = await _fetchHttpText('HEAD');
      if (contents == null) {
        return null;
      }
      final reference = GitReference.fromStorageValue(
        'HEAD',
        contents.trimRight(),
      );
      _httpHeadReferenceCache = reference;
      return reference;
    }

    final advertisedObjectId = (await _loadHttpSmartUploadPackAdvertisement())
        ?.references[referenceName];
    if (advertisedObjectId != null) {
      return GitReference.direct(referenceName, advertisedObjectId);
    }

    final contents = await _fetchHttpText(referenceName);
    if (contents != null) {
      return GitReference.fromStorageValue(referenceName, contents.trimRight());
    }

    final objectId = await resolveReferenceObjectId(referenceName);
    if (objectId == null) {
      return null;
    }
    return GitReference.direct(referenceName, objectId);
  }

  Future<GitObjectId?> resolveReferenceObjectId(String referenceName) async {
    if (repository case final repository?) {
      return repository.resolveReferenceObjectId(referenceName);
    }
    if (sshRemote != null) {
      return _resolveSshReferenceObjectId(referenceName);
    }

    if (referenceName == 'HEAD') {
      final headReference = await readReference('HEAD');
      if (headReference == null) {
        return null;
      }
      return switch (headReference.target) {
        GitDirectReferenceTarget(:final objectId) => objectId,
        GitSymbolicReferenceTarget(:final referenceName) =>
          await resolveReferenceObjectId(referenceName),
      };
    }

    final references = await _loadHttpReferenceObjectIds();
    final cachedObjectId = references[referenceName];
    if (cachedObjectId != null) {
      return cachedObjectId;
    }

    final contents = await _fetchHttpText(referenceName);
    if (contents == null) {
      return null;
    }
    final reference = GitReference.fromStorageValue(
      referenceName,
      contents.trimRight(),
    );
    return switch (reference.target) {
      GitDirectReferenceTarget(:final objectId) => objectId,
      GitSymbolicReferenceTarget(:final referenceName) =>
        await resolveReferenceObjectId(referenceName),
    };
  }

  Future<List<String>> listReferenceNamesUnder(String baseReferenceName) async {
    if (repository case final repository?) {
      return repository._listReferenceNamesUnder(baseReferenceName);
    }
    if (sshRemote != null) {
      return _listSshReferenceNamesUnder(baseReferenceName);
    }

    final prefix = '$baseReferenceName/';
    final references = await _loadHttpReferenceObjectIds();
    final names = <String>[
      for (final referenceName in references.keys)
        if (referenceName.startsWith(prefix)) referenceName,
    ];
    final headReference = await readReference('HEAD');
    final headTargetReferenceName = headReference?.targetReferenceName;
    if (headTargetReferenceName != null &&
        headTargetReferenceName.startsWith(prefix) &&
        !names.contains(headTargetReferenceName)) {
      names.add(headTargetReferenceName);
    }
    names.sort();
    return names;
  }

  Future<GitObject?> readObject(GitObjectId objectId) async {
    if (repository case final repository?) {
      return repository.readObject(objectId);
    }
    if (sshRemote != null) {
      final cached = _sshSmartObjectCache[objectId];
      if (cached != null) {
        return cached;
      }
      return _readSshObject(objectId);
    }
    final cached = _httpSmartObjectCache[objectId];
    if (cached != null) {
      return cached;
    }
    return _readHttpObject(objectId, activePackNames: const <String>{});
  }

  Future<void> writeReference(GitReference reference) async {
    if (repository case final repository?) {
      await repository.writeReference(reference);
      return;
    }
    if (sshRemote != null) {
      if (reference.target case GitDirectReferenceTarget(:final objectId)) {
        final previousObjectId = await resolveReferenceObjectId(reference.name);
        await _sendSshReceivePack([
          _GitSmartReceivePackCommand(
            referenceName: reference.name,
            previousObjectId: previousObjectId,
            nextObjectId: objectId,
          ),
        ], packBytes: _pendingSshReceivePackBytes);
        _pendingSshReceivePackBytes = null;
        _invalidateSshCaches();
        return;
      }
      throw UnsupportedError(
        'SSH remotes only support direct reference updates for ${reference.name}.',
      );
    }
    if (reference.target case GitDirectReferenceTarget(:final objectId)) {
      final previousObjectId = await resolveReferenceObjectId(reference.name);
      await _sendSmartHttpReceivePack([
        _GitSmartReceivePackCommand(
          referenceName: reference.name,
          previousObjectId: previousObjectId,
          nextObjectId: objectId,
        ),
      ], packBytes: _pendingHttpReceivePackBytes);
      _pendingHttpReceivePackBytes = null;
      _invalidateHttpCaches();
      return;
    }
    throw UnsupportedError(
      'HTTP remotes only support direct reference updates for ${reference.name}.',
    );
  }

  Future<bool> deleteReference(String referenceName) async {
    if (repository case final repository?) {
      return repository.deleteReference(referenceName);
    }
    if (sshRemote != null) {
      final previousObjectId = await resolveReferenceObjectId(referenceName);
      if (previousObjectId == null) {
        return false;
      }
      await _sendSshReceivePack([
        _GitSmartReceivePackCommand(
          referenceName: referenceName,
          previousObjectId: previousObjectId,
          nextObjectId: null,
        ),
      ], packBytes: _pendingSshReceivePackBytes);
      _pendingSshReceivePackBytes = null;
      _invalidateSshCaches();
      return true;
    }
    final previousObjectId = await resolveReferenceObjectId(referenceName);
    if (previousObjectId == null) {
      return false;
    }
    await _sendSmartHttpReceivePack([
      _GitSmartReceivePackCommand(
        referenceName: referenceName,
        previousObjectId: previousObjectId,
        nextObjectId: null,
      ),
    ], packBytes: _pendingHttpReceivePackBytes);
    _pendingHttpReceivePackBytes = null;
    _invalidateHttpCaches();
    return true;
  }

  Future<List<int>> exportPackForObjectIds(List<GitObjectId> objectIds) async {
    if (repository case final repository?) {
      return repository._exportPackForObjectIds(
        objectIds,
        objectReader: (objectId) => repository.readObject(objectId),
      );
    }
    if (objectIds.isEmpty) {
      return const <int>[];
    }

    if (httpBaseUri != null) {
      final smartPackBytes = await _fetchSmartHttpPackBytes(objectIds);
      if (smartPackBytes != null) {
        return smartPackBytes;
      }
    }

    final algorithm = objectIds.first.algorithm;
    final entries = <GitPackObjectEntry>[];
    for (final objectId in objectIds) {
      if (objectId.algorithm != algorithm) {
        throw StateError(
          'Pack export requires all object ids to use the same algorithm.',
        );
      }
      final object = await readObject(objectId);
      if (object == null) {
        throw StateError('Missing object for pack export: $objectId.');
      }
      entries.add(GitPackObjectEntry(object));
    }

    return GitPackCodec(checksumAlgorithm: algorithm)
        .encode(GitPack(checksumAlgorithm: algorithm, entries: entries));
  }

  Future<int> importPackBytes(List<int> packBytes) async {
    if (repository case final repository?) {
      return repository._importPackBytes(packBytes);
    }
    if (sshRemote != null) {
      if (packBytes.isEmpty) {
        _pendingSshReceivePackBytes = null;
        return 0;
      }
      final algorithm = GitRepository._detectPackChecksumAlgorithm(packBytes);
      final entries = GitPackCodec(checksumAlgorithm: algorithm)
          .decode(packBytes)
          .entries;
      _pendingSshReceivePackBytes = List<int>.unmodifiable(packBytes);
      return entries.length;
    }
    if (packBytes.isEmpty) {
      _pendingHttpReceivePackBytes = null;
      return 0;
    }
    final algorithm = GitRepository._detectPackChecksumAlgorithm(packBytes);
    final entries = GitPackCodec(checksumAlgorithm: algorithm)
        .decode(packBytes)
        .entries;
    _pendingHttpReceivePackBytes = List<int>.unmodifiable(packBytes);
    return entries.length;
  }

  Future<Map<String, GitObjectId>> _loadHttpReferenceObjectIds() async {
    if (_httpReferenceObjectIdsCache.isNotEmpty) {
      return _httpReferenceObjectIdsCache;
    }

    final advertisement = await _loadHttpSmartUploadPackAdvertisement();
    if (advertisement != null) {
      _httpReferenceObjectIdsCache.addAll(advertisement.references);
      if (advertisement.headReference != null) {
        _httpHeadReferenceCache ??= advertisement.headReference;
      }
      if (_httpReferenceObjectIdsCache.isNotEmpty) {
        return _httpReferenceObjectIdsCache;
      }
    }

    final infoRefsText = await _fetchHttpText('info/refs');
    if (infoRefsText == null) {
      return _httpReferenceObjectIdsCache;
    }

    for (final line in const LineSplitter().convert(infoRefsText)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) {
        continue;
      }
      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length < 2 || !GitObjectId.isValidHex(parts.first)) {
        continue;
      }
      _httpReferenceObjectIdsCache[parts[1]] = GitObjectId.fromHex(parts.first);
    }
    return _httpReferenceObjectIdsCache;
  }

  Future<List<String>> _loadHttpPackNames() async {
    final cached = _httpPackNamesCache;
    if (cached != null) {
      return cached;
    }

    final infoPacksText = await _fetchHttpText('objects/info/packs');
    if (infoPacksText == null) {
      _httpPackNamesCache = const <String>[];
      return _httpPackNamesCache!;
    }

    final packNames = <String>[
      for (final line in const LineSplitter().convert(infoPacksText))
        if (line.startsWith('P ')) line.substring(2).trim(),
    ]..sort();
    _httpPackNamesCache = packNames;
    return packNames;
  }

  Future<GitObject?> _readHttpObject(
    GitObjectId objectId, {
    required Set<String> activePackNames,
  }) async {
    final cachedObject = _httpSmartObjectCache[objectId];
    if (cachedObject != null) {
      return cachedObject;
    }

    final looseObjectBytes = await _fetchHttpBytes(
      'objects/${objectId.hex.substring(0, 2)}/${objectId.hex.substring(2)}',
    );
    if (looseObjectBytes != null) {
      final object = const GitLooseObjectCodec().decode(
        zlib.decode(looseObjectBytes),
      );
      _httpSmartObjectCache[objectId] = object;
      return object;
    }

    final packNames = await _loadHttpPackNames();
    if (packNames.isNotEmpty) {
      final packCodec = GitPackCodec(checksumAlgorithm: objectId.algorithm);
      final packIndexCodec = GitPackIndexCodec(
        checksumAlgorithm: objectId.algorithm,
      );
      final packResolver = GitPackResolver(
        objectIdAlgorithm: objectId.algorithm,
      );

      for (final packName in packNames) {
        if (activePackNames.contains(packName)) {
          continue;
        }

        final indexBytes = await _fetchCachedHttpPackIndexBytes(packName);
        if (indexBytes == null) {
          continue;
        }
        final index = packIndexCodec.decode(indexBytes);
        if (index.entryForObjectId(objectId) == null) {
          continue;
        }

        final packBytes = await _fetchCachedHttpPackBytes(packName);
        if (packBytes == null) {
          continue;
        }
        final pack = packCodec.decode(packBytes);
        final resolvedEntries = await packResolver.resolve(
          pack,
          externalBaseResolver: (baseObjectId) => _readHttpObject(
            baseObjectId,
            activePackNames: {...activePackNames, packName},
          ),
        );
        for (final resolvedEntry in resolvedEntries) {
          _httpSmartObjectCache[resolvedEntry.objectId] = resolvedEntry.object;
          if (resolvedEntry.objectId == objectId) {
            return resolvedEntry.object;
          }
        }
      }
    }

    final smartPackBytes = await _fetchSmartHttpPackBytes([objectId]);
    if (smartPackBytes != null) {
      await _cacheSmartHttpPack(smartPackBytes, algorithm: objectId.algorithm);
      return _httpSmartObjectCache[objectId];
    }

    return null;
  }

  Future<void> _cacheSmartHttpPack(
    List<int> packBytes, {
    required GitHashAlgorithm algorithm,
  }) async {
    if (packBytes.isEmpty) {
      return;
    }
    final pack = GitPackCodec(checksumAlgorithm: algorithm).decode(packBytes);
    final resolvedEntries = await GitPackResolver(objectIdAlgorithm: algorithm)
        .resolve(
          pack,
          externalBaseResolver: (baseObjectId) async {
            final cached = _httpSmartObjectCache[baseObjectId];
            if (cached != null) {
              return cached;
            }
            return _readHttpObject(
              baseObjectId,
              activePackNames: const <String>{},
            );
          },
        );
    for (final entry in resolvedEntries) {
      _httpSmartObjectCache[entry.objectId] = entry.object;
    }
  }

  Future<_GitSmartHttpAdvertisement?>
  _loadHttpSmartUploadPackAdvertisement() async {
    if (_didProbeHttpUploadPackAdvertisement) {
      return _httpUploadPackAdvertisementCache;
    }
    _didProbeHttpUploadPackAdvertisement = true;
    try {
      _httpUploadPackAdvertisementCache = await _loadHttpSmartAdvertisement(
        'git-upload-pack',
      );
      return _httpUploadPackAdvertisementCache;
    } catch (_) {
      _didProbeHttpUploadPackAdvertisement = false;
      rethrow;
    }
  }

  Future<_GitSmartHttpAdvertisement?>
  _loadHttpSmartReceivePackAdvertisement() async {
    if (_didProbeHttpReceivePackAdvertisement) {
      return _httpReceivePackAdvertisementCache;
    }
    _didProbeHttpReceivePackAdvertisement = true;
    try {
      _httpReceivePackAdvertisementCache = await _loadHttpSmartAdvertisement(
        'git-receive-pack',
      );
      return _httpReceivePackAdvertisementCache;
    } catch (_) {
      _didProbeHttpReceivePackAdvertisement = false;
      rethrow;
    }
  }

  Future<_GitSmartHttpAdvertisement?> _loadHttpSmartAdvertisement(
    String service,
  ) async {
    final responseBytes = await _fetchHttpBytes('info/refs?service=$service');
    return _parseSmartAdvertisementBytes(service, responseBytes);
  }

  static _GitSmartHttpAdvertisement? _parseSmartAdvertisementBytes(
    String service,
    List<int>? responseBytes, {
    bool expectServiceHeader = true,
  }) {
    if (responseBytes == null || responseBytes.isEmpty) {
      return null;
    }

    try {
      var offset = 0;
      final references = <String, GitObjectId>{};
      GitReference? headReference;
      var sawServiceHeader = !expectServiceHeader;
      var firstReferenceLine = true;

      while (offset + 4 <= responseBytes.length) {
        final length = _GitPktLine.decodeLength(responseBytes, offset);
        if (length == null) {
          break;
        }
        offset += 4;
        if (length == 0) {
          continue;
        }
        final payloadLength = length - 4;
        if (payloadLength < 0 ||
            offset + payloadLength > responseBytes.length) {
          break;
        }
        final payload = responseBytes.sublist(offset, offset + payloadLength);
        offset += payloadLength;

        final payloadText = utf8.decode(payload, allowMalformed: true);
        if (!sawServiceHeader && payloadText == '# service=$service\n') {
          sawServiceHeader = true;
          continue;
        }

        final nulIndex = payload.indexOf(0);
        final referenceText = utf8
            .decode(
              nulIndex == -1 ? payload : payload.sublist(0, nulIndex),
              allowMalformed: true,
            )
            .trimRight();
        if (referenceText.isEmpty) {
          continue;
        }
        final separatorIndex = referenceText.indexOf(' ');
        if (separatorIndex <= 0) {
          continue;
        }
        final objectIdText = referenceText.substring(0, separatorIndex);
        final referenceName = referenceText.substring(separatorIndex + 1);
        if (!GitObjectId.isValidHex(objectIdText) ||
            referenceName.endsWith('^{}')) {
          firstReferenceLine = false;
          continue;
        }
        final objectId = GitObjectId.fromHex(objectIdText);
        references[referenceName] = objectId;

        if (firstReferenceLine && nulIndex != -1) {
          final capabilityText = utf8.decode(
            payload.sublist(nulIndex + 1),
            allowMalformed: true,
          );
          for (final capability in capabilityText.trim().split(' ')) {
            if (capability.startsWith('symref=HEAD:')) {
              final targetReferenceName = capability
                  .substring('symref=HEAD:'.length)
                  .trim();
              if (targetReferenceName.isNotEmpty) {
                headReference = GitReference.symbolic(
                  'HEAD',
                  targetReferenceName,
                );
              }
            }
          }
        }
        firstReferenceLine = false;
      }

      if (!sawServiceHeader) {
        return null;
      }
      return _GitSmartHttpAdvertisement(
        service: service,
        references: references,
        headReference: headReference,
      );
    } on FormatException {
      return null;
    }
  }

  Future<GitReference?> _readSshReference(String referenceName) async {
    if (referenceName == 'HEAD') {
      final advertisement = await _loadSshUploadPackAdvertisement();
      return advertisement?.headReference;
    }
    final objectId = await _resolveSshReferenceObjectId(referenceName);
    if (objectId == null) {
      return null;
    }
    return GitReference.direct(referenceName, objectId);
  }

  Future<GitObjectId?> _resolveSshReferenceObjectId(
    String referenceName,
  ) async {
    if (referenceName == 'HEAD') {
      final headReference = await _readSshReference('HEAD');
      if (headReference == null) {
        return null;
      }
      return switch (headReference.target) {
        GitDirectReferenceTarget(:final objectId) => objectId,
        GitSymbolicReferenceTarget(:final referenceName) =>
          await _resolveSshReferenceObjectId(referenceName),
      };
    }
    final advertisement = await _loadSshUploadPackAdvertisement();
    return advertisement?.references[referenceName];
  }

  Future<List<String>> _listSshReferenceNamesUnder(
    String baseReferenceName,
  ) async {
    final advertisement = await _loadSshUploadPackAdvertisement();
    final prefix = '$baseReferenceName/';
    final names = <String>[
      for (final referenceName
          in advertisement?.references.keys ?? const <String>[])
        if (referenceName.startsWith(prefix)) referenceName,
    ];
    final headTargetReferenceName =
        advertisement?.headReference?.targetReferenceName;
    if (headTargetReferenceName != null &&
        headTargetReferenceName.startsWith(prefix) &&
        !names.contains(headTargetReferenceName)) {
      names.add(headTargetReferenceName);
    }
    names.sort();
    return names;
  }

  Future<GitObject?> _readSshObject(GitObjectId objectId) async {
    final cached = _sshSmartObjectCache[objectId];
    if (cached != null) {
      return cached;
    }
    await _ensureSshReachableObjectCacheLoaded();
    return _sshSmartObjectCache[objectId];
  }

  Future<void> _ensureSshReachableObjectCacheLoaded() async {
    if (_didPopulateSshReachableObjectCache) {
      return;
    }
    _didPopulateSshReachableObjectCache = true;
    final advertisement = await _loadSshUploadPackAdvertisement();
    final wantObjectIds = {
      for (final objectId
          in advertisement?.references.values ?? const <GitObjectId>[])
        objectId,
    }.toList();
    if (wantObjectIds.isEmpty) {
      return;
    }
    final packBytes = await _fetchSshPackBytes(wantObjectIds);
    if (packBytes == null) {
      return;
    }
    await _cacheSshPack(packBytes, algorithm: wantObjectIds.first.algorithm);
  }

  Future<void> _cacheSshPack(
    List<int> packBytes, {
    required GitHashAlgorithm algorithm,
  }) async {
    if (packBytes.isEmpty) {
      return;
    }
    final pack = GitPackCodec(checksumAlgorithm: algorithm).decode(packBytes);
    final resolvedEntries = await GitPackResolver(objectIdAlgorithm: algorithm)
        .resolve(
          pack,
          externalBaseResolver: (baseObjectId) async {
            final cached = _sshSmartObjectCache[baseObjectId];
            if (cached != null) {
              return cached;
            }
            return _readSshObject(baseObjectId);
          },
        );
    for (final entry in resolvedEntries) {
      _sshSmartObjectCache[entry.objectId] = entry.object;
    }
  }

  Future<_GitSmartHttpAdvertisement?> _loadSshUploadPackAdvertisement() async {
    if (_didProbeSshUploadPackAdvertisement) {
      return _sshUploadPackAdvertisementCache;
    }
    _didProbeSshUploadPackAdvertisement = true;
    try {
      _sshUploadPackAdvertisementCache = _parseSmartAdvertisementBytes(
        'git-upload-pack',
        await _runSshService('git-upload-pack', advertiseRefs: true),
        expectServiceHeader: false,
      );
      return _sshUploadPackAdvertisementCache;
    } catch (_) {
      _didProbeSshUploadPackAdvertisement = false;
      rethrow;
    }
  }

  Future<_GitSmartHttpAdvertisement?> _loadSshReceivePackAdvertisement() async {
    if (_didProbeSshReceivePackAdvertisement) {
      return _sshReceivePackAdvertisementCache;
    }
    _didProbeSshReceivePackAdvertisement = true;
    try {
      _sshReceivePackAdvertisementCache = _parseSmartAdvertisementBytes(
        'git-receive-pack',
        await _runSshService('git-receive-pack', advertiseRefs: true),
        expectServiceHeader: false,
      );
      return _sshReceivePackAdvertisementCache;
    } catch (_) {
      _didProbeSshReceivePackAdvertisement = false;
      rethrow;
    }
  }

  Future<List<int>?> _fetchSshPackBytes(
    List<GitObjectId> wantObjectIds, {
    Iterable<GitObjectId> haveObjectIds = const <GitObjectId>[],
  }) async {
    final advertisement = await _loadSshUploadPackAdvertisement();
    if (advertisement == null || wantObjectIds.isEmpty) {
      return null;
    }

    final algorithm = wantObjectIds.first.algorithm;
    final requestBytes = <int>[];
    for (final objectId in wantObjectIds) {
      if (objectId.algorithm != algorithm) {
        throw StateError(
          'SSH pack requests require a consistent hash algorithm.',
        );
      }
      requestBytes.addAll(_GitPktLine.encodeText('want ${objectId.hex}\n'));
    }
    requestBytes.addAll(_GitPktLine.flushBytes);
    for (final objectId in haveObjectIds) {
      if (objectId.algorithm == algorithm) {
        requestBytes.addAll(_GitPktLine.encodeText('have ${objectId.hex}\n'));
      }
    }
    requestBytes.addAll(_GitPktLine.encodeText('done\n'));

    final responseBytes = await _runSshService(
      'git-upload-pack',
      requestBytes: requestBytes,
    );
    final packOffset = _GitPktLine.findPackOffset(responseBytes);
    if (packOffset == null) {
      return null;
    }
    return responseBytes.sublist(packOffset);
  }

  Future<void> _sendSshReceivePack(
    List<_GitSmartReceivePackCommand> commands, {
    List<int>? packBytes,
  }) async {
    final advertisement = await _loadSshReceivePackAdvertisement();
    if (advertisement == null) {
      throw UnsupportedError(
        'SSH remote does not advertise git-receive-pack support.',
      );
    }
    if (commands.isEmpty) {
      return;
    }

    final requestBytes = <int>[];
    for (var index = 0; index < commands.length; index++) {
      final command = commands[index];
      final previousObjectIdText =
          command.previousObjectId?.hex ??
          _zeroObjectIdHex(command.zeroAlgorithm);
      final nextObjectIdText =
          command.nextObjectId?.hex ?? _zeroObjectIdHex(command.zeroAlgorithm);
      final line =
          '$previousObjectIdText $nextObjectIdText ${command.referenceName}';
      requestBytes.addAll(
        _GitPktLine.encodeText(
          index == 0 ? '$line\u0000report-status\n' : '$line\n',
        ),
      );
    }
    requestBytes.addAll(_GitPktLine.flushBytes);
    if (packBytes != null && packBytes.isNotEmpty) {
      requestBytes.addAll(packBytes);
    }

    final responseBytes = await _runSshService(
      'git-receive-pack',
      requestBytes: requestBytes,
    );
    final responseLines = _GitPktLine.decodePayloadTexts(responseBytes);
    final unpackStatus = responseLines
        .where((line) => line.startsWith('unpack '))
        .map((line) => line.trim())
        .firstWhere((_) => true, orElse: () => '');
    if (unpackStatus.isNotEmpty && unpackStatus != 'unpack ok') {
      throw StateError('SSH push failed during unpack: $unpackStatus');
    }
    final rejectedLine = responseLines
        .where((line) => line.startsWith('ng '))
        .map((line) => line.trim())
        .firstWhere((_) => true, orElse: () => '');
    if (rejectedLine.isNotEmpty) {
      throw StateError('SSH push rejected: $rejectedLine');
    }
  }

  Future<List<int>> _runSshService(
    String service, {
    List<int>? requestBytes,
    bool advertiseRefs = false,
  }) {
    throw UnsupportedError(
      'SSH remotes are not available on the virtual host '
      '($service, advertiseRefs=$advertiseRefs, bytes=${requestBytes?.length ?? 0}).',
    );
  }

  void _invalidateSshCaches() {
    _sshSmartObjectCache.clear();
    _sshUploadPackAdvertisementCache = null;
    _sshReceivePackAdvertisementCache = null;
    _didProbeSshUploadPackAdvertisement = false;
    _didProbeSshReceivePackAdvertisement = false;
    _didPopulateSshReachableObjectCache = false;
  }

  Future<List<int>?> _fetchSmartHttpPackBytes(
    List<GitObjectId> wantObjectIds, {
    Iterable<GitObjectId> haveObjectIds = const <GitObjectId>[],
  }) async {
    final advertisement = await _loadHttpSmartUploadPackAdvertisement();
    if (advertisement == null || wantObjectIds.isEmpty) {
      return null;
    }

    final algorithm = wantObjectIds.first.algorithm;
    final requestBytes = <int>[];
    for (final objectId in wantObjectIds) {
      if (objectId.algorithm != algorithm) {
        throw StateError(
          'Smart HTTP pack requests require a consistent hash algorithm.',
        );
      }
      requestBytes.addAll(_GitPktLine.encodeText('want ${objectId.hex}\n'));
    }
    requestBytes.addAll(_GitPktLine.flushBytes);
    for (final objectId in haveObjectIds) {
      if (objectId.algorithm == algorithm) {
        requestBytes.addAll(_GitPktLine.encodeText('have ${objectId.hex}\n'));
      }
    }
    requestBytes.addAll(_GitPktLine.encodeText('done\n'));

    final responseBytes = await _fetchHttpBytes(
      'git-upload-pack',
      method: 'POST',
      body: requestBytes,
      extraHeaders: const {
        'Accept': 'application/x-git-upload-pack-result',
        'Content-Type': 'application/x-git-upload-pack-request',
      },
    );
    if (responseBytes == null || responseBytes.isEmpty) {
      return null;
    }

    final packOffset = _GitPktLine.findPackOffset(responseBytes);
    if (packOffset == null) {
      final packetTexts = _GitPktLine.decodePayloadTexts(responseBytes);
      if (packetTexts.any((line) => line.startsWith('ERR '))) {
        throw StateError(
          packetTexts.firstWhere((line) => line.startsWith('ERR ')).trim(),
        );
      }
      return null;
    }
    return responseBytes.sublist(packOffset);
  }

  Future<void> _sendSmartHttpReceivePack(
    List<_GitSmartReceivePackCommand> commands, {
    List<int>? packBytes,
  }) async {
    final advertisement = await _loadHttpSmartReceivePackAdvertisement();
    if (advertisement == null) {
      throw UnsupportedError(
        'HTTP remote does not advertise git-receive-pack support.',
      );
    }
    if (commands.isEmpty) {
      return;
    }

    final requestBytes = <int>[];
    for (var index = 0; index < commands.length; index++) {
      final command = commands[index];
      final previousObjectIdText =
          command.previousObjectId?.hex ??
          _zeroObjectIdHex(command.zeroAlgorithm);
      final nextObjectIdText =
          command.nextObjectId?.hex ?? _zeroObjectIdHex(command.zeroAlgorithm);
      final line =
          '$previousObjectIdText $nextObjectIdText ${command.referenceName}';
      requestBytes.addAll(
        _GitPktLine.encodeText(
          index == 0 ? '$line\u0000report-status\n' : '$line\n',
        ),
      );
    }
    requestBytes.addAll(_GitPktLine.flushBytes);
    if (packBytes != null && packBytes.isNotEmpty) {
      requestBytes.addAll(packBytes);
    }

    final responseBytes = await _fetchHttpBytes(
      'git-receive-pack',
      method: 'POST',
      body: requestBytes,
      extraHeaders: const {
        'Accept': 'application/x-git-receive-pack-result',
        'Content-Type': 'application/x-git-receive-pack-request',
      },
    );
    if (responseBytes == null) {
      throw StateError('Smart HTTP push did not return a receive-pack result.');
    }

    final responseLines = _GitPktLine.decodePayloadTexts(responseBytes);
    final unpackStatus = responseLines
        .where((line) => line.startsWith('unpack '))
        .map((line) => line.trim())
        .firstWhere((_) => true, orElse: () => '');
    if (unpackStatus.isNotEmpty && unpackStatus != 'unpack ok') {
      throw StateError('Smart HTTP push failed during unpack: $unpackStatus');
    }
    final rejectedLine = responseLines
        .where((line) => line.startsWith('ng '))
        .map((line) => line.trim())
        .firstWhere((_) => true, orElse: () => '');
    if (rejectedLine.isNotEmpty) {
      throw StateError('Smart HTTP push rejected: $rejectedLine');
    }
  }

  void _invalidateHttpCaches() {
    _httpReferenceObjectIdsCache.clear();
    _httpHeadReferenceCache = null;
    _httpPackNamesCache = null;
    _httpPackIndexBytesCache.clear();
    _httpPackBytesCache.clear();
    _httpSmartObjectCache.clear();
    _httpUploadPackAdvertisementCache = null;
    _httpReceivePackAdvertisementCache = null;
    _didProbeHttpUploadPackAdvertisement = false;
    _didProbeHttpReceivePackAdvertisement = false;
  }

  Future<List<int>?> _fetchCachedHttpPackIndexBytes(String packName) async {
    final cached = _httpPackIndexBytesCache[packName];
    if (cached != null) {
      return cached;
    }

    final indexName = p.setExtension(packName, '.idx');
    final bytes = await _fetchHttpBytes('objects/pack/$indexName');
    if (bytes != null) {
      _httpPackIndexBytesCache[packName] = bytes;
    }
    return bytes;
  }

  Future<List<int>?> _fetchCachedHttpPackBytes(String packName) async {
    final cached = _httpPackBytesCache[packName];
    if (cached != null) {
      return cached;
    }

    final bytes = await _fetchHttpBytes('objects/pack/$packName');
    if (bytes != null) {
      _httpPackBytesCache[packName] = bytes;
    }
    return bytes;
  }

  Future<List<int>?> _fetchHttpBytes(
    String relativePath, {
    String method = 'GET',
    List<int>? body,
    Map<String, String> extraHeaders = const {},
    Set<int> missingStatusCodes = const {HttpStatus.notFound},
  }) async {
    final requestUri = httpBaseUri!.resolve(relativePath);
    final client = gitHttp ?? PackageGitHttp(timeout: gitFs.limits.runTimeout);
    final response = await client.send(
      method: method,
      uri: requestUri,
      headers: {...httpHeaders, ...extraHeaders},
      body: body,
    );
    if (missingStatusCodes.contains(response.statusCode)) {
      return null;
    }
    if (response.statusCode != HttpStatus.ok) {
      throw StateError(
        'Remote HTTP request failed for $requestUri: '
                '${response.statusCode} ${response.reasonPhrase} '
                '${gitHttpBodyText(response.body).trim()}'
            .trim(),
      );
    }
    return response.body;
  }

  Future<String?> _fetchHttpText(String relativePath) async {
    final bytes = await _fetchHttpBytes(relativePath);
    if (bytes == null) {
      return null;
    }
    return utf8.decode(bytes);
  }
}

final class _GitFetchMapping {
  const _GitFetchMapping({
    required this.sourceReferenceName,
    required this.destinationReferenceName,
    required this.objectId,
    required this.force,
  });

  final String sourceReferenceName;
  final String destinationReferenceName;
  final GitObjectId objectId;
  final bool force;
}

final class _GitPushMapping {
  const _GitPushMapping({
    required this.sourceReferenceName,
    required this.destinationReferenceName,
    required this.objectId,
    required this.force,
  });

  final String? sourceReferenceName;
  final String destinationReferenceName;
  final GitObjectId? objectId;
  final bool force;

  bool get isDeletion => objectId == null;
}

final class _GitSmartHttpAdvertisement {
  const _GitSmartHttpAdvertisement({
    required this.service,
    required this.references,
    this.headReference,
  });

  final String service;
  final Map<String, GitObjectId> references;
  final GitReference? headReference;
}

final class _GitSmartReceivePackCommand {
  const _GitSmartReceivePackCommand({
    required this.referenceName,
    required this.previousObjectId,
    required this.nextObjectId,
  });

  final String referenceName;
  final GitObjectId? previousObjectId;
  final GitObjectId? nextObjectId;

  GitHashAlgorithm get zeroAlgorithm =>
      previousObjectId?.algorithm ??
      nextObjectId?.algorithm ??
      GitHashAlgorithm.sha1;
}

final class _GitSshRemoteConfig {
  const _GitSshRemoteConfig({
    required this.host,
    required this.port,
    required this.username,
    required this.repositoryPath,
    this.privateKeyPath,
    this.privateKey,
    this.privateKeyPassphrase,
    this.password,
    this.knownHostsPath,
    this.hostKeyFingerprints = const <String>[],
  });

  final String host;
  final int port;
  final String username;
  final String repositoryPath;
  final String? privateKeyPath;
  final String? privateKey;
  final String? privateKeyPassphrase;
  final String? password;
  final String? knownHostsPath;
  final List<String> hostKeyFingerprints;
}

// ignore: avoid_classes_with_only_static_members, набор функций pkt-line из референса
final class _GitPktLine {
  static const List<int> flushBytes = <int>[0x30, 0x30, 0x30, 0x30];

  static List<int> encodeText(String text) {
    final payload = utf8.encode(text);
    final length = payload.length + 4;
    final prefix = length.toRadixString(16).padLeft(4, '0');
    return <int>[...ascii.encode(prefix), ...payload];
  }

  static int? decodeLength(List<int> bytes, int offset) {
    if (offset + 4 > bytes.length) {
      return null;
    }
    final lengthText = ascii.decode(
      bytes.sublist(offset, offset + 4),
      allowInvalid: true,
    );
    return int.tryParse(lengthText, radix: 16);
  }

  static int? findPackOffset(List<int> bytes) {
    for (var index = 0; index <= bytes.length - 4; index++) {
      if (bytes[index] == 0x50 &&
          bytes[index + 1] == 0x41 &&
          bytes[index + 2] == 0x43 &&
          bytes[index + 3] == 0x4b) {
        return index;
      }
    }
    return null;
  }

  static List<String> decodePayloadTexts(List<int> bytes) {
    final lines = <String>[];
    var offset = 0;
    while (offset + 4 <= bytes.length) {
      final length = decodeLength(bytes, offset);
      if (length == null) {
        break;
      }
      offset += 4;
      if (length == 0) {
        continue;
      }
      final payloadLength = length - 4;
      if (payloadLength < 0 || offset + payloadLength > bytes.length) {
        break;
      }
      lines.add(
        utf8.decode(
          bytes.sublist(offset, offset + payloadLength),
          allowMalformed: true,
        ),
      );
      offset += payloadLength;
    }
    return lines;
  }
}

String _zeroObjectIdHex(GitHashAlgorithm algorithm) =>
    '0' * algorithm.hexLength;

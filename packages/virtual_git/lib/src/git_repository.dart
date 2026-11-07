// ignore_for_file: cascade_invocations
// ignore_for_file: avoid-substring
// Причина: разбор hex и каскады оставлены как в git_core.
/// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Файлы идут в виртуальную ФС, SSH отключён.
///
/// Команды репозитория лежат в part-файлах `repository/`. Это расширения
/// [GitRepository] в той же библиотеке: приватные методы видны между файлами.
/// Здесь остаются конструкторы, пути и раскладка `init`/`clone`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:virtual_git/src/git_apply.dart';
import 'package:virtual_git/src/git_apply_whitespace.dart';
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
import 'package:virtual_git/src/git_pack_index.dart';
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

part 'git_repository_surface.dart';
part 'repository/apply.dart';
part 'repository/branch.dart';
part 'repository/config.dart';
part 'repository/history.dart';
part 'repository/index.dart';
part 'repository/merge.dart';
part 'repository/objects.dart';
part 'repository/references.dart';
part 'repository/stash.dart';
part 'repository/state.dart';
part 'repository/status.dart';
part 'repository/transfer.dart';
part 'repository/transport.dart';
part 'repository/tree.dart';

final class GitRepository {
  GitRepository._({
    required this.path,
    required this.gitDirectoryPath,
    required this.commonDirectoryPath,
    required this.bare,
    this.hashAlgorithm = GitHashAlgorithm.sha1,
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

  /// Алгоритм объектов репозитория. Меняется `init --object-format`.
  final GitHashAlgorithm hashAlgorithm;

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
    int? depth,
    String? filter,
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

    final normalizedRemoteName = GitRepositoryConfig._normalizeRemoteName(
      remoteName,
    );
    final remoteTransport = await GitRepositoryTransfer._openRemoteTransport(
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
        : GitRepositoryReferences._normalizeBranchReferenceName(branchName);
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
      depth: depth,
      filter: filter,
      commitCodec: commitCodec,
      treeCodec: treeCodec,
    );
    final branchShortName = GitRepositoryReferences._branchShortName(
      targetReferenceName,
    );
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
    String gitDirectoryPath, {
    GitHashAlgorithm hashAlgorithm = GitHashAlgorithm.sha1,
  }) async {
    final gitDirectory = Directory(gitDirectoryPath);
    await Directory(p.join(gitDirectory.path, 'objects'))
        .create(recursive: true);
    await Directory(p.join(gitDirectory.path, 'refs')).create(recursive: true);
    await Directory(p.join(gitDirectory.path, 'info')).create(recursive: true);
    await File(p.join(gitDirectory.path, 'HEAD'))
        .writeAsString('ref: refs/heads/main\n', flush: true);
    if (hashAlgorithm != GitHashAlgorithm.sha1) {
      await File(p.join(gitDirectory.path, 'object-format'))
          .writeAsString('${hashAlgorithm.wireName}\n', flush: true);
    }
  }

  /// Читает `.git/object-format`. Нет файла — SHA-1.
  static Future<GitHashAlgorithm> _objectFormatOf(
    String gitDirectoryPath,
  ) async {
    final file = File(p.join(gitDirectoryPath, 'object-format'));
    if (!await file.exists()) return GitHashAlgorithm.sha1;
    final text = (await file.readAsString()).trim();
    for (final algorithm in GitHashAlgorithm.values) {
      if (algorithm.wireName == text) return algorithm;
    }
    return GitHashAlgorithm.sha1;
  }

  static Future<GitRepository?> _discoverWorkTree(String workTreePath) async {
    final gitDirectory = Directory(p.join(workTreePath, '.git'));
    if (await gitDirectory.exists()) {
      final gitDirectoryPath = p.normalize(p.absolute(gitDirectory.path));
      final repository = GitRepository._(
        path: workTreePath,
        gitDirectoryPath: gitDirectoryPath,
        commonDirectoryPath: gitDirectoryPath,
        bare: false,
        hashAlgorithm: await _objectFormatOf(gitDirectoryPath),
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
          hashAlgorithm: await _objectFormatOf(resolvedCommonDirectoryPath),
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

    return directories.toList()
      ..sort(GitRepositoryStatus._comparePathDepthThenLexicographically);
  }
}

String _zeroObjectIdHex(GitHashAlgorithm algorithm) =>
    '0' * algorithm.hexLength;

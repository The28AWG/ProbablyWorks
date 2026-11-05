// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'package:virtual_git/src/git_object_id.dart';

enum GitWorktreeOperationKind {
  createDirectory,
  writeMetadataFile,
  writeWorkTreeFile,
  writeIndex,
  writeReference,
}

final class GitWorktreeOperation {
  const GitWorktreeOperation({required this.kind, required this.path});

  final GitWorktreeOperationKind kind;
  final String path;
}

final class GitWorktreeResult {
  GitWorktreeResult({
    required this.workTreePath,
    required this.gitDirectoryPath,
    required this.commonDirectoryPath,
    required this.objectId,
    required List<GitWorktreeOperation> operations,
    this.referenceName,
    this.detached = true,
    this.dryRun = false,
  }) : operations = List.unmodifiable(operations);

  final String workTreePath;
  final String gitDirectoryPath;
  final String commonDirectoryPath;
  final GitObjectId objectId;
  final List<GitWorktreeOperation> operations;
  final String? referenceName;
  final bool detached;
  final bool dryRun;
}

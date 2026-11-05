// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'package:virtual_git/src/git_branch_tracking.dart';
import 'package:virtual_git/src/git_object_id.dart';

enum GitPushReferenceStatus { updated, deleted, upToDate, rejected }

final class GitPushedReference {
  const GitPushedReference({
    required this.sourceReferenceName,
    required this.destinationReferenceName,
    required this.status,
    required this.objectId,
    this.previousObjectId,
    this.forced = false,
    this.objectsPushed = 0,
  });

  final String? sourceReferenceName;
  final String destinationReferenceName;
  final GitPushReferenceStatus status;
  final GitObjectId? objectId;
  final GitObjectId? previousObjectId;
  final bool forced;
  final int objectsPushed;
}

final class GitPushResult {
  GitPushResult({
    required this.remoteName,
    required this.remoteUrl,
    required List<GitPushedReference> references,
    this.tracking,
    this.dryRun = false,
  }) : references = List.unmodifiable(references);

  final String remoteName;
  final String remoteUrl;
  final List<GitPushedReference> references;
  final GitBranchTracking? tracking;
  final bool dryRun;

  int get objectsPushed =>
      references.fold(0, (total, reference) => total + reference.objectsPushed);
}

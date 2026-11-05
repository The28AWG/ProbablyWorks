// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'package:virtual_git/src/git_branch_tracking.dart';
import 'package:virtual_git/src/git_fetch.dart';
import 'package:virtual_git/src/git_merge.dart';
import 'package:virtual_git/src/git_object_id.dart';

enum GitPullStrategy { fastForward, merge }

enum GitPullStatus {
  updated,
  merged,
  conflict,
  upToDate,
  localAhead,
  divergent,
  rejected,
}

final class GitPullResult {
  const GitPullResult({
    required this.remoteName,
    required this.remoteUrl,
    required this.localReferenceName,
    required this.remoteReferenceName,
    required this.remoteTrackingReferenceName,
    required this.status,
    required this.targetObjectId,
    required this.fetchResult,
    this.strategy = GitPullStrategy.fastForward,
    this.currentObjectId,
    this.mergeResult,
    this.tracking,
    this.dryRun = false,
  });

  final String remoteName;
  final String remoteUrl;
  final String localReferenceName;
  final String remoteReferenceName;
  final String remoteTrackingReferenceName;
  final GitPullStatus status;
  final GitObjectId? currentObjectId;
  final GitObjectId targetObjectId;
  final GitFetchResult fetchResult;
  final GitPullStrategy strategy;
  final GitMergeResult? mergeResult;
  final GitBranchTracking? tracking;
  final bool dryRun;

  int get objectsFetched => fetchResult.objectsFetched;
}

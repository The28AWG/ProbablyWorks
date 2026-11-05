// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
final class GitBranchTracking {
  const GitBranchTracking({
    required this.branchName,
    required this.referenceName,
    required this.remoteName,
    required this.mergeReferenceName,
  });

  final String branchName;
  final String referenceName;
  final String remoteName;
  final String mergeReferenceName;
}

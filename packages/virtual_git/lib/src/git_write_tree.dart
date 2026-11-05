// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
final class GitWriteTreeConflict {
  const GitWriteTreeConflict({required this.path, required this.stages});

  final String path;
  final List<int> stages;
}

final class GitWriteTreeCheckResult {
  const GitWriteTreeCheckResult({this.conflicts = const []});

  final List<GitWriteTreeConflict> conflicts;

  bool get canWrite => conflicts.isEmpty;
}

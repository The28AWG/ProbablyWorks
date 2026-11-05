// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
final class GitRestoreResult {
  GitRestoreResult({
    required List<String> paths,
    this.source,
    this.staged = false,
    this.workTree = true,
  }) : paths = List.unmodifiable(paths);

  final List<String> paths;
  final String? source;
  final bool staged;
  final bool workTree;
}

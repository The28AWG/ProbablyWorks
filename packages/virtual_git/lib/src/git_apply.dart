// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
enum GitApplyStatus { applied, conflict, unsupported }

final class GitApplyConflict {
  const GitApplyConflict({
    required this.startLine,
    required this.lineCount,
    required this.baseText,
    required this.currentText,
    required this.incomingText,
  });

  final int startLine;
  final int lineCount;
  final String baseText;
  final String currentText;
  final String incomingText;
}

final class GitApplyFileResult {
  const GitApplyFileResult({
    required this.path,
    required this.status,
    this.message,
    this.mergedText,
    this.conflicts = const [],
  });

  final String path;
  final GitApplyStatus status;
  final String? message;
  final String? mergedText;
  final List<GitApplyConflict> conflicts;

  bool get applied => status == GitApplyStatus.applied;

  bool get conflict => status == GitApplyStatus.conflict;

  bool get unsupported => status == GitApplyStatus.unsupported;
}

final class GitApplyResult {
  const GitApplyResult({this.files = const [], this.check = false});

  final List<GitApplyFileResult> files;
  final bool check;

  bool get success => files.every((file) => file.applied);

  bool get hasConflicts => files.any((file) => file.conflict);

  bool get hasUnsupported => files.any((file) => file.unsupported);
}

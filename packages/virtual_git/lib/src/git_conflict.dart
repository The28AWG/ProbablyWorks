// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'package:virtual_git/src/git_object_id.dart';

final class GitConflictStageEntry {
  const GitConflictStageEntry({
    required this.stage,
    required this.objectId,
    required this.mode,
  });

  final int stage;
  final GitObjectId objectId;
  final int mode;
}

final class GitConflictEntry {
  const GitConflictEntry({
    required this.path,
    this.base,
    this.ours,
    this.theirs,
  });

  final String path;
  final GitConflictStageEntry? base;
  final GitConflictStageEntry? ours;
  final GitConflictStageEntry? theirs;
}

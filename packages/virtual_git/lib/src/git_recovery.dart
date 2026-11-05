// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'package:virtual_git/src/git_object_id.dart';

final class GitMergeAbortResult {
  const GitMergeAbortResult({
    required this.referenceName,
    required this.originalObjectId,
    required this.incomingObjectId,
    this.baseObjectId,
  });

  final String referenceName;
  final GitObjectId originalObjectId;
  final GitObjectId incomingObjectId;
  final GitObjectId? baseObjectId;
}

final class GitApplyAbortResult {
  const GitApplyAbortResult({
    required this.conflictPaths,
    this.indexRestored = false,
  });

  final List<String> conflictPaths;
  final bool indexRestored;
}

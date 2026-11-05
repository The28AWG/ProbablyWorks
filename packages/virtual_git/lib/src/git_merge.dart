// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'package:virtual_git/src/git_apply.dart';
import 'package:virtual_git/src/git_object_id.dart';

enum GitMergeStatus { alreadyUpToDate, fastForward, merged, conflict }

enum GitMergeFileStatus { merged, conflict, unsupported }

final class GitMergeFileResult {
  const GitMergeFileResult({
    required this.path,
    required this.status,
    this.message,
    this.mergedText,
    this.conflicts = const [],
  });

  final String path;
  final GitMergeFileStatus status;
  final String? message;
  final String? mergedText;
  final List<GitApplyConflict> conflicts;

  bool get merged => status == GitMergeFileStatus.merged;

  bool get conflict => status == GitMergeFileStatus.conflict;

  bool get unsupported => status == GitMergeFileStatus.unsupported;
}

final class GitMergeResult {
  const GitMergeResult({
    required this.status,
    required this.referenceName,
    required this.incomingObjectId,
    this.currentObjectId,
    this.baseObjectId,
    this.resultObjectId,
    this.files = const [],
  });

  final GitMergeStatus status;
  final String referenceName;
  final GitObjectId? currentObjectId;
  final GitObjectId incomingObjectId;
  final GitObjectId? baseObjectId;
  final GitObjectId? resultObjectId;
  final List<GitMergeFileResult> files;

  bool get hasConflicts => files.any((file) => file.conflict);

  bool get hasUnsupported => files.any((file) => file.unsupported);
}

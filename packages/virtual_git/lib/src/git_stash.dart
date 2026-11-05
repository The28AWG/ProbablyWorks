// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'package:virtual_git/src/git_apply.dart';
import 'package:virtual_git/src/git_commit.dart';
import 'package:virtual_git/src/git_object_id.dart';

final class GitStashEntry {
  const GitStashEntry({
    required this.revision,
    required this.referenceName,
    required this.stashObjectId,
    required this.baseObjectId,
    required this.indexObjectId,
    required this.actor,
    required this.message,
    required this.reflogMessage,
    this.untrackedObjectId,
  });

  final String revision;
  final String referenceName;
  final GitObjectId stashObjectId;
  final GitObjectId baseObjectId;
  final GitObjectId indexObjectId;
  final GitObjectId? untrackedObjectId;
  final GitCommitSignature actor;
  final String message;
  final String reflogMessage;

  bool get hasUntracked => untrackedObjectId != null;
}

final class GitStashResult {
  const GitStashResult({
    required this.referenceName,
    this.stashObjectId,
    this.baseObjectId,
    this.indexObjectId,
    this.untrackedObjectId,
    this.message,
    this.trackedPaths = const [],
    this.untrackedPaths = const [],
    this.includeUntracked = false,
    this.keepIndex = false,
    this.created = false,
  });

  final String referenceName;
  final GitObjectId? stashObjectId;
  final GitObjectId? baseObjectId;
  final GitObjectId? indexObjectId;
  final GitObjectId? untrackedObjectId;
  final String? message;
  final List<String> trackedPaths;
  final List<String> untrackedPaths;
  final bool includeUntracked;
  final bool keepIndex;
  final bool created;

  bool get hasUntracked => untrackedObjectId != null;
}

final class GitStashDropResult {
  const GitStashDropResult({
    required this.referenceName,
    required this.revision,
    required this.stashObjectId,
    required this.remainingCount,
    this.newTopObjectId,
  });

  final String referenceName;
  final String revision;
  final GitObjectId stashObjectId;
  final GitObjectId? newTopObjectId;
  final int remainingCount;
}

enum GitStashApplyStatus { applied, conflict, unsupported }

final class GitStashApplyResult {
  const GitStashApplyResult({
    required this.status,
    required this.referenceName,
    required this.stashObjectId,
    required this.baseObjectId,
    required this.indexObjectId,
    this.untrackedObjectId,
    this.applyResult = const GitApplyResult(),
    this.conflictingPaths = const [],
    this.restoredUntrackedPaths = const [],
    this.indexRestored = false,
  });

  final GitStashApplyStatus status;
  final String referenceName;
  final GitObjectId stashObjectId;
  final GitObjectId baseObjectId;
  final GitObjectId indexObjectId;
  final GitObjectId? untrackedObjectId;
  final GitApplyResult applyResult;
  final List<String> conflictingPaths;
  final List<String> restoredUntrackedPaths;
  final bool indexRestored;

  bool get applied => status == GitStashApplyStatus.applied;
}

enum GitStashPopStatus { applied, conflict, unsupported }

final class GitStashPopResult {
  const GitStashPopResult({
    required this.status,
    required this.referenceName,
    required this.revision,
    required this.stashObjectId,
    required this.applyResult,
    this.dropResult,
  });

  final GitStashPopStatus status;
  final String referenceName;
  final String revision;
  final GitObjectId stashObjectId;
  final GitStashApplyResult applyResult;
  final GitStashDropResult? dropResult;

  bool get applied => status == GitStashPopStatus.applied;
  bool get dropped => dropResult != null;
}

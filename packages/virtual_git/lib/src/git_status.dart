// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'package:virtual_git/src/git_conflict.dart';

enum GitFileStatus {
  unchanged,
  added,
  modified,
  deleted,
  conflicted,
  untracked,
  ignored,
}

final class GitStatusEntry {
  const GitStatusEntry({
    required this.path,
    this.indexStatus = GitFileStatus.unchanged,
    this.workTreeStatus = GitFileStatus.unchanged,
    this.conflict,
  });

  final String path;
  final GitFileStatus indexStatus;
  final GitFileStatus workTreeStatus;
  final GitConflictEntry? conflict;

  bool get isIgnored => workTreeStatus == GitFileStatus.ignored;

  bool get isConflicted => indexStatus == GitFileStatus.conflicted;

  bool get isStaged =>
      indexStatus != GitFileStatus.unchanged &&
      indexStatus != GitFileStatus.ignored;

  bool get isUnstaged =>
      isConflicted || (workTreeStatus != GitFileStatus.unchanged && !isIgnored);

  bool get isUntracked => workTreeStatus == GitFileStatus.untracked;
}

final class GitStatus {
  const GitStatus({this.entries = const []});

  final List<GitStatusEntry> entries;

  bool get isClean => entries.every(
    (entry) =>
        entry.indexStatus == GitFileStatus.unchanged &&
        (entry.workTreeStatus == GitFileStatus.unchanged || entry.isIgnored),
  );

  bool get hasStagedChanges => entries.any((entry) => entry.isStaged);

  bool get hasUnstagedChanges => entries.any((entry) => entry.isUnstaged);

  Iterable<GitStatusEntry> get staged =>
      entries.where((entry) => entry.isStaged);

  Iterable<GitStatusEntry> get unstaged =>
      entries.where((entry) => entry.isUnstaged);
}

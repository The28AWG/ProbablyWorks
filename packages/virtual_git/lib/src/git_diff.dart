// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'package:virtual_git/src/git_conflict.dart';
import 'package:virtual_git/src/git_object_id.dart';

enum GitDiffChangeType { added, modified, deleted }

enum GitDiffLineType { context, addition, deletion }

final class GitDiffLine {
  const GitDiffLine({required this.type, required this.text});

  final GitDiffLineType type;
  final String text;
}

final class GitDiffHunk {
  const GitDiffHunk({
    required this.oldStart,
    required this.oldLineCount,
    required this.newStart,
    required this.newLineCount,
    required this.lines,
  });

  final int oldStart;
  final int oldLineCount;
  final int newStart;
  final int newLineCount;
  final List<GitDiffLine> lines;
}

final class GitDiffEntry {
  const GitDiffEntry({
    required this.path,
    required this.changeType,
    this.oldMode,
    this.newMode,
    this.oldObjectId,
    this.newObjectId,
    this.oldBytes,
    this.newBytes,
    this.binary = false,
    this.hunks = const [],
    this.conflict,
  });

  final String path;
  final GitDiffChangeType changeType;
  final String? oldMode;
  final String? newMode;
  final GitObjectId? oldObjectId;
  final GitObjectId? newObjectId;
  final List<int>? oldBytes;
  final List<int>? newBytes;
  final bool binary;
  final List<GitDiffHunk> hunks;
  final GitConflictEntry? conflict;

  bool get conflicted => conflict != null;
}

// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'package:virtual_git/src/git_object_id.dart';

final class GitCommitSignature {
  const GitCommitSignature({
    required this.name,
    required this.email,
    required this.timestampSeconds,
    required this.timezoneOffset,
  });

  factory GitCommitSignature.fromDateTime({
    required String name,
    required String email,
    required DateTime timestamp,
  }) {
    final localTimestamp = timestamp.toLocal();
    return GitCommitSignature(
      name: name,
      email: email,
      timestampSeconds: localTimestamp.millisecondsSinceEpoch ~/ 1000,
      timezoneOffset: _formatTimezoneOffset(localTimestamp.timeZoneOffset),
    );
  }

  final String name;
  final String email;
  final int timestampSeconds;
  final String timezoneOffset;

  GitCommitSignature copyWith({
    String? name,
    String? email,
    int? timestampSeconds,
    String? timezoneOffset,
    DateTime? timestamp,
  }) {
    if (timestamp != null &&
        (timestampSeconds != null || timezoneOffset != null)) {
      throw ArgumentError(
        'timestamp cannot be combined with timestampSeconds or timezoneOffset.',
      );
    }
    if (timestamp != null) {
      final localTimestamp = timestamp.toLocal();
      return GitCommitSignature(
        name: name ?? this.name,
        email: email ?? this.email,
        timestampSeconds: localTimestamp.millisecondsSinceEpoch ~/ 1000,
        timezoneOffset: _formatTimezoneOffset(localTimestamp.timeZoneOffset),
      );
    }
    return GitCommitSignature(
      name: name ?? this.name,
      email: email ?? this.email,
      timestampSeconds: timestampSeconds ?? this.timestampSeconds,
      timezoneOffset: timezoneOffset ?? this.timezoneOffset,
    );
  }

  static String _formatTimezoneOffset(Duration offset) {
    final sign = offset.isNegative ? '-' : '+';
    final absoluteOffset = offset.abs();
    final hours = absoluteOffset.inHours.toString().padLeft(2, '0');
    final minutes = (absoluteOffset.inMinutes % 60).toString().padLeft(2, '0');
    return '$sign$hours$minutes';
  }
}

final class GitCommitHeader {
  const GitCommitHeader(this.name, this.value);

  final String name;
  final String value;
}

final class GitCommit {
  const GitCommit({
    required this.tree,
    this.parents = const [],
    required this.author,
    required this.committer,
    required this.message,
    this.extraHeaders = const [],
  });

  final GitObjectId tree;
  final List<GitObjectId> parents;
  final GitCommitSignature author;
  final GitCommitSignature committer;
  final String message;
  final List<GitCommitHeader> extraHeaders;
}

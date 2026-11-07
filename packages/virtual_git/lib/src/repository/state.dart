// ignore_for_file: cascade_invocations
// ignore_for_file: avoid-substring
// Причина: разбор hex и каскады оставлены как в git_core.
part of '../git_repository.dart';

/// Снимки деревьев, состояние merge/apply/stash и разбор `.git/config`.
final class _GitTreeSnapshotEntry {
  const _GitTreeSnapshotEntry({required this.objectId, required this.mode});

  final GitObjectId objectId;
  final String mode;
}

final class _GitWorkTreeSnapshotEntry {
  const _GitWorkTreeSnapshotEntry({
    required this.objectId,
    required this.mode,
    required this.bytes,
  });

  final GitObjectId objectId;
  final String mode;
  final List<int> bytes;
}

final class _GitDiffOperation {
  const _GitDiffOperation({
    required this.type,
    required this.text,
    required this.oldLineNumber,
    required this.newLineNumber,
  });

  final GitDiffLineType type;
  final String text;
  final int oldLineNumber;
  final int newLineNumber;
}

final class _GitApplyPlan {
  const _GitApplyPlan({required this.result, this.writePlan});

  final GitApplyFileResult result;
  final _GitApplyWritePlan? writePlan;
}

final class _GitApplyWritePlan {
  const _GitApplyWritePlan({
    required this.path,
    required this.mode,
    required this.delete,
    this.bytes,
  });

  final String path;
  final String? mode;
  final bool delete;
  final List<int>? bytes;
}

final class _GitThreeWayMergeResult {
  const _GitThreeWayMergeResult({
    required this.mergedText,
    required this.conflicts,
  });

  final String mergedText;
  final List<GitApplyConflict> conflicts;
}

final class _GitTextChange {
  const _GitTextChange({
    required this.baseStart,
    required this.baseEnd,
    required this.replacement,
  });

  final int baseStart;
  final int baseEnd;
  final List<String> replacement;
}

final class _GitIgnoreRule {
  const _GitIgnoreRule({
    required this.pattern,
    required this.source,
    required this.sourceDirectory,
    required this.lineNumber,
    required this.negated,
    required this.directoryOnly,
    required this.basenameOnly,
    required this.matcher,
  });

  final String pattern;
  final String source;
  final String sourceDirectory;
  final int lineNumber;
  final bool negated;
  final bool directoryOnly;
  final bool basenameOnly;
  final Pattern matcher;
}

final class _GitIgnoreSubject {
  const _GitIgnoreSubject({required this.path, required this.isDirectory});

  final String path;
  final bool isDirectory;
}

final class _GitConfigDocument {
  const _GitConfigDocument({required this.preamble, required this.sections});

  final List<String> preamble;
  final List<_GitConfigSection> sections;
}

final class _GitConfigSection {
  const _GitConfigSection({
    required this.headerLine,
    required this.name,
    required this.subsection,
    required this.bodyLines,
  });

  final String headerLine;
  final String name;
  final String? subsection;
  final List<String> bodyLines;

  _GitConfigSection copyWith({
    String? headerLine,
    String? name,
    String? subsection,
    List<String>? bodyLines,
  }) => _GitConfigSection(
    headerLine: headerLine ?? this.headerLine,
    name: name ?? this.name,
    subsection: subsection ?? this.subsection,
    bodyLines: bodyLines ?? this.bodyLines,
  );
}

final class _GitStashStackEntry {
  const _GitStashStackEntry({
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
}

final class _GitMergeOperationState {
  const _GitMergeOperationState({
    required this.referenceName,
    required this.currentObjectId,
    required this.incomingObjectId,
    required this.message,
    this.baseObjectId,
    this.originalIndexBytes,
  });

  factory _GitMergeOperationState.fromJson(Map<String, dynamic> json) {
    final originalIndexBytesText = json['originalIndexBytes'] as String?;
    return _GitMergeOperationState(
      referenceName: json['referenceName'] as String,
      currentObjectId: GitObjectId.fromHex(json['currentObjectId'] as String),
      incomingObjectId: GitObjectId.fromHex(json['incomingObjectId'] as String),
      baseObjectId: json['baseObjectId'] == null
          ? null
          : GitObjectId.fromHex(json['baseObjectId'] as String),
      message: json['message'] as String,
      originalIndexBytes: originalIndexBytesText == null
          ? null
          : base64.decode(originalIndexBytesText),
    );
  }

  final String referenceName;
  final GitObjectId currentObjectId;
  final GitObjectId incomingObjectId;
  final GitObjectId? baseObjectId;
  final String message;
  final List<int>? originalIndexBytes;

  Map<String, Object?> toJson() => {
    'referenceName': referenceName,
    'currentObjectId': currentObjectId.hex,
    'incomingObjectId': incomingObjectId.hex,
    'baseObjectId': baseObjectId?.hex,
    'message': message,
    'originalIndexBytes': originalIndexBytes == null
        ? null
        : base64.encode(originalIndexBytes!),
  };
}

final class _GitApplyOperationState {
  const _GitApplyOperationState({
    required this.conflictPaths,
    this.originalIndexBytes,
  });

  factory _GitApplyOperationState.fromJson(Map<String, dynamic> json) {
    final originalIndexBytesText = json['originalIndexBytes'] as String?;
    return _GitApplyOperationState(
      conflictPaths: [
        for (final path in json['conflictPaths'] as List<dynamic>)
          path as String,
      ],
      originalIndexBytes: originalIndexBytesText == null
          ? null
          : base64.decode(originalIndexBytesText),
    );
  }

  final List<String> conflictPaths;
  final List<int>? originalIndexBytes;

  Map<String, Object?> toJson() => {
    'conflictPaths': conflictPaths,
    'originalIndexBytes': originalIndexBytes == null
        ? null
        : base64.encode(originalIndexBytes!),
  };
}

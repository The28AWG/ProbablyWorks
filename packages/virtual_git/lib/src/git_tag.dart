// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'package:virtual_git/src/git_commit.dart';
import 'package:virtual_git/src/git_object_id.dart';
import 'package:virtual_git/src/git_object_type.dart';

final class GitTagObject {
  const GitTagObject({
    required this.targetObjectId,
    required this.targetType,
    required this.name,
    required this.tagger,
    required this.message,
  });

  final GitObjectId targetObjectId;
  final GitObjectType targetType;
  final String name;
  final GitCommitSignature tagger;
  final String message;
}

final class GitTag {
  const GitTag({
    required this.name,
    required this.referenceName,
    required this.objectId,
    required this.targetObjectId,
    required this.targetType,
    this.tagger,
    this.message,
    this.annotated = false,
  });

  final String name;
  final String referenceName;
  final GitObjectId objectId;
  final GitObjectId targetObjectId;
  final GitObjectType targetType;
  final GitCommitSignature? tagger;
  final String? message;
  final bool annotated;
}

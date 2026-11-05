// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'package:virtual_git/src/git_commit.dart';
import 'package:virtual_git/src/git_object_id.dart';

final class GitReflogEntry {
  const GitReflogEntry({
    required this.actor,
    this.previousObjectId,
    this.newObjectId,
    this.message = '',
  });

  final GitObjectId? previousObjectId;
  final GitObjectId? newObjectId;
  final GitCommitSignature actor;
  final String message;
}

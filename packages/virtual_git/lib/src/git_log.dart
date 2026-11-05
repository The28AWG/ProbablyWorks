// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'package:virtual_git/src/git_commit.dart';
import 'package:virtual_git/src/git_object_id.dart';

final class GitLogEntry {
  const GitLogEntry({required this.objectId, required this.commit});

  final GitObjectId objectId;
  final GitCommit commit;
}

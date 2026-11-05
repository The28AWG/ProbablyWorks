// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'package:virtual_git/src/git_object_id.dart';

final class GitLsFilesEntry {
  const GitLsFilesEntry.tracked({
    required this.path,
    required this.objectId,
    required this.mode,
    this.stage = 0,
  }) : untracked = false,
       ignored = false;

  const GitLsFilesEntry.untracked(this.path)
    : objectId = null,
      mode = null,
      stage = 0,
      untracked = true,
      ignored = false;

  const GitLsFilesEntry.ignored(this.path)
    : objectId = null,
      mode = null,
      stage = 0,
      untracked = false,
      ignored = true;

  final String path;
  final GitObjectId? objectId;
  final int? mode;
  final int stage;
  final bool untracked;
  final bool ignored;

  bool get tracked => !untracked && !ignored;
}

// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'package:virtual_git/src/git_object_id.dart';

enum GitResetMode { soft, mixed, hard }

final class GitResetResult {
  const GitResetResult({
    required this.objectId,
    required this.referenceName,
    required this.mode,
  });

  final GitObjectId objectId;
  final String referenceName;
  final GitResetMode mode;
}

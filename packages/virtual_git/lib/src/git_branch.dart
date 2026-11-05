// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'package:virtual_git/src/git_object_id.dart';

final class GitBranch {
  const GitBranch({
    required this.name,
    required this.referenceName,
    required this.objectId,
    this.current = false,
  });

  final String name;
  final String referenceName;
  final GitObjectId objectId;
  final bool current;
}

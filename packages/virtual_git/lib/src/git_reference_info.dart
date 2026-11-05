// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'package:virtual_git/src/git_object_id.dart';

final class GitReferenceInfo {
  const GitReferenceInfo({
    required this.referenceName,
    required this.name,
    required this.objectId,
    this.peeledObjectId,
  });

  final String referenceName;
  final String name;
  final GitObjectId objectId;
  final GitObjectId? peeledObjectId;
}

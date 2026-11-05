// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'package:virtual_git/src/git_object_id.dart';

final class GitCheckoutResult {
  const GitCheckoutResult({
    required this.objectId,
    this.referenceName,
    this.detached = false,
  });

  final GitObjectId objectId;
  final String? referenceName;
  final bool detached;
}

// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'package:virtual_git/src/git_object_id.dart';

enum GitFetchReferenceStatus { updated, upToDate, rejected }

final class GitFetchedReference {
  const GitFetchedReference({
    required this.sourceReferenceName,
    required this.destinationReferenceName,
    required this.status,
    required this.objectId,
    this.previousObjectId,
    this.forced = false,
    this.objectsFetched = 0,
  });

  final String sourceReferenceName;
  final String destinationReferenceName;
  final GitFetchReferenceStatus status;
  final GitObjectId objectId;
  final GitObjectId? previousObjectId;
  final bool forced;
  final int objectsFetched;
}

final class GitFetchResult {
  GitFetchResult({
    required this.remoteName,
    required this.remoteUrl,
    required List<GitFetchedReference> references,
    this.dryRun = false,
  }) : references = List.unmodifiable(references);

  final String remoteName;
  final String remoteUrl;
  final List<GitFetchedReference> references;
  final bool dryRun;

  int get objectsFetched => references.fold(
    0,
    (total, reference) => total + reference.objectsFetched,
  );
}

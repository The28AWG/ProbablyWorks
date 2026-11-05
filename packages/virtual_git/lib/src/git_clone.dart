// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'package:virtual_git/src/git_fetch.dart';
import 'package:virtual_git/src/git_object_id.dart';

final class GitCloneResult {
  const GitCloneResult({
    required this.path,
    required this.gitDirectoryPath,
    required this.remoteName,
    required this.remoteUrl,
    required this.referenceName,
    required this.objectId,
    required this.fetchResult,
  });

  final String path;
  final String gitDirectoryPath;
  final String remoteName;
  final String remoteUrl;
  final String referenceName;
  final GitObjectId objectId;
  final GitFetchResult fetchResult;

  int get objectsFetched => fetchResult.objectsFetched;
}

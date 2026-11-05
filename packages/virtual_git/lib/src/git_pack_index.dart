// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'package:virtual_git/src/git_hash_algorithm.dart';
import 'package:virtual_git/src/git_object_id.dart';

final class GitPackIndexEntry {
  const GitPackIndexEntry({
    required this.objectId,
    required this.offset,
    required this.crc32,
  });

  final GitObjectId objectId;
  final int offset;
  final int crc32;
}

final class GitPackIndex {
  const GitPackIndex({
    this.version = 2,
    this.checksumAlgorithm = GitHashAlgorithm.sha1,
    this.entries = const [],
    this.packChecksum,
    this.checksum,
  });

  final int version;
  final GitHashAlgorithm checksumAlgorithm;
  final List<GitPackIndexEntry> entries;
  final GitObjectId? packChecksum;
  final GitObjectId? checksum;

  int get objectCount => entries.length;

  GitPackIndexEntry? entryForObjectId(GitObjectId objectId) {
    var lower = 0;
    var upper = entries.length - 1;

    while (lower <= upper) {
      final middle = lower + ((upper - lower) ~/ 2);
      final comparison = entries[middle].objectId.hex.compareTo(objectId.hex);

      if (comparison == 0) {
        return entries[middle];
      }
      if (comparison < 0) {
        lower = middle + 1;
      } else {
        upper = middle - 1;
      }
    }

    return null;
  }
}

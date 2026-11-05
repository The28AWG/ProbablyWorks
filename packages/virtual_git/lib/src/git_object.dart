// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'dart:typed_data';

import 'package:virtual_git/src/git_hash_algorithm.dart';
import 'package:virtual_git/src/git_loose_object_codec.dart';
import 'package:virtual_git/src/git_object_id.dart';
import 'package:virtual_git/src/git_object_type.dart';

final class GitObject {
  GitObject(this.type, List<int> bytes) : bytes = Uint8List.fromList(bytes);

  factory GitObject.blob(List<int> bytes) =>
      GitObject(GitObjectType.blob, bytes);

  factory GitObject.tree(List<int> bytes) =>
      GitObject(GitObjectType.tree, bytes);

  factory GitObject.commit(List<int> bytes) =>
      GitObject(GitObjectType.commit, bytes);

  factory GitObject.tag(List<int> bytes) => GitObject(GitObjectType.tag, bytes);

  final GitObjectType type;
  final Uint8List bytes;

  int get size => bytes.lengthInBytes;

  GitObjectId id({GitHashAlgorithm algorithm = GitHashAlgorithm.sha1}) =>
      GitObjectId.compute(
        const GitLooseObjectCodec().encode(this),
        algorithm: algorithm,
      );
}

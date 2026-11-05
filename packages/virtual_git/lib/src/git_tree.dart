// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'dart:convert';
import 'dart:typed_data';

import 'package:virtual_git/src/git_object_id.dart';

final class GitTreeEntry {
  GitTreeEntry({
    required this.mode,
    required List<int> nameBytes,
    required this.objectId,
  }) : nameBytes = Uint8List.fromList(nameBytes) {
    if (mode.trim().isEmpty) {
      throw ArgumentError.value(
        mode,
        'mode',
        'Tree entry mode must not be empty.',
      );
    }
    if (this.nameBytes.isEmpty) {
      throw ArgumentError.value(
        nameBytes,
        'nameBytes',
        'Tree entry name must not be empty.',
      );
    }
    if (this.nameBytes.contains(0)) {
      throw ArgumentError.value(
        nameBytes,
        'nameBytes',
        'Tree entry name must not contain NUL bytes.',
      );
    }
  }

  factory GitTreeEntry.utf8({
    required String mode,
    required String name,
    required GitObjectId objectId,
  }) => GitTreeEntry(
    mode: mode,
    nameBytes: utf8.encode(name),
    objectId: objectId,
  );

  final String mode;
  final Uint8List nameBytes;
  final GitObjectId objectId;

  String get utf8Name => utf8.decode(nameBytes);
}

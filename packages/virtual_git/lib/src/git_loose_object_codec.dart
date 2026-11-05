// ignore_for_file: cascade_invocations
// ignore_for_file: avoid-substring
// Причина: разбор hex и каскады оставлены как в git_core.
// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'dart:convert';
import 'dart:typed_data';

import 'package:virtual_git/src/git_object.dart';
import 'package:virtual_git/src/git_object_type.dart';

final class GitLooseObjectCodec {
  const GitLooseObjectCodec();

  Uint8List encode(GitObject object) {
    final header = ascii.encode('${object.type.headerName} ${object.size}\x00');
    return Uint8List.fromList([...header, ...object.bytes]);
  }

  GitObject decode(List<int> bytes) {
    final headerTerminatorIndex = bytes.indexOf(0);
    if (headerTerminatorIndex == -1) {
      throw const FormatException(
        'Loose object is missing the NUL terminator after the header.',
      );
    }

    final header = ascii.decode(bytes.sublist(0, headerTerminatorIndex));
    final separatorIndex = header.indexOf(' ');
    if (separatorIndex == -1) {
      throw FormatException(
        'Loose object header is missing the size field.',
        header,
      );
    }

    final typeName = header.substring(0, separatorIndex);
    final sizeText = header.substring(separatorIndex + 1);
    final expectedSize = int.tryParse(sizeText);
    if (expectedSize == null || expectedSize < 0) {
      throw FormatException('Loose object size is invalid.', sizeText);
    }

    final payload = bytes.sublist(headerTerminatorIndex + 1);
    if (payload.length != expectedSize) {
      throw FormatException(
        'Loose object payload size does not match the header.',
        payload.length,
      );
    }

    return GitObject(GitObjectType.parse(typeName), payload);
  }
}

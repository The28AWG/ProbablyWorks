// ignore_for_file: cascade_invocations
// ignore_for_file: avoid-substring
// Причина: разбор hex и каскады оставлены как в git_core.
// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'dart:convert';
import 'dart:typed_data';

import 'package:virtual_git/src/git_commit.dart';
import 'package:virtual_git/src/git_object_id.dart';
import 'package:virtual_git/src/git_object_type.dart';
import 'package:virtual_git/src/git_tag.dart';

final class GitTagCodec {
  const GitTagCodec();

  Uint8List encode(GitTagObject tag) {
    final lines = <String>[
      'object ${tag.targetObjectId.hex}',
      'type ${tag.targetType.headerName}',
      'tag ${tag.name}',
      'tagger ${_formatSignature(tag.tagger)}',
      '',
      tag.message,
    ];
    return Uint8List.fromList(utf8.encode(lines.join('\n')));
  }

  GitTagObject decode(List<int> bytes) {
    final text = utf8.decode(bytes);
    final separator = text.indexOf('\n\n');
    final headerText = separator == -1 ? text : text.substring(0, separator);
    final message = separator == -1 ? '' : text.substring(separator + 2);

    GitObjectId? targetObjectId;
    GitObjectType? targetType;
    String? name;
    GitCommitSignature? tagger;

    for (final line in const LineSplitter().convert(headerText)) {
      final separatorIndex = line.indexOf(' ');
      if (separatorIndex == -1) {
        throw FormatException('Tag header is malformed.', line);
      }

      final headerName = line.substring(0, separatorIndex);
      final value = line.substring(separatorIndex + 1);
      switch (headerName) {
        case 'object':
          targetObjectId = GitObjectId.fromHex(value);
        case 'type':
          targetType = GitObjectType.parse(value);
        case 'tag':
          name = value;
        case 'tagger':
          tagger = _parseSignature(value);
      }
    }

    if (targetObjectId == null) {
      throw const FormatException('Tag object is missing the object header.');
    }
    if (targetType == null) {
      throw const FormatException('Tag object is missing the type header.');
    }
    if (name == null) {
      throw const FormatException('Tag object is missing the tag header.');
    }
    if (tagger == null) {
      throw const FormatException('Tag object is missing the tagger header.');
    }

    return GitTagObject(
      targetObjectId: targetObjectId,
      targetType: targetType,
      name: name,
      tagger: tagger,
      message: message,
    );
  }

  GitCommitSignature _parseSignature(String value) {
    final match = RegExp(r'^(.*) <([^<>]+)> (\d+) ([+-]\d{4})$')
        .firstMatch(value);
    if (match == null) {
      throw FormatException('Tag signature is malformed.', value);
    }

    return GitCommitSignature(
      name: match.group(1)!,
      email: match.group(2)!,
      timestampSeconds: int.parse(match.group(3)!),
      timezoneOffset: match.group(4)!,
    );
  }

  String _formatSignature(GitCommitSignature signature) =>
      '${signature.name} <${signature.email}> '
      '${signature.timestampSeconds} ${signature.timezoneOffset}';
}

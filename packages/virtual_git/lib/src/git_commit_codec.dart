// ignore_for_file: cascade_invocations
// ignore_for_file: avoid-substring
// Причина: разбор hex и каскады оставлены как в git_core.
// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'dart:convert';
import 'dart:typed_data';

import 'package:virtual_git/src/git_commit.dart';
import 'package:virtual_git/src/git_object_id.dart';

final class GitCommitCodec {
  const GitCommitCodec();

  Uint8List encode(GitCommit commit) {
    final lines = <String>[
      'tree ${commit.tree.hex}',
      ...commit.parents.map((parent) => 'parent ${parent.hex}'),
      'author ${_formatSignature(commit.author)}',
      'committer ${_formatSignature(commit.committer)}',
      ...commit.extraHeaders.expand(
        (header) => _formatHeaderLines(header.name, header.value),
      ),
      '',
      commit.message,
    ];
    return Uint8List.fromList(utf8.encode(lines.join('\n')));
  }

  GitCommit decode(List<int> bytes) {
    final text = utf8.decode(bytes);
    final separator = text.indexOf('\n\n');
    final headerText = separator == -1 ? text : text.substring(0, separator);
    final message = separator == -1 ? '' : text.substring(separator + 2);

    final rawHeaders = _parseHeaders(headerText);
    GitObjectId? tree;
    final parents = <GitObjectId>[];
    GitCommitSignature? author;
    GitCommitSignature? committer;
    final extraHeaders = <GitCommitHeader>[];

    for (final header in rawHeaders) {
      switch (header.name) {
        case 'tree':
          tree = GitObjectId.fromHex(header.value);
        case 'parent':
          parents.add(GitObjectId.fromHex(header.value));
        case 'author':
          author = _parseSignature(header.value);
        case 'committer':
          committer = _parseSignature(header.value);
        default:
          extraHeaders.add(header);
      }
    }

    if (tree == null) {
      throw const FormatException('Commit object is missing the tree header.');
    }
    if (author == null) {
      throw const FormatException(
        'Commit object is missing the author header.',
      );
    }
    if (committer == null) {
      throw const FormatException(
        'Commit object is missing the committer header.',
      );
    }

    return GitCommit(
      tree: tree,
      parents: parents,
      author: author,
      committer: committer,
      message: message,
      extraHeaders: extraHeaders,
    );
  }

  List<GitCommitHeader> _parseHeaders(String headerText) {
    if (headerText.isEmpty) {
      return const [];
    }

    final headers = <GitCommitHeader>[];
    GitCommitHeader? currentHeader;

    for (final line in const LineSplitter().convert(headerText)) {
      if (line.startsWith(' ')) {
        if (currentHeader == null) {
          throw const FormatException(
            'Commit header continuation without a header.',
          );
        }
        currentHeader = GitCommitHeader(
          currentHeader.name,
          '${currentHeader.value}\n${line.substring(1)}',
        );
        headers[headers.length - 1] = currentHeader;
        continue;
      }

      final separatorIndex = line.indexOf(' ');
      if (separatorIndex == -1) {
        throw FormatException('Commit header is malformed.', line);
      }

      currentHeader = GitCommitHeader(
        line.substring(0, separatorIndex),
        line.substring(separatorIndex + 1),
      );
      headers.add(currentHeader);
    }

    return headers;
  }

  GitCommitSignature _parseSignature(String value) {
    final match = RegExp(r'^(.*) <([^<>]+)> (\d+) ([+-]\d{4})$')
        .firstMatch(value);
    if (match == null) {
      throw FormatException('Commit signature is malformed.', value);
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

  Iterable<String> _formatHeaderLines(String name, String value) sync* {
    final lines = value.split('\n');
    yield '$name ${lines.first}';
    for (final line in lines.skip(1)) {
      yield ' $line';
    }
  }
}

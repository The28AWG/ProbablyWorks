// ignore_for_file: cascade_invocations
// ignore_for_file: avoid-substring
// Причина: разбор hex и каскады оставлены как в git_core.
// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'package:virtual_git/src/git_commit.dart';
import 'package:virtual_git/src/git_hash_algorithm.dart';
import 'package:virtual_git/src/git_object_id.dart';
import 'package:virtual_git/src/git_reflog.dart';

final class GitReflogCodec {
  const GitReflogCodec({this.defaultAlgorithm = GitHashAlgorithm.sha1});

  final GitHashAlgorithm defaultAlgorithm;

  List<GitReflogEntry> decode(String contents) {
    final lines = contents.split('\n').where((line) => line.trim().isNotEmpty);
    return [for (final line in lines) decodeLine(line)];
  }

  GitReflogEntry decodeLine(String line) {
    final tabIndex = line.indexOf('\t');
    final metadata = tabIndex == -1 ? line : line.substring(0, tabIndex);
    final message = tabIndex == -1 ? '' : line.substring(tabIndex + 1);
    final match = RegExp(
      r'^([0-9a-f]+) ([0-9a-f]+) (.+) <([^>]+)> (\d+) ([+-]\d{4})$',
    ).firstMatch(metadata);
    if (match == null) {
      throw FormatException('Invalid reflog entry: $line');
    }

    return GitReflogEntry(
      previousObjectId: _parseNullableObjectId(match.group(1)!),
      newObjectId: _parseNullableObjectId(match.group(2)!),
      actor: GitCommitSignature(
        name: match.group(3)!,
        email: match.group(4)!,
        timestampSeconds: int.parse(match.group(5)!),
        timezoneOffset: match.group(6)!,
      ),
      message: message,
    );
  }

  String encode(List<GitReflogEntry> entries) => entries.map(encodeLine).join();

  String encodeLine(GitReflogEntry entry) {
    final algorithm =
        entry.previousObjectId?.algorithm ??
        entry.newObjectId?.algorithm ??
        defaultAlgorithm;
    final zeroHex = '0' * algorithm.hexLength;
    final previousHex = entry.previousObjectId?.hex ?? zeroHex;
    final newHex = entry.newObjectId?.hex ?? zeroHex;
    final actor = entry.actor;
    return '$previousHex $newHex ${actor.name} <${actor.email}> '
        '${actor.timestampSeconds} ${actor.timezoneOffset}\t'
        '${entry.message}\n';
  }

  GitObjectId? _parseNullableObjectId(String value) {
    if (value.runes.every((codeUnit) => codeUnit == 0x30)) {
      return null;
    }
    return GitObjectId.fromHex(value);
  }
}

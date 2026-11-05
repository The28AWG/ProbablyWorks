// ignore_for_file: cascade_invocations
// ignore_for_file: avoid-substring
// Причина: разбор hex и каскады оставлены как в git_core.
// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
import 'package:virtual_git/src/git_diff.dart';
import 'package:virtual_git/src/git_object_id.dart';

final class GitDiffCodec {
  const GitDiffCodec();

  String encode(Iterable<GitDiffEntry> entries) {
    final buffer = StringBuffer();
    for (final entry in entries) {
      final oldPathSpec = entry.changeType == GitDiffChangeType.added
          ? '/dev/null'
          : 'a/${entry.path}';
      final newPathSpec = entry.changeType == GitDiffChangeType.deleted
          ? '/dev/null'
          : 'b/${entry.path}';

      buffer.writeln('diff --git a/${entry.path} b/${entry.path}');
      switch (entry.changeType) {
        case GitDiffChangeType.added:
          if (entry.newMode != null) {
            buffer.writeln('new file mode ${entry.newMode}');
          }
        case GitDiffChangeType.deleted:
          if (entry.oldMode != null) {
            buffer.writeln('deleted file mode ${entry.oldMode}');
          }
        case GitDiffChangeType.modified:
          if (entry.oldMode != null &&
              entry.newMode != null &&
              entry.oldMode != entry.newMode) {
            buffer.writeln('old mode ${entry.oldMode}');
            buffer.writeln('new mode ${entry.newMode}');
          }
      }

      if (entry.oldObjectId != null || entry.newObjectId != null) {
        final oldHex = entry.oldObjectId?.hex ?? _zeroHexForEntry(entry);
        final newHex = entry.newObjectId?.hex ?? _zeroHexForEntry(entry);
        final modeSuffix =
            entry.oldMode == entry.newMode && entry.newMode != null
            ? ' ${entry.newMode}'
            : '';
        buffer.writeln('index $oldHex..$newHex$modeSuffix');
      }

      buffer.writeln('--- $oldPathSpec');
      buffer.writeln('+++ $newPathSpec');
      if (entry.binary) {
        buffer.writeln('Binary files $oldPathSpec and $newPathSpec differ');
        continue;
      }

      for (final hunk in entry.hunks) {
        buffer.writeln(
          '@@ -${_formatRange(hunk.oldStart, hunk.oldLineCount)} '
          '+${_formatRange(hunk.newStart, hunk.newLineCount)} @@',
        );
        for (final line in hunk.lines) {
          _writeDiffLine(buffer, line);
        }
      }
    }

    return buffer.toString();
  }

  List<GitDiffEntry> decode(String patchText) {
    if (patchText.isEmpty) {
      return const <GitDiffEntry>[];
    }

    final lines = _splitPatchLines(patchText);
    final entries = <GitDiffEntry>[];
    _GitDiffEntryBuilder? currentEntry;
    var index = 0;

    while (index < lines.length) {
      final rawLine = lines[index];
      final line = _stripTrailingLineEnding(rawLine);
      if (line.isEmpty) {
        index++;
        continue;
      }

      if (line.startsWith('diff --git ')) {
        if (currentEntry != null) {
          entries.add(currentEntry.build());
        }
        currentEntry = _GitDiffEntryBuilder.fromDiffGitHeader(line);
        index++;
        continue;
      }

      if (currentEntry == null) {
        throw FormatException(
          'Expected a diff header before patch content.',
          patchText,
        );
      }

      if (line.startsWith('new file mode ')) {
        currentEntry.changeType = GitDiffChangeType.added;
        currentEntry.newMode = line.substring('new file mode '.length);
        index++;
        continue;
      }
      if (line.startsWith('deleted file mode ')) {
        currentEntry.changeType = GitDiffChangeType.deleted;
        currentEntry.oldMode = line.substring('deleted file mode '.length);
        index++;
        continue;
      }
      if (line.startsWith('old mode ')) {
        currentEntry.oldMode = line.substring('old mode '.length);
        index++;
        continue;
      }
      if (line.startsWith('new mode ')) {
        currentEntry.newMode = line.substring('new mode '.length);
        index++;
        continue;
      }
      if (line.startsWith('index ')) {
        _decodeIndexLine(line, currentEntry);
        index++;
        continue;
      }
      if (line.startsWith('--- ')) {
        currentEntry.oldPath = _decodePathSpec(line.substring(4));
        index++;
        continue;
      }
      if (line.startsWith('+++ ')) {
        currentEntry.newPath = _decodePathSpec(line.substring(4));
        index++;
        continue;
      }
      if (line.startsWith('Binary files ')) {
        currentEntry.binary = true;
        index++;
        continue;
      }
      if (line.startsWith('@@ ')) {
        final hunk = _decodeHunk(lines, currentIndex: index);
        currentEntry.hunks.add(hunk.hunk);
        index = hunk.nextIndex;
        continue;
      }

      throw FormatException('Unsupported unified diff line: $line', patchText);
    }

    if (currentEntry != null) {
      entries.add(currentEntry.build());
    }
    return entries;
  }

  static String _zeroHexForEntry(GitDiffEntry entry) {
    final hexLength =
        entry.oldObjectId?.hex.length ?? entry.newObjectId?.hex.length ?? 40;
    return List.filled(hexLength, '0').join();
  }

  static String _formatRange(int start, int lineCount) =>
      lineCount == 1 ? '$start' : '$start,$lineCount';

  static void _writeDiffLine(StringBuffer buffer, GitDiffLine line) {
    final prefix = switch (line.type) {
      GitDiffLineType.context => ' ',
      GitDiffLineType.addition => '+',
      GitDiffLineType.deletion => '-',
    };
    buffer.write(prefix);
    buffer.write(line.text);
    if (!line.text.endsWith('\n')) {
      buffer.write('\n');
      buffer.writeln(r'\ No newline at end of file');
    }
  }

  static void _decodeIndexLine(String line, _GitDiffEntryBuilder entry) {
    final match = RegExp(r'^index ([0-9a-f]+)\.\.([0-9a-f]+)(?: ([0-9]{6}))?$')
        .firstMatch(line);
    if (match == null) {
      throw FormatException('Invalid index line.', line);
    }

    entry.oldObjectId = _decodeMaybeObjectId(match.group(1)!);
    entry.newObjectId = _decodeMaybeObjectId(match.group(2)!);
    entry.indexMode = match.group(3);
  }

  static GitObjectId? _decodeMaybeObjectId(String hex) {
    final normalized = hex.trim();
    if (normalized.isEmpty || _allZeros(normalized)) {
      return null;
    }
    if (!GitObjectId.isValidHex(normalized)) {
      return null;
    }
    return GitObjectId.fromHex(normalized);
  }

  static bool _allZeros(String value) =>
      value.runes.every((codePoint) => codePoint == 0x30);

  static String? _decodePathSpec(String spec) {
    final trimmed = spec.trim();
    if (trimmed == '/dev/null') {
      return null;
    }
    if (trimmed.startsWith('a/') || trimmed.startsWith('b/')) {
      return trimmed.substring(2);
    }
    return trimmed;
  }

  static ({GitDiffHunk hunk, int nextIndex}) _decodeHunk(
    List<String> lines, {
    required int currentIndex,
  }) {
    final header = _stripTrailingLineEnding(lines[currentIndex]);
    final headerMatch = RegExp(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@')
        .firstMatch(header);
    if (headerMatch == null) {
      throw FormatException('Invalid hunk header.', header);
    }

    final hunkLines = <GitDiffLine>[];
    var index = currentIndex + 1;
    while (index < lines.length) {
      final rawLine = lines[index];
      final strippedLine = _stripTrailingLineEnding(rawLine);
      if (strippedLine.startsWith('diff --git ') ||
          strippedLine.startsWith('index ') ||
          strippedLine.startsWith('new file mode ') ||
          strippedLine.startsWith('deleted file mode ') ||
          strippedLine.startsWith('old mode ') ||
          strippedLine.startsWith('new mode ') ||
          strippedLine.startsWith('--- ') ||
          strippedLine.startsWith('+++ ') ||
          strippedLine.startsWith('@@ ')) {
        break;
      }

      if (strippedLine == r'\ No newline at end of file') {
        if (hunkLines.isEmpty) {
          throw FormatException(
            'No previous line was available for a no-newline marker.',
            strippedLine,
          );
        }
        final previousLine = hunkLines.removeLast();
        hunkLines.add(
          GitDiffLine(
            type: previousLine.type,
            text: previousLine.text.endsWith('\n')
                ? previousLine.text.substring(0, previousLine.text.length - 1)
                : previousLine.text,
          ),
        );
        index++;
        continue;
      }

      final prefix = rawLine[0];
      final type = switch (prefix) {
        ' ' => GitDiffLineType.context,
        '+' => GitDiffLineType.addition,
        '-' => GitDiffLineType.deletion,
        _ => null,
      };
      if (type == null) {
        break;
      }

      hunkLines.add(GitDiffLine(type: type, text: rawLine.substring(1)));
      index++;
    }

    return (
      hunk: GitDiffHunk(
        oldStart: int.parse(headerMatch.group(1)!),
        oldLineCount: int.parse(headerMatch.group(2) ?? '1'),
        newStart: int.parse(headerMatch.group(3)!),
        newLineCount: int.parse(headerMatch.group(4) ?? '1'),
        lines: hunkLines,
      ),
      nextIndex: index,
    );
  }

  static List<String> _splitPatchLines(String text) {
    if (text.isEmpty) {
      return const [];
    }

    final lines = <String>[];
    var start = 0;
    for (var index = 0; index < text.length; index++) {
      if (text.codeUnitAt(index) != 0x0a) {
        continue;
      }
      lines.add(text.substring(start, index + 1));
      start = index + 1;
    }
    if (start < text.length) {
      lines.add(text.substring(start));
    }
    return lines;
  }

  static String _stripTrailingLineEnding(String line) {
    var result = line;
    if (result.endsWith('\n')) {
      result = result.substring(0, result.length - 1);
    }
    if (result.endsWith('\r')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }
}

final class _GitDiffEntryBuilder {
  _GitDiffEntryBuilder._({
    required this.headerOldPath,
    required this.headerNewPath,
  });

  factory _GitDiffEntryBuilder.fromDiffGitHeader(String line) {
    final match = RegExp(r'^diff --git a/(.+) b/(.+)$').firstMatch(line);
    if (match == null) {
      throw FormatException('Invalid diff header.', line);
    }
    return _GitDiffEntryBuilder._(
      headerOldPath: match.group(1)!,
      headerNewPath: match.group(2)!,
    );
  }

  final String headerOldPath;
  final String headerNewPath;
  GitDiffChangeType? changeType;
  String? oldPath;
  String? newPath;
  String? oldMode;
  String? newMode;
  String? indexMode;
  GitObjectId? oldObjectId;
  GitObjectId? newObjectId;
  bool binary = false;
  final List<GitDiffHunk> hunks = <GitDiffHunk>[];

  GitDiffEntry build() {
    final effectiveOldPath = oldPath ?? headerOldPath;
    final effectiveNewPath = newPath ?? headerNewPath;
    final effectiveChangeType =
        changeType ??
        switch ((oldPath, newPath)) {
          (null, _) => GitDiffChangeType.added,
          (_, null) => GitDiffChangeType.deleted,
          _ => GitDiffChangeType.modified,
        };

    final path = switch (effectiveChangeType) {
      GitDiffChangeType.added => effectiveNewPath,
      GitDiffChangeType.deleted => effectiveOldPath,
      GitDiffChangeType.modified => effectiveNewPath,
    };
    if (path.isEmpty) {
      throw FormatException('Patch entries must include a path.');
    }

    final resolvedOldMode = switch (effectiveChangeType) {
      GitDiffChangeType.added => null,
      GitDiffChangeType.deleted ||
      GitDiffChangeType.modified => oldMode ?? indexMode ?? newMode,
    };
    final resolvedNewMode = switch (effectiveChangeType) {
      GitDiffChangeType.deleted => null,
      GitDiffChangeType.added ||
      GitDiffChangeType.modified => newMode ?? indexMode ?? oldMode,
    };

    return GitDiffEntry(
      path: path,
      changeType: effectiveChangeType,
      oldMode: resolvedOldMode,
      newMode: resolvedNewMode,
      oldObjectId: oldObjectId,
      newObjectId: newObjectId,
      binary: binary,
      hunks: List<GitDiffHunk>.unmodifiable(hunks),
    );
  }
}

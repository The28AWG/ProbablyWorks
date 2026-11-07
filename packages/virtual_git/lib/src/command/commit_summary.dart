part of '../git_commit_command.dart';

/// Автор, дата и краткий отчёт после commit.
GitCommitSignature _authorSignature(
  GitInvocation parsed, {
  required GitCommitSignature current,
  required GitCommit? amended,
  required GitCommit? reused,
}) {
  final reset = parsed.has('reset-author');
  final source = reused ?? amended;
  if (reset && source == null) {
    throw const GitUsage(
      'fatal: --reset-author can be used only with -C, -c or --amend.\n',
      exitCode: 128,
    );
  }
  final override = _authorLine(parsed.value('author'));
  var name = current.name;
  var email = current.email;
  var seconds = current.timestampSeconds;
  var zone = current.timezoneOffset;
  if (source != null && !reset) {
    name = source.author.name;
    email = source.author.email;
    seconds = source.author.timestampSeconds;
    zone = source.author.timezoneOffset;
  }
  if (override != null) {
    name = override.name;
    email = override.email;
  }
  final date = parsed.value('date');
  if (date != null) {
    final parsedDate = parseGitDate(date);
    if (parsedDate == null) {
      throw GitUsage('fatal: invalid date format: $date\n', exitCode: 128);
    }
    seconds = parsedDate.seconds;
    zone = parsedDate.zone;
  }
  return GitCommitSignature(
    name: name,
    email: email,
    timestampSeconds: seconds,
    timezoneOffset: zone,
  );
}

({String name, String email})? _authorLine(String? raw) {
  if (raw == null) return null;
  final open = raw.lastIndexOf('<');
  final close = raw.lastIndexOf('>');
  if (open <= 0 || close < open) {
    throw GitUsage(
      "fatal: --author '$raw' is not 'Name <email>' and matches no existing author\n",
      exitCode: 128,
    );
  }
  return (
    name: _slice(raw, 0, open).trim(),
    email: _slice(raw, open + 1, close).trim(),
  );
}

/// Печатает сводку нового коммита так же, как `git commit`, `cherry-pick` и `revert`.
///
/// [showDate] у cherry-pick и revert всегда включён: строка `Date:` есть,
/// даже когда имя автора совпадает с коммитером. [initialCommit] добавляет
/// `(root-commit)` только первому коммиту ветки.
Future<void> writeGitCommitSummary(
  AppletIo io,
  GitRepository repo, {
  required GitObjectId id,
  required String message,
  required GitCommitSignature author,
  required GitCommitSignature committer,
  required bool showDate,
  required bool initialCommit,
}) => _printSummary(
  io,
  repo,
  id: id,
  message: message,
  author: author,
  committer: committer,
  showDate: showDate,
  initialCommit: initialCommit,
);

Future<void> _printSummary(
  AppletIo io,
  GitRepository repo, {
  required GitObjectId id,
  required String message,
  required GitCommitSignature author,
  required GitCommitSignature committer,
  required bool showDate,
  required bool initialCommit,
}) async {
  final head = await repo.readReference('HEAD');
  final branch = _branchOf(head?.targetReferenceName) ?? 'detached HEAD';
  final stored = const GitCommitCodec().decode(
    (await repo.show(id.hex))!.bytes,
  );
  final root = initialCommit && stored.parents.isEmpty ? ' (root-commit)' : '';
  io.stdout.writeText('[$branch$root ${_abbr(id.hex)}] ${_subject(message)}\n');
  if (author.name != committer.name || author.email != committer.email) {
    io.stdout.writeText(' Author: ${author.name} <${author.email}>\n');
  }
  if (showDate) io.stdout.writeText(_commitDateLine(author));
  io.stdout.writeText(await _commitStat(repo, stored, id.hex));
}

String _commitDateLine(GitCommitSignature author) {
  final formatted = _formatSignatureDate(author);
  return ' Date: $formatted\n';
}

String _formatSignatureDate(GitCommitSignature signature) {
  final zoned = RegExp(r'^([+-])(\d\d)(\d\d)$')
      .firstMatch(signature.timezoneOffset);
  var seconds = signature.timestampSeconds;
  if (zoned != null) {
    final sign = zoned.group(1) == '-' ? -1 : 1;
    final shift =
        int.parse(zoned.group(2)!) * 3600 + int.parse(zoned.group(3)!) * 60;
    seconds += sign * shift;
  }
  final date = DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final day = '${date.day}';
  final hour = date.hour.toString().padLeft(2, '0');
  final minute = date.minute.toString().padLeft(2, '0');
  final second = date.second.toString().padLeft(2, '0');
  return '${weekdays[date.weekday - 1]} ${months[date.month - 1]} '
      '$day $hour:$minute:$second ${date.year} ${signature.timezoneOffset}';
}

Future<String> _commitStat(
  GitRepository repo,
  GitCommit commit,
  String hex,
) async {
  if (commit.parents.isNotEmpty) {
    return _shortstat(await repo.diffRevisions(commit.parents.first.hex, hex));
  }
  final rows = await repo.listTree(hex, recursive: true);
  final entries = <GitDiffEntry>[];
  for (final row in rows) {
    final object = await repo.readObject(row.entry.objectId);
    if (object == null) continue;
    final lines = const LineSplitter().convert(
      utf8.decode(object.bytes, allowMalformed: true),
    );
    entries.add(
      GitDiffEntry(
        path: row.path,
        changeType: GitDiffChangeType.added,
        newMode: row.entry.mode,
        hunks: [
          GitDiffHunk(
            oldStart: 0,
            oldLineCount: 0,
            newStart: 1,
            newLineCount: lines.length,
            lines: [
              for (final line in lines)
                GitDiffLine(type: GitDiffLineType.addition, text: line),
            ],
          ),
        ],
      ),
    );
  }
  return _shortstat(entries);
}

String _shortstat(List<GitDiffEntry> entries) {
  if (entries.isEmpty) return '';
  var insertions = 0;
  var deletions = 0;
  final modes = StringBuffer();
  for (final entry in entries) {
    for (final hunk in entry.hunks) {
      for (final line in hunk.lines) {
        if (line.type == GitDiffLineType.addition) insertions++;
        if (line.type == GitDiffLineType.deletion) deletions++;
      }
    }
    if (entry.changeType == GitDiffChangeType.added) {
      modes.write(' create mode ${entry.newMode ?? '100644'} ${entry.path}\n');
    } else if (entry.changeType == GitDiffChangeType.deleted) {
      modes.write(' delete mode ${entry.oldMode ?? '100644'} ${entry.path}\n');
    }
  }
  final files = entries.length == 1 ? '1 file' : '${entries.length} files';
  final parts = <String>['$files changed'];
  if (insertions > 0) {
    parts.add('$insertions insertion${insertions == 1 ? '' : 's'}(+)');
  }
  if (deletions > 0) {
    parts.add('$deletions deletion${deletions == 1 ? '' : 's'}(-)');
  }
  return ' ${parts.join(', ')}\n$modes';
}

Future<String> _readText(
  AppletIo io,
  String path, {
  required String missing,
}) async {
  if (path == '-') return utf8.decode(io.stdin);
  try {
    return utf8.decode(await io.fs.readBytes(_join(io.cwd, path)));
  } on VfsException catch (error, stack) {
    Error.throwWithStackTrace(
      GitUsage('$missing${error.message}\n', exitCode: 128),
      stack,
    );
  }
}

String? _branchOf(String? reference) {
  if (reference == null || !reference.startsWith('refs/heads/')) return null;
  return _slice(reference, 'refs/heads/'.length, reference.length);
}

/// Тема как `%s` у git: строки до пустой, хвостовые пробелы сняты, перевод
/// строки между ними заменён одним пробелом.
String _subject(String message) {
  final body = message.endsWith('\n')
      ? _slice(message, 0, message.length - 1)
      : message;
  final parts = <String>[];
  for (final raw in body.split('\n')) {
    final line = _trimRight(raw);
    if (line.isEmpty) break;
    parts.add(line);
  }
  return parts.join(' ');
}

String _abbr(String hex) {
  final end = hex.length < 7 ? hex.length : 7;
  return _slice(hex, 0, end);
}

String _join(String cwd, String path) => path.startsWith('/')
    ? VfsPath.normalize(path)
    : VfsPath.normalize('$cwd/$path');

String _isoZone(String? raw) {
  if (raw == null || raw == 'Z') {
    if (raw == 'Z') return '+0000';
    return _formatZone(DateTime.now().timeZoneOffset);
  }
  return raw;
}

int _zoneSeconds(String zone) {
  final match = RegExp(r'^([+-])(\d\d)(\d\d)$').firstMatch(zone);
  if (match == null) return 0;
  final sign = match.group(1) == '-' ? -1 : 1;
  return sign *
      (int.parse(match.group(2)!) * 3600 + int.parse(match.group(3)!) * 60);
}

String _formatZone(Duration offset) {
  final sign = offset.isNegative ? '-' : '+';
  final absolute = offset.abs();
  final hours = absolute.inHours.toString().padLeft(2, '0');
  final minutes = (absolute.inMinutes % 60).toString().padLeft(2, '0');
  return '$sign$hours$minutes';
}

String _slice(String text, int start, int end) =>
    String.fromCharCodes(text.codeUnits.getRange(start, end));

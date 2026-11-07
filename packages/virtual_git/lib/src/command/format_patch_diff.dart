// ignore_for_file: avoid-substring
// Причина: темы, хеши и base85 режутся по байтам ASCII, как в git.
part of '../git_format_patch.dart';

/// Тело патча, stat и кодирование бинарных блоков.
String _fileName(
  _FpOptions opts,
  int number,
  String subject, {
  required bool cover,
}) {
  if (opts.numberedFiles) return '$number';
  final reroll = opts.reroll;
  final prefix = StringBuffer();
  if (reroll != null) prefix.write('v$reroll-');
  prefix.write('${number.toString().padLeft(4, '0')}-');
  final slug = cover ? 'cover-letter' : _sanitize(subject);
  return _limitFileName(prefix.toString(), slug, opts.suffix, opts.filenameMax);
}

String _sanitize(String subject) {
  final out = StringBuffer();
  var dash = false;
  for (final unit in subject.codeUnits) {
    final ok =
        (unit >= 0x30 && unit <= 0x39) ||
        (unit >= 0x41 && unit <= 0x5a) ||
        (unit >= 0x61 && unit <= 0x7a);
    if (ok) {
      out.writeCharCode(unit);
      dash = false;
      continue;
    }
    if (!dash && out.isNotEmpty) {
      out.write('-');
      dash = true;
    }
  }
  var text = out.toString();
  if (text.endsWith('-')) text = text.substring(0, text.length - 1);
  return text;
}

String _limitFileName(String prefix, String slug, String suffix, int maxLen) {
  final full = '$prefix$slug$suffix';
  if (maxLen <= 0 || full.length <= maxLen) return full;
  final room = maxLen - prefix.length - suffix.length;
  if (room <= 0) {
    final bare = prefix.endsWith('-')
        ? prefix.substring(0, prefix.length - 1)
        : prefix;
    return '$bare$suffix';
  }
  var cut = slug.substring(0, math.min(room, slug.length));
  while (cut.endsWith('-') && cut.isNotEmpty) {
    cut = cut.substring(0, cut.length - 1);
  }
  if (cut.isEmpty) {
    final bare = prefix.endsWith('-')
        ? prefix.substring(0, prefix.length - 1)
        : prefix;
    return '$bare$suffix';
  }
  return '$prefix$cut$suffix';
}

String _wrap(String prefix, String text, int width) =>
    _wrapIndent(text, first: prefix, next: ' ', width: width);

String _wrapIndent(
  String text, {
  required String first,
  required String next,
  required int width,
}) {
  final buf = StringBuffer();
  var lead = first;
  var rest = text.trimRight();
  while (true) {
    if (rest.isEmpty) {
      if (lead == first) buf.writeln(lead.trimRight());
      break;
    }
    final room = width - lead.length;
    if (room >= rest.length) {
      buf.writeln('$lead$rest');
      break;
    }
    var cut = room <= 0 ? -1 : rest.lastIndexOf(' ', room);
    if (cut <= 0) {
      final word = rest.indexOf(' ');
      if (word < 0) {
        buf.writeln('$lead$rest');
        break;
      }
      buf.writeln(lead.trimRight());
      rest = rest.trimLeft();
      lead = next;
      continue;
    }
    buf.writeln('$lead${rest.substring(0, cut)}');
    rest = rest.substring(cut + 1);
    lead = next;
  }
  return buf.toString();
}

String _rfc2822(GitCommitSignature signature) {
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
  final day = date.day.toString().padLeft(2, ' ');
  final hh = date.hour.toString().padLeft(2, '0');
  final mm = date.minute.toString().padLeft(2, '0');
  final ss = date.second.toString().padLeft(2, '0');
  return '${weekdays[date.weekday - 1]}, $day ${months[date.month - 1]} '
      '${date.year} $hh:$mm:$ss ${signature.timezoneOffset}';
}

GitCommitSignature _actor(
  AppletIo io,
  List<({String key, String value})> config, {
  required bool committer,
}) {
  String? env(List<String> keys) {
    for (final key in keys) {
      final value = io.env[key];
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  String? configured(String key) {
    String? found;
    for (final item in config) {
      if (item.key == key) found = item.value;
    }
    return found;
  }

  final name =
      env(
        committer
            ? const ['GIT_COMMITTER_NAME', 'GIT_AUTHOR_NAME']
            : const ['GIT_AUTHOR_NAME'],
      ) ??
      configured('user.name') ??
      io.profile.user;
  final email =
      env(
        committer
            ? const ['GIT_COMMITTER_EMAIL', 'GIT_AUTHOR_EMAIL']
            : const ['GIT_AUTHOR_EMAIL'],
      ) ??
      configured('user.email') ??
      '$name@${io.profile.hostname}';
  final raw = env(
    committer
        ? const ['GIT_COMMITTER_DATE', 'GIT_AUTHOR_DATE']
        : const ['GIT_AUTHOR_DATE'],
  );
  if (raw != null) {
    final parts = raw.split(' ');
    final seconds = int.tryParse(parts.first);
    if (seconds != null) {
      return GitCommitSignature(
        name: name,
        email: email,
        timestampSeconds: seconds,
        timezoneOffset: parts.length > 1 ? parts[1] : '+0000',
      );
    }
  }
  return GitCommitSignature.fromDateTime(
    name: name,
    email: email,
    timestamp: DateTime.now(),
  );
}

Future<List<GitDiffEntry>> _seriesDiff(
  GitRepository repo,
  List<GitLogEntry> commits,
  List<String>? paths,
) async {
  if (commits.isEmpty) return const [];
  final first = commits.first;
  final parent = first.commit.parents.isEmpty
      ? _emptyTree
      : first.commit.parents.first.hex;
  return repo.diffRevisions(
    parent,
    commits.last.objectId.hex,
    pathspecs: paths,
  );
}

Future<List<GitDiffEntry>> _diffOf(
  GitRepository repo,
  GitLogEntry entry,
  List<String>? paths,
) {
  final parent = entry.commit.parents.isEmpty
      ? _emptyTree
      : entry.commit.parents.first.hex;
  return repo.diffRevisions(parent, entry.objectId.hex, pathspecs: paths);
}

String _diffText(List<GitDiffEntry> entries, {required bool gitBinary}) {
  final buf = StringBuffer();
  for (final entry in entries) {
    final encoded = const GitDiffCodec().encode([entry]);
    if (entry.binary && gitBinary) {
      final marker = encoded.lastIndexOf('Binary files ');
      final head = marker < 0 ? encoded : encoded.substring(0, marker);
      buf
        ..write(_stripBinaryPaths(head))
        ..write(_gitBinaryLiteral(entry.oldBytes, entry.newBytes));
    } else if (entry.binary) {
      buf.write(_stripBinaryPaths(_abbreviateIndex(encoded)));
    } else {
      buf.write(_abbreviateIndex(encoded));
    }
  }
  return buf.toString();
}

String _stripBinaryPaths(String patch) {
  final kept = <String>[];
  for (final line in patch.split('\n')) {
    if (line.startsWith('--- ') || line.startsWith('+++ ')) continue;
    kept.add(line);
  }
  return kept.join('\n');
}

String _abbreviateIndex(String patch) => patch.replaceAllMapped(
  RegExp('index ([0-9a-f]+)\\.\\.([0-9a-f]+)'),
  (match) {
    String cut(String hex) => hex.length <= 7 ? hex : hex.substring(0, 7);
    return 'index ${cut(match.group(1)!)}..${cut(match.group(2)!)}';
  },
);

String _abbr(String hex) => hex.length <= 7 ? hex : hex.substring(0, 7);

String _gitBinaryLiteral(List<int>? oldBytes, List<int>? newBytes) {
  final buf = StringBuffer('GIT binary patch\n')
    ..write(_literalBody(newBytes ?? const <int>[]))
    ..write(_literalBody(oldBytes ?? const <int>[]));
  return buf.toString();
}

String _literalBody(List<int> raw) {
  final deflated = const ZLibEncoder().encode(raw);
  final buf = StringBuffer('literal ${raw.length}\n');
  var offset = 0;
  while (offset < deflated.length) {
    final n = math.min(52, deflated.length - offset);
    final chunk = deflated.sublist(offset, offset + n);
    buf.writeln('${_b85Marker(n)}${_encode85(chunk)}');
    offset += n;
  }
  if (deflated.isEmpty) {
    buf.writeln('${_b85Marker(0)}${_encode85(const [])}');
  }
  return buf.toString();
}

String _b85Marker(int count) {
  if (count <= 26) {
    return String.fromCharCode(count + 0x40);
  }
  return String.fromCharCode(count + 0x46);
}

String _encode85(List<int> data) {
  if (data.isEmpty) return '';
  final out = StringBuffer();
  var index = 0;
  var remaining = data.length;
  while (remaining > 0) {
    var acc = 0;
    for (var shift = 24; shift >= 0; shift -= 8) {
      acc |= data[index] << shift;
      index++;
      remaining--;
      if (remaining == 0) break;
    }
    var value = acc;
    final piece = List<int>.filled(5, 0);
    for (var cursor = 4; cursor >= 0; cursor--) {
      piece[cursor] = (value % 85) + 33;
      value ~/= 85;
    }
    out.write(String.fromCharCodes(piece));
  }
  return out.toString();
}

String _stat(List<GitDiffEntry> entries) {
  if (entries.isEmpty) return '';
  var pathWidth = 0;
  var countWidth = 1;
  final rows =
      <
        ({String path, int add, int del, bool binary, int oldSize, int newSize})
      >[];
  var insertions = 0;
  var deletions = 0;
  for (final entry in entries) {
    if (entry.path.length > pathWidth) pathWidth = entry.path.length;
    if (entry.binary) {
      rows.add((
        path: entry.path,
        add: 0,
        del: 0,
        binary: true,
        oldSize: entry.oldBytes?.length ?? 0,
        newSize: entry.newBytes?.length ?? 0,
      ));
      continue;
    }
    var add = 0;
    var del = 0;
    for (final hunk in entry.hunks) {
      for (final line in hunk.lines) {
        switch (line.type) {
          case GitDiffLineType.addition:
            add++;
          case GitDiffLineType.deletion:
            del++;
          case GitDiffLineType.context:
            break;
        }
      }
    }
    insertions += add;
    deletions += del;
    final width = '${add + del}'.length;
    if (width > countWidth) countWidth = width;
    rows.add((
      path: entry.path,
      add: add,
      del: del,
      binary: false,
      oldSize: 0,
      newSize: 0,
    ));
  }
  final buf = StringBuffer();
  for (final row in rows) {
    final name = row.path.padRight(pathWidth);
    if (row.binary) {
      buf.writeln(' $name | Bin ${row.oldSize} -> ${row.newSize} bytes');
      continue;
    }
    final graph = '${'+' * row.add}${'-' * row.del}';
    final count = '${row.add + row.del}'.padLeft(countWidth);
    buf.writeln(' $name | $count $graph');
  }
  final files = entries.length == 1 ? '1 file' : '${entries.length} files';
  final parts = <String>['$files changed'];
  if (insertions > 0) {
    parts.add('$insertions insertion${insertions == 1 ? '' : 's'}(+)');
  }
  if (deletions > 0) {
    parts.add('$deletions deletion${deletions == 1 ? '' : 's'}(-)');
  }
  if (insertions == 0 && deletions == 0) {
    parts
      ..add('0 insertions(+)')
      ..add('0 deletions(-)');
  }
  buf.write(' ${parts.join(', ')}\n');
  for (final entry in entries) {
    if (entry.changeType == GitDiffChangeType.added) {
      buf.writeln(' create mode ${entry.newMode ?? '100644'} ${entry.path}');
    } else if (entry.changeType == GitDiffChangeType.deleted) {
      buf.writeln(' delete mode ${entry.oldMode ?? '100644'} ${entry.path}');
    }
  }
  return buf.toString();
}

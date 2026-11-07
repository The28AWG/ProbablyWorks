// ignore_for_file: avoid-substring
// Причина: темы, хеши и base85 режутся по байтам ASCII, как в git.
part of '../git_format_patch.dart';

/// Письма mbox: заголовки, cover letter и тема.
bool _coverEnabled(_FpOptions opts, int count) {
  final explicit = opts.coverExplicit;
  if (explicit != null) return explicit;
  final wantsExtra = opts.rangeDiff != null || opts.interdiff != null;
  return wantsExtra && count > 1;
}

bool _numbered(_FpOptions opts, int count, {required bool cover}) {
  final explicit = opts.numberedExplicit;
  if (explicit != null) return explicit;
  return count > 1 || cover;
}

Future<_Mail> _cover(
  GitRepository repo,
  _FpOptions opts,
  List<GitLogEntry> commits, {
  required GitCommitSignature actor,
  required bool numbered,
  required int total,
  required String? description,
  required String? signature,
  required int unix,
  required List<String>? paths,
}) async {
  final tip = commits.last;
  final subjectBits = _bracket(
    opts,
    numbered: numbered,
    number: 0,
    total: total,
    keep: false,
  );
  final (subjectText, blurb) = _coverText(opts, description);
  final subject = '$subjectBits$subjectText';
  final buffer = StringBuffer();
  _writeMailHeaders(
    buffer,
    opts,
    hash: opts.zeroCommit ? '0' * 40 : tip.objectId.hex,
    from: actor,
    date: actor,
    subject: subject,
  );
  buffer.writeln();
  if (blurb.isNotEmpty) {
    buffer.write(blurb.endsWith('\n') ? blurb : '$blurb\n');
  }
  buffer.writeln();
  _writeShortlog(buffer, commits);
  final statDiff = await _seriesDiff(repo, commits, paths);
  final stat = _stat(statDiff);
  if (stat.isNotEmpty) {
    buffer
      ..writeln()
      ..write(stat);
  }
  await _writeExtras(buffer, repo, opts, commits, onCover: true);
  if (opts.base != null) {
    buffer
      ..writeln()
      ..writeln('base-commit: ${await _baseHash(repo, opts.base!)}');
  }
  _writeSignature(buffer, signature);
  return _Mail(
    fileName: _fileName(opts, 0, 'cover-letter', cover: true),
    text: buffer.toString(),
    messageId: '<cover.$unix.git.${actor.email}>',
  );
}

Future<_Mail> _patchMail(
  GitRepository repo,
  _FpOptions opts,
  GitLogEntry entry, {
  required GitCommitSignature actor,
  required int number,
  required int total,
  required bool numbered,
  required String? signature,
  required int unix,
  required List<String>? paths,
  required bool baseOnThis,
  required bool extrasOnThis,
}) async {
  final commit = entry.commit;
  final subjectLine = _subject(commit.message);
  final bracket = opts.keepSubject
      ? ''
      : _bracket(
          opts,
          numbered: numbered,
          number: number,
          total: total,
          keep: false,
        );
  final subject = '$bracket$subjectLine';
  final from = _headerFrom(opts, actor, commit);
  final bodyFrom = _bodyFrom(opts, from, commit);
  final diffEntries = await _diffOf(repo, entry, paths);
  final diffText = _diffText(diffEntries, gitBinary: opts.gitBinary);
  final fileName = _fileName(opts, number, subjectLine, cover: false);

  final buffer = StringBuffer();
  _writeMailHeaders(
    buffer,
    opts,
    hash: opts.zeroCommit ? '0' * 40 : entry.objectId.hex,
    from: from,
    date: commit.author,
    subject: subject,
  );
  final mime = opts.attach ?? opts.inline;
  if (mime != null) {
    buffer
      ..writeln('MIME-Version: 1.0')
      ..writeln('Content-Type: multipart/mixed; boundary="${_boundary(mime)}"');
  }
  buffer.writeln();
  if (mime != null) {
    buffer
      ..writeln('This is a multi-part message in MIME format.')
      ..writeln('--${_boundary(mime)}')
      ..writeln('Content-Type: text/plain; charset=UTF-8; format=fixed')
      ..writeln('Content-Transfer-Encoding: 8bit')
      ..writeln();
  }
  if (bodyFrom != null) {
    buffer
      ..writeln('From: $bodyFrom')
      ..writeln();
  }
  final body = _body(commit.message);
  if (body.isNotEmpty) buffer.write(body.endsWith('\n') ? body : '$body\n');
  if (opts.signoff) {
    final line = 'Signed-off-by: ${actor.name} <${actor.email}>';
    if (!body.contains(line)) buffer.writeln(line);
  }
  if (mime != null) {
    if (diffEntries.isNotEmpty && !opts.noStat) {
      buffer
        ..writeln('---')
        ..write(_stat(diffEntries))
        ..writeln()
        ..writeln();
    }
    _writeMimeDiff(
      buffer,
      boundary: _boundary(mime),
      inline: opts.inline != null,
      fileName: fileName,
      diffText: diffText,
    );
  } else if (diffEntries.isNotEmpty && !opts.noStat) {
    buffer
      ..writeln('---')
      ..write(_stat(diffEntries))
      ..writeln()
      ..write(diffText);
  } else if (diffEntries.isNotEmpty) {
    buffer
      ..writeln()
      ..write(diffText);
  }
  if (extrasOnThis) {
    await _writeExtras(buffer, repo, opts, [entry], onCover: false);
  }
  if (baseOnThis && opts.base != null) {
    buffer
      ..writeln()
      ..writeln('base-commit: ${await _baseHash(repo, opts.base!)}');
  }
  _writeSignature(buffer, signature);
  return _Mail(
    fileName: fileName,
    text: buffer.toString(),
    messageId: '<${entry.objectId.hex}.$unix.git.${actor.email}>',
  );
}

void _writeMailHeaders(
  StringBuffer buffer,
  _FpOptions opts, {
  required String hash,
  required GitCommitSignature from,
  required GitCommitSignature date,
  required String subject,
}) {
  buffer
    ..writeln('From $hash $_mboxFromDate')
    ..writeln('From: ${from.name} <${from.email}>')
    ..writeln('Date: ${_rfc2822(date)}')
    ..write(_wrap('Subject: ', subject, 78));
  for (final header in opts.extraHeaders) {
    buffer.writeln(header);
  }
  for (final to in opts.tos) {
    buffer.writeln('To: $to');
  }
  for (final cc in opts.ccs) {
    buffer.writeln('Cc: $cc');
  }
}

String _bracket(
  _FpOptions opts, {
  required bool numbered,
  required int number,
  required int total,
  required bool keep,
}) {
  if (keep || opts.keepSubject) return '';
  final parts = <String>[];
  if (opts.rfc.isNotEmpty) parts.add(opts.rfc);
  parts.add(opts.subjectPrefix);
  final reroll = opts.reroll;
  if (reroll != null) parts.add('v$reroll');
  if (numbered) parts.add('$number/$total');
  return '[${parts.join(' ')}] ';
}

(String, String) _coverText(_FpOptions opts, String? description) {
  const placeholderSubject = '*** SUBJECT HERE ***';
  const placeholderBlurb = '*** BLURB HERE ***';
  if (description == null || description.isEmpty || opts.coverMode == 'none') {
    return (placeholderSubject, placeholderBlurb);
  }
  final mode = opts.coverMode ?? 'message';
  final paragraphs = description.split('\n\n');
  final first = paragraphs.first.trimRight();
  final rest = paragraphs.length < 2 ? '' : paragraphs.sublist(1).join('\n\n');
  final singleLine = !first.contains('\n');
  final useSubject = mode == 'subject' || (mode == 'auto' && singleLine);
  if (useSubject) {
    return (first.trim(), rest.trimRight());
  }
  return (placeholderSubject, description.trimRight());
}

void _writeShortlog(StringBuffer buffer, List<GitLogEntry> commits) {
  final groups = <String, List<String>>{};
  final order = <String>[];
  for (final entry in commits) {
    final name = entry.commit.author.name;
    if (!groups.containsKey(name)) {
      groups[name] = [];
      order.add(name);
    }
    groups[name]!.add(_subject(entry.commit.message));
  }
  for (var index = 0; index < order.length; index++) {
    final name = order[index];
    final subjects = groups[name]!;
    buffer.writeln('$name (${subjects.length}):');
    for (final subject in subjects) {
      buffer.write(_wrapIndent(subject, first: '  ', next: '    ', width: 76));
    }
  }
}

Future<void> _writeExtras(
  StringBuffer buffer,
  GitRepository repo,
  _FpOptions opts,
  List<GitLogEntry> commits, {
  required bool onCover,
}) async {
  if (commits.isEmpty) return;
  if (opts.interdiff != null) {
    final tip = commits.last.objectId.hex;
    await _requireRevision(repo, opts.interdiff!);
    final entries = await repo.diffRevisions(opts.interdiff!, tip);
    final text = _abbreviateIndex(const GitDiffCodec().encode(entries));
    buffer
      ..writeln()
      ..writeln('Interdiff:');
    final lines = text.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    for (final line in lines) {
      buffer.writeln(line);
    }
  }
  if (opts.rangeDiff != null) {
    if (!onCover && commits.length > 1) {
      throw const GitUsage(
        'fatal: --range-diff requires --cover-letter or single patch\n',
        exitCode: 128,
      );
    }
    final body = await _rangeDiff(repo, opts, commits);
    buffer
      ..writeln()
      ..write(body);
  }
}

Future<String> _rangeDiff(
  GitRepository repo,
  _FpOptions opts,
  List<GitLogEntry> current,
) async {
  final previous = await _previousSeries(repo, opts.rangeDiff!, current);
  final width = math.max(current.length, previous.length).toString().length;
  final buf = StringBuffer()..writeln('Range-diff:');
  final pairs = math.max(current.length, previous.length);
  for (var index = 0; index < pairs; index++) {
    final left = index < previous.length ? previous[index] : null;
    final right = index < current.length ? current[index] : null;
    final leftNo = left == null ? '-' : '${index + 1}';
    final rightNo = right == null ? '-' : '${index + 1}';
    final leftHash = left == null ? '-------' : _abbr(left.objectId.hex);
    final rightHash = right == null ? '-------' : _abbr(right.objectId.hex);
    final same =
        left != null && right != null && await _samePatch(repo, left, right);
    final status = left == null
        ? '>'
        : right == null
        ? '<'
        : same
        ? '='
        : '!';
    final title = (left ?? right)!.commit.message;
    buf.writeln(
      '${_padNum(leftNo, width)}  $leftHash $status ${_padNum(rightNo, width)}  $rightHash ${_subject(title)}',
    );
    if (left != null && right != null && !same) {
      final diff = gitUnifiedTextDiff(
        await _rangeSynth(repo, left),
        await _rangeSynth(repo, right),
        context: 1000,
      );
      final nl = diff.indexOf('\n');
      final rest = nl < 0 ? '' : diff.substring(nl + 1);
      buf.writeln('    @@ Metadata');
      for (final line in rest.split('\n')) {
        if (line.isEmpty) continue;
        buf.writeln('    $line');
      }
    }
  }
  return buf.toString();
}

String _padNum(String number, int width) {
  if (number == '-') return '-:';
  return '${number.padLeft(width)}:';
}

Future<List<GitLogEntry>> _previousSeries(
  GitRepository repo,
  String spec,
  List<GitLogEntry> current,
) async {
  if (spec.contains('..')) {
    final normalized = spec.replaceAll('...', '..');
    return _dotDot(repo, normalized, null);
  }
  await _requireRevision(repo, spec);
  if (current.isEmpty) return const [];
  // Одна ревизия — серия от merge-base с вершиной текущей серии до этой
  // ревизии. Предок текущей вершины даёт пустой диапазон, и патчи идут как `>`.
  final base = await repo.mergeBase(spec, current.last.objectId.hex);
  if (base == null || base.hex == (await repo.revParse(spec))?.hex) {
    return const [];
  }
  return repo.revListAncestryPath(
    base: base.hex,
    tip: spec,
    excludeMerges: false,
  );
}

Future<bool> _samePatch(
  GitRepository repo,
  GitLogEntry left,
  GitLogEntry right,
) async {
  if (left.objectId == right.objectId) return true;
  final a = _patchFingerprint(
    _diffText(await _diffOf(repo, left, null), gitBinary: false),
  );
  final b = _patchFingerprint(
    _diffText(await _diffOf(repo, right, null), gitBinary: false),
  );
  return a == b &&
      _subject(left.commit.message) == _subject(right.commit.message);
}

Future<String> _rangeSynth(GitRepository repo, GitLogEntry entry) async {
  final diff = await _diffOf(repo, entry, null);
  final buf = StringBuffer()
    ..writeln(
      'Author: ${entry.commit.author.name} <${entry.commit.author.email}>',
    )
    ..writeln()
    ..writeln(' ## Commit message ##');
  final message = entry.commit.message.trimRight();
  for (final line in message.split('\n')) {
    buf.writeln('    $line');
  }
  buf.writeln();
  final patch = _abbreviateIndex(const GitDiffCodec().encode(diff));
  final section = StringBuffer();
  String? path;
  var kind = '';
  var header = false;
  for (final line in patch.split('\n')) {
    if (line.startsWith('diff --git ')) {
      if (section.isNotEmpty) buf.write(section);
      final parts = line.split(' ');
      path = parts.length >= 4 ? parts[3].substring(2) : null;
      kind = '';
      header = false;
      section.clear();
      continue;
    }
    if (line.startsWith('new file mode')) {
      kind = 'new';
      continue;
    }
    if (line.startsWith('deleted file mode')) {
      kind = 'gone';
      continue;
    }
    if (line.startsWith('@@')) {
      _rangeFileHeader(section, path, kind, header);
      header = true;
      section.writeln('@@');
      continue;
    }
    if (line.startsWith('index ') ||
        line.startsWith('old mode ') ||
        line.startsWith('new mode ') ||
        line.startsWith('similarity ') ||
        line.startsWith('rename ') ||
        line.startsWith('--- ') ||
        line.startsWith('+++ ') ||
        line.isEmpty) {
      continue;
    }
    _rangeFileHeader(section, path, kind, header);
    header = true;
    section.writeln(line);
  }
  buf.write(section);
  return buf.toString().trimRight();
}

void _rangeFileHeader(
  StringBuffer section,
  String? path,
  String kind,
  bool written,
) {
  if (written || path == null) return;
  final suffix = switch (kind) {
    'new' => ' (new)',
    'gone' => ' (gone)',
    _ => '',
  };
  section.writeln(' ## $path$suffix ##');
}

void _thread(List<_Mail> mails, _FpOptions opts) {
  final style = opts.threadStyle;
  final reply = opts.inReplyTo;
  if (style == null && reply == null) {
    for (final mail in mails) {
      mail.messageId = null;
    }
    return;
  }
  for (var index = 0; index < mails.length; index++) {
    final mail = mails[index];
    final headers = StringBuffer();
    if (style != null && mail.messageId != null) {
      headers.writeln('Message-ID: ${mail.messageId}');
    }
    if (reply != null) {
      final id = reply.startsWith('<') ? reply : '<$reply>';
      headers
        ..writeln('In-Reply-To: $id')
        ..writeln('References: $id');
    } else if (style != null && index > 0) {
      final parent = style == 'deep' ? index - 1 : 0;
      final parentId = mails[parent].messageId!;
      headers.writeln('In-Reply-To: $parentId');
      final chain = <String>[];
      final until = style == 'deep' ? index : 1;
      for (var cursor = 0; cursor < until; cursor++) {
        final id = mails[cursor].messageId;
        if (id != null) chain.add(id);
      }
      headers.writeln(_references(chain));
    }
    if (headers.isEmpty) continue;
    final marker = 'From ';
    final nl = mail.text.indexOf('\n');
    if (nl < 0) continue;
    mail.text =
        '${mail.text.substring(0, nl + 1)}$headers${mail.text.substring(nl + 1)}';
    // marker удерживает первую строку From.
    if (!mail.text.startsWith(marker)) continue;
  }
}

String _references(List<String> ids) {
  if (ids.isEmpty) return 'References:';
  var line = 'References: ${ids.first}';
  final lines = <String>[line];
  for (var index = 1; index < ids.length; index++) {
    final id = ids[index];
    if (line.length + 1 + id.length > 78) {
      line = '\t$id';
      lines.add(line);
    } else {
      line = '$line $id';
      lines[lines.length - 1] = line;
    }
  }
  return lines.join('\n');
}

void _writeMimeDiff(
  StringBuffer buffer, {
  required String boundary,
  required bool inline,
  required String fileName,
  required String diffText,
}) {
  final disposition = inline ? 'inline' : 'attachment';
  buffer
    ..writeln('--$boundary')
    ..writeln('Content-Type: text/x-patch; name="$fileName"')
    ..writeln('Content-Transfer-Encoding: 8bit')
    ..writeln('Content-Disposition: $disposition; filename="$fileName"')
    ..writeln()
    ..write(diffText.endsWith('\n') ? diffText : '$diffText\n')
    ..writeln()
    ..writeln('--$boundary--')
    ..writeln()
    ..writeln();
}

String _boundary(String token) {
  if (token.isEmpty || token == '__DEFAULT__') {
    return '------------$_versionMarker';
  }
  return '------------$token';
}

void _writeSignature(StringBuffer buffer, String? signature) {
  if (signature == null) return;
  buffer
    ..writeln('-- ')
    ..writeln(signature)
    ..writeln();
}

Future<String?> _signatureText(
  AppletIo io,
  GitRepository repo,
  _FpOptions opts,
) async {
  if (opts.noSignature) return null;
  if (opts.signatureFile != null) {
    final text = await _readText(io, opts.signatureFile!, 'signature file');
    return text.trimRight();
  }
  if (opts.hasSignatureFlag) {
    final value = opts.signatureValue ?? '';
    if (value.isEmpty) return null;
    return value;
  }
  final configured = opts._cfg('format.signature');
  if (configured != null) {
    if (configured.isEmpty) return null;
    return configured;
  }
  final stored = await repo.configGet('format.signature');
  if (stored != null) {
    if (stored.isEmpty) return null;
    return stored;
  }
  return _versionMarker;
}

Future<String?> _description(AppletIo io, _FpOptions opts) async {
  final file = opts.descriptionFile;
  if (file == null) return null;
  return _readText(io, file, 'branch description file');
}

Future<String> _readText(AppletIo io, String path, String what) async {
  final full = path.startsWith('/') ? path : p.join(io.cwd, path);
  try {
    final bytes = await io.fs.readBytes(full);
    return String.fromCharCodes(bytes);
  } on VfsException catch (_, stack) {
    Error.throwWithStackTrace(
      GitUsage(
        "fatal: unable to read $what '$path': No such file or directory\n",
        exitCode: 128,
      ),
      stack,
    );
  }
}

Future<String> _baseHash(GitRepository repo, String spec) async {
  if (spec == 'auto') {
    throw const GitUsage(
      'fatal: failed to get upstream, if you want to record base commit automatically,\n'
      'please use git branch --set-upstream-to to track a remote branch.\n'
      'Or you could specify base commit by --base=<base-commit-id> manually\n',
      exitCode: 128,
    );
  }
  final id = await repo.revParse(spec);
  if (id == null) {
    throw GitUsage('fatal: unknown commit $spec\n', exitCode: 128);
  }
  return id.hex;
}

GitCommitSignature _headerFrom(
  _FpOptions opts,
  GitCommitSignature actor,
  GitCommit commit,
) {
  final raw = opts.fromIdent;
  if (raw == null) return commit.author;
  if (raw.isEmpty || raw == '__COMMITTER__') return actor;
  final open = raw.lastIndexOf('<');
  final close = raw.lastIndexOf('>');
  if (open <= 0 || close < open) {
    throw GitUsage('fatal: invalid ident line: $raw\n', exitCode: 128);
  }
  return GitCommitSignature(
    name: raw.substring(0, open).trim(),
    email: raw.substring(open + 1, close).trim(),
    timestampSeconds: actor.timestampSeconds,
    timezoneOffset: actor.timezoneOffset,
  );
}

String? _bodyFrom(
  _FpOptions opts,
  GitCommitSignature header,
  GitCommit commit,
) {
  final author = '${commit.author.name} <${commit.author.email}>';
  final shown = '${header.name} <${header.email}>';
  if (opts.fromIdent != null && (opts.forceInBodyFrom || author != shown)) {
    return author;
  }
  return null;
}

String _subject(String message) {
  final nl = message.indexOf('\n');
  final line = nl < 0 ? message : message.substring(0, nl);
  return line.trimRight();
}

String _body(String message) {
  final nl = message.indexOf('\n');
  if (nl < 0) return '';
  var rest = message.substring(nl + 1);
  if (rest.startsWith('\n')) rest = rest.substring(1);
  return rest;
}

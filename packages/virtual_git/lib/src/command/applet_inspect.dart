part of '../git_applet.dart';

/// status, log, diff, show, rev-parse и ls-files.
extension GitAppletInspect on GitApplet {
  Future<int> _status(AppletIo io, List<String> args) async {
    const usage = 'usage: git status [<options>] [--] [<pathspec>...]';
    final parsed = parseGitArgs(args, const [
      GitOption('short', short: 's'),
      GitOption('branch', short: 'b'),
      GitOption('porcelain', valued: true, optional: true),
      GitOption('ignored'),
      GitOption('untracked-files', short: 'u', valued: true, optional: true),
    ], usage: usage);
    final repo = await _repo(io);
    final untracked = _untrackedMode(parsed);
    final report = await repo.status(
      pathspecs: parsed.operands.isEmpty ? null : parsed.operands,
      includeIgnored: parsed.has('ignored'),
    );
    final head = await repo.readReference('HEAD');
    final branch = _branchOf(head?.targetReferenceName);
    final committed = await repo.revParse('HEAD') != null;
    if (parsed.has('porcelain') || parsed.has('short')) {
      final porcelain = parsed.value('porcelain');
      if (porcelain != null && porcelain.isNotEmpty && porcelain != 'v1') {
        throw GitUsage(
          'fatal: unsupported porcelain version: $porcelain\n',
          exitCode: 128,
        );
      }
      if (parsed.has('branch')) {
        writeGitBranchHeader(io, branch, committed: committed);
      }
      writeGitShortStatus(io, report, showUntracked: untracked != 'no');
      return 0;
    }
    final hint = await _sequencerHint(repo);
    writeGitLongStatus(
      io,
      branch: branch,
      committed: committed,
      report: report,
      showUntracked: untracked != 'no',
      sequencerAction: hint?.action,
      sequencerAbbr: hint?.abbr,
    );
    return 0;
  }

  Future<int> _log(AppletIo io, List<String> args) async {
    const usage =
        'usage: git log [<options>] [<revision-range>] [[--] <path>...]';
    final plain = <String>[];
    int? dashedCount;
    for (final arg in args) {
      if (RegExp(r'^-\d+$').hasMatch(arg)) {
        dashedCount = int.parse(_piece(arg, 1, arg.length));
        continue;
      }
      plain.add(arg);
    }
    final parsed = parseGitArgs(plain, const [
      GitOption('max-count', short: 'n', valued: true),
      GitOption('oneline'),
      GitOption('first-parent'),
      GitOption('all'),
      GitOption('patch', short: 'p'),
      GitOption('author', valued: true),
      GitOption('grep', valued: true),
    ], usage: usage);
    final rawCount = parsed.value('max-count');
    final maxCount = rawCount == null ? dashedCount : int.tryParse(rawCount);
    if (rawCount != null && maxCount == null) {
      throw const GitUsage('fatal: invalid --max-count\n', exitCode: 128);
    }
    final repo = await _repo(io);
    // `--` parseGitArgs из операндов выкидывает, поэтому границу путей
    // приходится искать в исходном argv, пропуская значения флагов.
    final selection = _splitLogArgs(args);
    final tips = <String>[];
    final paths = <String>[];
    if (selection.separated) {
      for (final revision in selection.revisions) {
        if (await repo.revParse(revision) == null) {
          throw GitUsage("fatal: bad revision '$revision'\n", exitCode: 128);
        }
        tips.add(revision);
      }
      paths.addAll(selection.paths);
    } else {
      var seenPath = false;
      for (final token in selection.revisions) {
        if (seenPath || await repo.revParse(token) == null) {
          if (!seenPath && !await _logPathExists(repo, token)) {
            throw GitUsage(
              "fatal: ambiguous argument '$token': "
              'unknown revision or path not in the working tree.\n'
              "Use '--' to separate paths from revisions, like this:\n"
              "'git <command> [<revision>...] -- [<file>...]'\n",
              exitCode: 128,
            );
          }
          seenPath = true;
          paths.add(token);
          continue;
        }
        tips.add(token);
      }
    }
    if (parsed.has('all')) {
      for (final branch in await repo.branches()) {
        tips.add(branch.name);
      }
    }
    if (tips.isEmpty) tips.add('HEAD');
    final entries = <GitLogEntry>[];
    final seen = <String>{};
    for (final tip in tips) {
      final page = await repo.log(tip, firstParent: parsed.has('first-parent'));
      for (final entry in page) {
        if (seen.add(entry.objectId.hex)) entries.add(entry);
      }
    }
    final authorFilter = parsed.value('author');
    final grep = parsed.value('grep');
    var shown = 0;
    // Пустая строка между коммитами, но не после последнего — как у git log.
    var separated = false;
    for (final entry in entries) {
      if (authorFilter != null &&
          !entry.commit.author.name.contains(authorFilter)) {
        continue;
      }
      if (grep != null && !entry.commit.message.contains(grep)) continue;
      if (paths.isNotEmpty &&
          !await repo.historyTouches(
            entry.commit,
            entry.objectId.hex,
            pathspecs: paths,
          )) {
        continue;
      }
      if (maxCount != null && shown >= maxCount) break;
      shown++;
      if (parsed.has('oneline')) {
        io.stdout.writeText(
          '${_abbr(entry.objectId.hex)} ${_subject(entry.commit.message)}\n',
        );
        continue;
      }
      if (separated) io.stdout.writeText('\n');
      separated = true;
      _writeCommitHeader(io, entry.objectId.hex, entry.commit);
      if (parsed.has('patch') && entry.commit.parents.isNotEmpty) {
        final patch = await repo.diffRevisions(
          entry.commit.parents.first.hex,
          entry.objectId.hex,
          pathspecs: paths.isEmpty ? null : paths,
        );
        io.stdout.writeText(
          '\n${_shortenDiff(const GitDiffCodec().encode(patch))}',
        );
      }
    }
    return 0;
  }

  Future<int> _diff(AppletIo io, List<String> args) async {
    const usage = 'usage: git diff [<options>] [--] [<path>...]';
    final parsed = parseGitArgs(args, gitDiffParseOptions, usage: usage);
    final repo = await _repo(io);
    final split = _splitDiffOperands(parsed.operands);
    final pathspecs = split.pathspecs;
    final revs = split.revOperands;
    final staged = parsed.has('staged') || parsed.has('cached');

    List<GitDiffEntry> entries;
    if (staged) {
      final ref = revs.isEmpty ? 'HEAD' : revs.first;
      if (revs.length > 1) {
        throw const GitUsage('$usage\n');
      }
      entries = await repo.diff(
        staged: true,
        referenceName: ref,
        pathspecs: pathspecs.isEmpty ? null : pathspecs,
      );
    } else if (revs.isEmpty) {
      entries = await repo.diff(
        pathspecs: pathspecs.isEmpty ? null : pathspecs,
      );
    } else if (parsed.has('merge-base') &&
        revs.length == 2 &&
        !revs.any((r) => r.contains('...'))) {
      final other = revs.first;
      final tip = revs.last;
      final mb = await repo.mergeBase(other, tip);
      if (mb == null) {
        throw const GitUsage('fatal: no merge base found\n', exitCode: 128);
      }
      entries = await repo.diffRevisions(
        mb.hex,
        tip,
        pathspecs: pathspecs.isEmpty ? null : pathspecs,
      );
    } else if (revs.length == 1 && revs.single.contains('...')) {
      final parts = revs.single.split('...');
      if (parts.length != 2) throw const GitUsage('$usage\n');
      final left = parts.first.trim();
      final right = parts.last.trim();
      final mb = await repo.mergeBase(left, right);
      if (mb == null) {
        throw const GitUsage('fatal: no merge base found\n', exitCode: 128);
      }
      entries = await repo.diffRevisions(
        mb.hex,
        right,
        pathspecs: pathspecs.isEmpty ? null : pathspecs,
      );
    } else if (revs.isNotEmpty &&
        await repo.revParse(revs.first) != null &&
        (revs.length == 1 || await repo.revParse(revs[1]) != null)) {
      if (revs.length > 2) throw const GitUsage('$usage\n');
      if (revs.length == 1) {
        entries = await repo.diffRevisions(
          'HEAD',
          revs.first,
          pathspecs: pathspecs.isEmpty ? null : pathspecs,
        );
      } else {
        var oldRev = revs.first;
        var newRev = revs[1];
        if (parsed.has('R')) {
          final swap = oldRev;
          oldRev = newRev;
          newRev = swap;
        }
        entries = await repo.diffRevisions(
          oldRev,
          newRev,
          pathspecs: pathspecs.isEmpty ? null : pathspecs,
        );
      }
    } else {
      throw const GitUsage('$usage\n');
    }

    if (parsed.has('quiet')) {
      return _diffExitCode(parsed, entries);
    }
    io.stdout.writeText(_renderDiff(parsed, entries));
    return _diffExitCode(parsed, entries);
  }

  Future<int> _show(AppletIo io, List<String> args) async {
    const usage = 'usage: git show [<options>] [<object>]';
    final parsed = parseGitArgs(args, const [
      GitOption('oneline'),
    ], usage: usage);
    if (parsed.operands.length > 1) throw const GitUsage('$usage\n');
    final repo = await _repo(io);
    final revision = parsed.operands.isEmpty ? 'HEAD' : parsed.operands.single;
    final colon = revision.indexOf(':');
    if (colon > 0) {
      final rev = _piece(revision, 0, colon);
      final path = _piece(revision, colon + 1, revision.length);
      final entry = await repo.treeEntry(rev, path);
      if (entry == null) {
        io.stderr.writeText("fatal: path '$path' does not exist in '$rev'\n");
        return 128;
      }
      final blob = await repo.show(entry.objectId.hex);
      if (blob == null) return 128;
      io.stdout.writeText(utf8.decode(blob.bytes, allowMalformed: true));
      return 0;
    }
    final object = await repo.show(revision);
    if (object == null) {
      io.stderr.writeText(
        "fatal: ambiguous argument '$revision': unknown revision or path\n",
      );
      return 128;
    }
    if (object.type == GitObjectType.commit) {
      final commit = const GitCommitCodec().decode(object.bytes);
      final id = await repo.revParse(revision);
      if (parsed.has('oneline')) {
        io.stdout.writeText('${_abbr(id!.hex)} ${_subject(commit.message)}\n');
      } else {
        _writeCommitHeader(io, id!.hex, commit);
      }
      if (commit.parents.isNotEmpty) {
        final patch = await repo.diffRevisions(
          commit.parents.first.hex,
          id.hex,
        );
        final diff = _shortenDiff(const GitDiffCodec().encode(patch));
        io.stdout.writeText(parsed.has('oneline') ? diff : '\n$diff');
      }
      return 0;
    }
    io.stdout.writeText(utf8.decode(object.bytes, allowMalformed: true));
    if (object.bytes.isEmpty || object.bytes.last != 0x0a) {
      io.stdout.writeText('\n');
    }
    return 0;
  }

  Future<int> _revParse(AppletIo io, List<String> args) async {
    const usage = 'usage: git rev-parse [<options>] [<args>...]';
    final parsed = parseGitArgs(args, const [
      GitOption('abbrev-ref'),
      GitOption('verify'),
      GitOption('quiet', short: 'q'),
      GitOption('short', valued: true, optional: true),
      GitOption('show-toplevel'),
      GitOption('git-dir'),
    ], usage: usage);
    final repo = await _repo(io);
    if (parsed.has('show-toplevel')) {
      io.stdout.writeText('${repo.path}\n');
    }
    if (parsed.has('git-dir')) {
      io.stdout.writeText('${repo.gitDirectoryPath}\n');
    }
    if (parsed.has('show-toplevel') || parsed.has('git-dir')) {
      if (parsed.operands.isEmpty) return 0;
    }
    if (parsed.operands.isEmpty) throw const GitUsage('$usage\n');
    final length = int.tryParse(parsed.value('short') ?? '') ?? 7;
    for (final revision in parsed.operands) {
      if (parsed.has('abbrev-ref')) {
        io.stdout.writeText('${await _abbrev(repo, revision)}\n');
        continue;
      }
      final id = await repo.revParse(revision);
      if (id == null) {
        if (!parsed.has('quiet')) {
          io.stderr.writeText(
            "fatal: ambiguous argument '$revision': unknown revision or path\n",
          );
        }
        return parsed.has('verify') ? 1 : 128;
      }
      final hex = parsed.has('short') ? _abbr(id.hex, length) : id.hex;
      io.stdout.writeText('$hex\n');
    }
    return 0;
  }

  Future<int> _lsFiles(AppletIo io, List<String> args) async {
    const usage = 'usage: git ls-files [<options>] [--] [<path>...]';
    final parsed = parseGitArgs(args, const [
      GitOption('others', short: 'o'),
      GitOption('ignored', short: 'i'),
      GitOption('cached', short: 'c'),
      GitOption('stage', short: 's'),
      GitOption('z'),
    ], usage: usage);
    final cached =
        parsed.has('cached') ||
        (!parsed.has('others') && !parsed.has('ignored'));
    final repo = await _repo(io);
    final entries = await repo.lsFiles(
      includeUntracked: parsed.has('others'),
      includeIgnored: parsed.has('ignored'),
      pathspecs: parsed.operands.isEmpty ? null : parsed.operands,
    );
    final end = parsed.has('z') ? '\x00' : '\n';
    for (final entry in entries) {
      if (entry.tracked && !cached) continue;
      if (!entry.tracked && parsed.has('stage')) {
        io.stdout.writeText('${entry.path}$end');
        continue;
      }
      if (parsed.has('stage') && entry.tracked) {
        io.stdout.writeText(
          '${_mode(entry.mode!)} ${entry.objectId!.hex} ${entry.stage}\t${entry.path}$end',
        );
        continue;
      }
      io.stdout.writeText('${entry.path}$end');
    }
    return 0;
  }

  Future<List<String>> _trackedChanges(
    GitRepository repo,
    List<String> specs,
  ) async {
    final report = await repo.status();
    return [
      for (final entry in report.entries)
        if (!entry.isUntracked &&
            !entry.isIgnored &&
            entry.isUnstaged &&
            _matches(entry.path, specs))
          entry.path,
    ];
  }

  void _writeCommitHeader(AppletIo io, String hex, GitCommit commit) {
    io.stdout.writeText('commit $hex\n');
    io.stdout.writeText(
      'Author: ${commit.author.name} <${commit.author.email}>\n',
    );
    io.stdout.writeText('Date:   ${_gitDate(commit.author)}\n\n');
    for (final line in const LineSplitter().convert(commit.message)) {
      io.stdout.writeText('    $line\n');
    }
  }

  String _untrackedMode(GitInvocation parsed) {
    final raw = parsed.value('untracked-files');
    if (!parsed.has('untracked-files')) return 'normal';
    if (raw == null || raw.isEmpty) {
      final operand = parsed.operands.isEmpty ? null : parsed.operands.first;
      if (operand == 'no' || operand == 'normal' || operand == 'all') {
        return operand!;
      }
      return 'all';
    }
    return raw;
  }

  String _shortenDiff(String diff) {
    if (diff.isEmpty) return diff;
    final buffer = StringBuffer();
    for (final line in const LineSplitter().convert(diff)) {
      buffer.writeln(line.startsWith('index ') ? _shortenIndex(line) : line);
    }
    return buffer.toString();
  }

  String _shortenIndex(String line) {
    final body = _piece(line, 'index '.length, line.length);
    final dots = body.indexOf('..');
    if (dots < 0) return line;
    final space = body.indexOf(' ', dots);
    final oldHex = _piece(body, 0, dots);
    final newHex = space < 0
        ? _piece(body, dots + 2, body.length)
        : _piece(body, dots + 2, space);
    final suffix = space < 0 ? '' : _piece(body, space, body.length);
    return 'index ${_abbr(oldHex)}..${_abbr(newHex)}$suffix';
  }

  ({List<String> revOperands, List<String> pathspecs}) _splitDiffOperands(
    List<String> operands,
  ) {
    final sep = operands.indexOf('--');
    final revPart = sep < 0 ? operands : operands.sublist(0, sep);
    final tail = sep < 0 ? const <String>[] : operands.sublist(sep + 1);
    return (revOperands: revPart, pathspecs: tail);
  }

  int _diffExitCode(GitInvocation parsed, List<GitDiffEntry> entries) {
    if (!parsed.has('exit-code')) return 0;
    return entries.isEmpty ? 0 : 1;
  }

  String _renderDiff(GitInvocation parsed, List<GitDiffEntry> entries) {
    final hasPatch = parsed.has('patch') && !parsed.has('no-patch');
    final fmtStat = parsed.has('stat') || parsed.has('patch-with-stat');
    final onlyFormats =
        parsed.has('stat') ||
        parsed.has('shortstat') ||
        parsed.has('numstat') ||
        parsed.has('name-only') ||
        parsed.has('name-status');
    var showPatch =
        !parsed.has('no-patch') &&
        (hasPatch || parsed.has('patch-with-stat') || !onlyFormats);
    if (parsed.has('no-patch')) {
      showPatch = false;
    }
    final parts = <String>[];

    if (parsed.has('name-only')) {
      parts.add([for (final entry in entries) '${entry.path}\n'].join());
    }
    if (parsed.has('name-status')) {
      final buf = StringBuffer();
      for (final entry in entries) {
        buf.writeln('${_diffNameStatusLetter(entry)}\t${entry.path}');
      }
      parts.add(buf.toString());
    }
    if (fmtStat) {
      parts.add(_diffStat(entries));
    }
    if (parsed.has('shortstat')) {
      parts.add(entries.isEmpty ? '' : _shortstat(entries));
    }
    if (parsed.has('numstat')) {
      parts.add(_diffNumstat(entries));
    }
    if (showPatch && entries.isNotEmpty) {
      final patchText = const GitDiffCodec().encode(entries);
      parts.add(parsed.has('full-index') ? patchText : _shortenDiff(patchText));
    }

    return parts.join();
  }

  String _diffNameStatusLetter(GitDiffEntry entry) {
    if (entry.conflicted) return 'U';
    return switch (entry.changeType) {
      GitDiffChangeType.added => 'A',
      GitDiffChangeType.deleted => 'D',
      GitDiffChangeType.modified => 'M',
    };
  }

  String _diffNumstat(List<GitDiffEntry> entries) {
    final buf = StringBuffer();
    for (final entry in entries) {
      if (entry.binary) {
        buf.writeln('-\t-\t${entry.path}');
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
      buf.writeln('$add\t$del\t${entry.path}');
    }
    return buf.toString();
  }

  /// Строки `git diff --stat`: график по файлам и сводка.
  ///
  /// Для небольшого diff один `+` или `-` равен одной строке. Ширина числа
  /// берётся по самому длинному счётчику, как у git.
  String _diffStat(List<GitDiffEntry> entries) {
    if (entries.isEmpty) return '';
    final rows = <({String path, int additions, int deletions})>[];
    var pathWidth = 0;
    var countWidth = 1;
    for (final entry in entries) {
      var additions = 0;
      var deletions = 0;
      for (final hunk in entry.hunks) {
        for (final line in hunk.lines) {
          switch (line.type) {
            case GitDiffLineType.addition:
              additions++;
            case GitDiffLineType.deletion:
              deletions++;
            case GitDiffLineType.context:
              break;
          }
        }
      }
      final count = '${additions + deletions}'.length;
      if (entry.path.length > pathWidth) pathWidth = entry.path.length;
      if (count > countWidth) countWidth = count;
      rows.add((path: entry.path, additions: additions, deletions: deletions));
    }
    final buffer = StringBuffer();
    for (final row in rows) {
      final graph = '${'+' * row.additions}${'-' * row.deletions}';
      final count = '${row.additions + row.deletions}'.padLeft(countWidth);
      buffer.writeln(' ${row.path.padRight(pathWidth)} | $count $graph');
    }
    buffer.write(_shortstat(entries));
    return buffer.toString();
  }

  /// Сводка `git commit`: число строк и create/delete mode.
  String _shortstat(List<GitDiffEntry> entries) {
    if (entries.isEmpty) return '';
    var insertions = 0;
    var deletions = 0;
    final modes = StringBuffer();
    for (final entry in entries) {
      for (final hunk in entry.hunks) {
        for (final line in hunk.lines) {
          switch (line.type) {
            case GitDiffLineType.addition:
              insertions++;
            case GitDiffLineType.deletion:
              deletions++;
            case GitDiffLineType.context:
              break;
          }
        }
      }
      if (entry.changeType == GitDiffChangeType.added) {
        modes.write(
          ' create mode ${entry.newMode ?? '100644'} ${entry.path}\n',
        );
      } else if (entry.changeType == GitDiffChangeType.deleted) {
        modes.write(
          ' delete mode ${entry.oldMode ?? '100644'} ${entry.path}\n',
        );
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

  String _piece(String text, int start, int end) =>
      String.fromCharCodes(text.codeUnits.getRange(start, end));

  /// Ревизии и пути `git log`. `--` в операндах разбора нет, поэтому смотрим argv.
  ///
  /// Значения `--max-count`, `--author`, `--grep` и `-n` пропускаются, иначе
  /// число или образец стали бы ревизией. `-5` — это лимит, не путь.
  ({List<String> revisions, List<String> paths, bool separated}) _splitLogArgs(
    List<String> args,
  ) {
    const valuedLong = {'max-count', 'author', 'grep'};
    final revisions = <String>[];
    final paths = <String>[];
    var separated = false;
    for (var index = 0; index < args.length; index++) {
      final arg = args[index];
      if (separated || arg == '-' || !arg.startsWith('-')) {
        if (separated) {
          paths.add(arg);
        } else {
          revisions.add(arg);
        }
        continue;
      }
      if (arg == '--') {
        separated = true;
        continue;
      }
      if (RegExp(r'^-\d+$').hasMatch(arg)) continue;
      if (arg.startsWith('--')) {
        final body = _piece(arg, 2, arg.length);
        final eq = body.indexOf('=');
        final name = eq < 0 ? body : _piece(body, 0, eq);
        if (eq < 0 && valuedLong.contains(name)) index++;
        continue;
      }
      final body = _piece(arg, 1, arg.length);
      for (var cursor = 0; cursor < body.length; cursor++) {
        if (body[cursor] != 'n') continue;
        if (cursor + 1 >= body.length) index++;
        break;
      }
    }
    return (revisions: revisions, paths: paths, separated: separated);
  }

  Future<bool> _logPathExists(GitRepository repo, String path) async {
    try {
      final absolute = repo.resolveWorkTreePath(path);
      if (await File(absolute).exists()) return true;
      return await Directory(absolute).exists();
    } on ArgumentError {
      return false;
    } on StateError {
      return false;
    }
  }
}

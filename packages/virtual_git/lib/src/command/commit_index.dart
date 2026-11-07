part of '../git_commit_command.dart';

/// Подготовка индекса для commit: pathspec и dry-run.
enum _StageMode { asIs, all, include, only }

_StageMode _indexMode(GitInvocation parsed, int pathCount) {
  if (parsed.has('all')) return _StageMode.all;
  if (parsed.has('include')) return _StageMode.include;
  if (parsed.has('only') || pathCount > 0) return _StageMode.only;
  return _StageMode.asIs;
}

void _rejectPathMode(
  GitInvocation parsed,
  _StageMode mode,
  List<String> specs,
) {
  if (parsed.has('all') && specs.isNotEmpty) {
    throw GitUsage(
      "fatal: paths '${specs.first} ...' with -a does not make sense\n",
      exitCode: 128,
    );
  }
  final onlyNeedsPaths =
      parsed.has('only') && !parsed.has('allow-empty') && !parsed.has('amend');
  if (specs.isEmpty && (parsed.has('include') || onlyNeedsPaths)) {
    throw const GitUsage(
      'fatal: No paths with --include/--only does not make sense.\n',
      exitCode: 128,
    );
  }
  if (mode == _StageMode.only &&
      parsed.has('fixup') &&
      _fixupKind(parsed.value('fixup') ?? '').prefix == 'reword') {
    throw const GitUsage(
      "fatal: reword option of '--fixup' and '--patch/--interactive/--all/--include/--only' cannot be used together\n",
      exitCode: 128,
    );
  }
}

bool _dryRun(GitInvocation parsed) =>
    parsed.has('dry-run') ||
    parsed.has('short') ||
    parsed.has('porcelain') ||
    parsed.has('long');

final class _PreparedIndex {
  const _PreparedIndex({
    required this.commitIndex,
    required this.realIndex,
    required this.writeReal,
  });

  final GitIndex commitIndex;
  final GitIndex realIndex;
  final bool writeReal;
}

Future<_PreparedIndex> _prepareIndex(
  GitRepository repo, {
  required GitIndex current,
  required _StageMode mode,
  required List<String> paths,
}) async {
  switch (mode) {
    case _StageMode.asIs:
      return _PreparedIndex(
        commitIndex: current,
        realIndex: current,
        writeReal: false,
      );
    case _StageMode.all:
    case _StageMode.include:
      final updated = await _stagePaths(repo, current, paths);
      return _PreparedIndex(
        commitIndex: updated,
        realIndex: updated,
        writeReal: true,
      );
    case _StageMode.only:
      final headIndex = await _indexFromHead(repo);
      final commitIndex = await _stagePaths(repo, headIndex, paths);
      final realIndex = await _stagePaths(repo, current, paths);
      return _PreparedIndex(
        commitIndex: commitIndex,
        realIndex: realIndex,
        writeReal: true,
      );
  }
}

Future<List<String>> _pathspecs(AppletIo io, GitInvocation parsed) async {
  final fromFile = parsed.value('pathspec-from-file');
  if (parsed.has('pathspec-file-nul') && fromFile == null) {
    throw const GitUsage(
      "fatal: the option '--pathspec-file-nul' requires '--pathspec-from-file'\n",
      exitCode: 128,
    );
  }
  if (fromFile == null) return _pathspecOperands(parsed);
  if (parsed.has('all')) {
    throw const GitUsage(
      "fatal: options '--pathspec-from-file' and '-a' cannot be used together\n",
      exitCode: 128,
    );
  }
  if (parsed.operands.isNotEmpty) {
    throw const GitUsage(
      "fatal: '--pathspec-from-file' and pathspec arguments cannot be used together\n",
      exitCode: 128,
    );
  }
  final text = await _readText(
    io,
    fromFile,
    missing: "fatal: could not open '$fromFile' for reading: ",
  );
  final pieces = parsed.has('pathspec-file-nul')
      ? text.split('\x00')
      : const LineSplitter().convert(text);
  return [
    for (final piece in pieces)
      if (piece.isNotEmpty) piece,
  ];
}

Future<List<String>> _resolvePaths(
  GitRepository repo,
  List<String> specs,
  _StageMode mode,
) async {
  if (mode == _StageMode.all) {
    final report = await repo.status();
    return [
      for (final entry in report.entries)
        if (!entry.isUntracked && !entry.isIgnored && entry.isUnstaged)
          entry.path,
    ];
  }
  final known = <String>{};
  final index = await repo.readIndex();
  if (index != null) {
    for (final entry in index.entries) {
      known.add(entry.path);
    }
  }
  final head = await repo.revParse('HEAD');
  if (head != null) {
    for (final row in await repo.listTree(head.hex, recursive: true)) {
      known.add(row.path);
    }
  }
  for (final entry in (await repo.status()).entries) {
    known.add(entry.path);
  }
  final selected = <String>{};
  for (final spec in specs) {
    final hits = [
      for (final path in known)
        if (_pathspecMatches(path, spec)) path,
    ];
    if (hits.isEmpty) {
      throw GitUsage(
        "error: pathspec '$spec' did not match any file(s) known to git\n",
        exitCode: 1,
      );
    }
    selected.addAll(hits);
  }
  return selected.toList()..sort();
}

bool _pathspecMatches(String path, String spec) {
  var pattern = spec;
  if (pattern.startsWith('./')) {
    pattern = _slice(pattern, 2, pattern.length);
  }
  if (pattern.endsWith('/')) {
    pattern = _slice(pattern, 0, pattern.length - 1);
  }
  return pattern == '.' || path == pattern || path.startsWith('$pattern/');
}

Future<GitIndex> _indexFromHead(GitRepository repo) async {
  final head = await repo.revParse('HEAD');
  if (head == null) return const GitIndex();
  var index = const GitIndex();
  for (final row in await repo.listTree(head.hex, recursive: true)) {
    index = index.withEntry(
      GitIndexEntry(
        ctimeSeconds: 0,
        ctimeNanoseconds: 0,
        mtimeSeconds: 0,
        mtimeNanoseconds: 0,
        device: 0,
        inode: 0,
        mode: _indexModeOf(row.entry.mode),
        userId: 0,
        groupId: 0,
        fileSize: 0,
        objectId: row.entry.objectId,
        path: row.path,
      ),
    );
  }
  return index;
}

int _indexModeOf(String mode) => switch (mode) {
  '100644' => GitIndexEntry.regularFileMode,
  '100755' => GitIndexEntry.executableFileMode,
  '120000' => GitIndexEntry.symbolicLinkMode,
  '160000' => GitIndexEntry.gitLinkMode,
  _ => throw StateError('Unsupported tree mode: $mode'),
};

Future<GitIndex> _stagePaths(
  GitRepository repo,
  GitIndex base,
  List<String> paths,
) async {
  var index = base;
  for (final path in paths) {
    try {
      final entry = await repo.createIndexEntryFromWorkTreePath(path);
      index = index.withEntry(entry);
    } on ArgumentError {
      index = index.withoutPath(path);
    }
  }
  return index;
}

Future<String?> _statusReference(
  GitRepository repo, {
  required bool amend,
}) async {
  if (!amend) {
    final head = await repo.revParse('HEAD');
    return head?.hex;
  }
  return (await repo.revParse('HEAD^'))?.hex;
}

Future<bool> _committable(
  GitRepository repo,
  GitIndex index, {
  required String? reference,
}) async {
  final tree = await repo.writeTreeFromIndex(index);
  if (reference == null) return index.entries.isNotEmpty;
  final commit = const GitCommitCodec().decode(
    (await repo.show(reference))!.bytes,
  );
  return commit.tree.hex != tree.hex;
}

Future<void> _printStatus(
  AppletIo io,
  GitRepository repo,
  GitInvocation parsed, {
  required List<String> args,
  required GitIndex index,
  required String? reference,
  required bool committed,
}) async {
  final report = await repo.status(
    index: index,
    referenceName: reference ?? 'HEAD',
  );
  final head = await repo.readReference('HEAD');
  final branch = _branchOf(head?.targetReferenceName);
  final untracked = _untrackedMode(parsed);
  final showUntracked = untracked != 'no';
  final nul = parsed.has('null');
  final end = nul ? '\x00' : '\n';
  if (parsed.has('porcelain')) {
    final version = parsed.value('porcelain');
    if (version != null && version.isNotEmpty && version != 'v1') {
      throw GitUsage(
        'fatal: unsupported porcelain version: $version\n',
        exitCode: 128,
      );
    }
  }
  final short = parsed.has('short') || parsed.has('porcelain');
  if (short && parsed.has('branch')) {
    final tracking = committed && branch != null
        ? await _trackingSuffix(repo, branch, counts: _wantsAheadBehind(args))
        : '';
    writeGitBranchHeader(
      io,
      branch,
      committed: committed,
      tracking: tracking,
      terminator: end,
    );
  }
  if (short) {
    writeGitShortStatus(
      io,
      report,
      showUntracked: showUntracked,
      terminator: end,
    );
    return;
  }
  writeGitLongStatus(
    io,
    branch: branch,
    committed: committed,
    report: report,
    showUntracked: showUntracked,
    mentionHiddenUntracked: !showUntracked,
    unbornHeading: 'Initial commit',
  );
}

/// `--no-ahead-behind` снимается разбором как отрицание флага и в [GitInvocation]
/// не остаётся. Последний из пары в argv побеждает, как у git.
bool _wantsAheadBehind(List<String> args) {
  var counts = true;
  for (final arg in args) {
    if (arg == '--ahead-behind') counts = true;
    if (arg == '--no-ahead-behind') counts = false;
  }
  return counts;
}

Future<String> _trackingSuffix(
  GitRepository repo,
  String branch, {
  required bool counts,
}) async {
  final remote = await _configValue(repo, 'branch.$branch.remote');
  final merge = await _configValue(repo, 'branch.$branch.merge');
  if (remote == null || merge == null || remote.isEmpty || merge.isEmpty) {
    return '';
  }
  final short = merge.startsWith('refs/heads/')
      ? _slice(merge, 'refs/heads/'.length, merge.length)
      : merge;
  final label = '$remote/$short';
  final upstream = 'refs/remotes/$remote/$short';
  if (await repo.revParse(upstream) == null) return '...$label [gone]';
  if (!counts) return '...$label';
  final ahead = await _countAhead(repo, 'HEAD', upstream);
  final behind = await _countAhead(repo, upstream, 'HEAD');
  if (ahead == 0 && behind == 0) return '...$label';
  if (behind == 0) return '...$label [ahead $ahead]';
  if (ahead == 0) return '...$label [behind $behind]';
  return '...$label [ahead $ahead, behind $behind]';
}

/// Значение ключа из `.git/config`. Секция и имя без учёта регистра,
/// подсекция — как записана: так git читает `branch.main.remote`.
Future<String?> _configValue(GitRepository repo, String key) async {
  final file = File(repo.configFilePath);
  if (!await file.exists()) return null;
  final firstDot = key.indexOf('.');
  final lastDot = key.lastIndexOf('.');
  if (firstDot <= 0 || lastDot <= firstDot) return null;
  final wantSection = _slice(key, 0, firstDot).toLowerCase();
  final wantSubsection = _slice(key, firstDot + 1, lastDot);
  final wantName = _slice(key, lastDot + 1, key.length).toLowerCase();
  String? section;
  String? subsection;
  for (final line in await file.readAsLines()) {
    final trimmed = line.trim();
    if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
      final header = _slice(trimmed, 1, trimmed.length - 1).trim();
      final quote = header.indexOf('"');
      if (quote < 0) {
        section = header.toLowerCase();
        subsection = null;
      } else {
        section = _slice(header, 0, quote).trim().toLowerCase();
        final end = header.lastIndexOf('"');
        subsection = end > quote
            ? _slice(header, quote + 1, end)
            : _slice(header, quote + 1, header.length);
      }
      continue;
    }
    final split = trimmed.indexOf('=');
    if (section == null || split <= 0) continue;
    final name = _slice(trimmed, 0, split).trim().toLowerCase();
    final value = _slice(trimmed, split + 1, trimmed.length).trim();
    if (section == wantSection &&
        subsection == wantSubsection &&
        name == wantName) {
      return value;
    }
  }
  return null;
}

Future<int> _countAhead(GitRepository repo, String tip, String base) async {
  final tipIds = <String>{
    for (final entry in await repo.log(tip)) entry.objectId.hex,
  };
  final baseIds = <String>{
    for (final entry in await repo.log(base)) entry.objectId.hex,
  };
  var count = 0;
  for (final id in tipIds) {
    if (!baseIds.contains(id)) count++;
  }
  return count;
}

List<String> _pathspecOperands(GitInvocation parsed) {
  final operands = parsed.operands;
  if (_untrackedStealsOperand(parsed)) {
    return operands.sublist(1);
  }
  return operands;
}

bool _untrackedStealsOperand(GitInvocation parsed) {
  if (parsed.separated || !parsed.has('untracked-files')) return false;
  final raw = parsed.value('untracked-files') ?? '';
  if (raw.isNotEmpty || parsed.operands.isEmpty) return false;
  final next = parsed.operands.first;
  return next == 'no' || next == 'normal' || next == 'all';
}

String _untrackedMode(GitInvocation parsed) {
  if (!parsed.has('untracked-files')) return 'normal';
  final raw = parsed.value('untracked-files') ?? '';
  if (raw.isEmpty) {
    if (_untrackedStealsOperand(parsed)) return parsed.operands.first;
    return 'all';
  }
  if (raw == 'no' || raw == 'normal' || raw == 'all') return raw;
  throw GitUsage("fatal: Invalid untracked files mode '$raw'\n", exitCode: 128);
}

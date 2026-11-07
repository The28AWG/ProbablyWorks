/// `git commit`: сообщение, частичный индекс и сухой прогон.
///
/// Редактор, интерактив, GPG и хуки в виртуальном хосте не запускаются.
/// Редактор совпадает с git без `EDITOR`: две строки в stderr и код 1.
/// Интерактив, GPG и флаги хуков — явный `fatal`, код 128: молчаливого
/// успеха у них нет. Остальные флаги справки меняют коммит или статус.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:virtual_git/src/git_cli.dart';
import 'package:virtual_git/src/git_commit.dart';
import 'package:virtual_git/src/git_commit_codec.dart';
import 'package:virtual_git/src/git_diff.dart';
import 'package:virtual_git/src/git_host_io.dart';
import 'package:virtual_git/src/git_index.dart';
import 'package:virtual_git/src/git_object_id.dart';
import 'package:virtual_git/src/git_repository.dart';
import 'package:virtual_git/src/git_status_format.dart';
import 'package:virtual_host/virtual_host.dart';

const _usage = 'usage: git commit [<options>] [--] [<pathspec>...]';

const _editorError =
    'error: Terminal is dumb, but EDITOR unset\n'
    'Please supply the message using either -m or -F option.\n';

const _scissorsMarker =
    '# ------------------------ >8 ------------------------';

/// Абсолютная дата в формах, которые git кладёт в объект коммита.
///
/// Принимаются `секунды ±zzzz`, `@секунды`, `YYYY-MM-DD HH:MM:SS ±zzzz`
/// и та же запись через `T`. Без пояса берётся пояс машины: так же делает git.
/// Относительные слова (`yesterday`) не разбираются: `fatal: invalid date format`.
({int seconds, String zone})? parseGitDate(String raw) {
  final trimmed = raw.trim();
  final zoned = RegExp(r'^(\d+) ([+-]\d{4})$').firstMatch(trimmed);
  if (zoned != null) {
    return (seconds: int.parse(zoned.group(1)!), zone: zoned.group(2)!);
  }
  final unix = RegExp(r'^@?(\d+)$').firstMatch(trimmed);
  if (unix != null) {
    return (seconds: int.parse(unix.group(1)!), zone: '+0000');
  }
  final iso = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})(?:\s*([+-]\d{4}|Z))?$',
  ).firstMatch(trimmed);
  if (iso == null) return null;
  final zone = _isoZone(iso.group(7));
  final wall = DateTime.utc(
    int.parse(iso.group(1)!),
    int.parse(iso.group(2)!),
    int.parse(iso.group(3)!),
    int.parse(iso.group(4)!),
    int.parse(iso.group(5)!),
    int.parse(iso.group(6)!),
  );
  final shift = _zoneSeconds(zone);
  return (seconds: wall.millisecondsSinceEpoch ~/ 1000 - shift, zone: zone);
}

/// Выполняет `git commit`. [author] и [committer] — личность из окружения.
Future<int> runGitCommit(
  AppletIo io,
  GitRepository repo,
  List<String> args, {
  required GitCommitSignature author,
  required GitCommitSignature committer,
}) async {
  final parsed = parseGitArgs(args, _commitOptions, usage: _usage);
  _rejectUnsupported(parsed);
  _rejectConflicts(parsed);

  final amend = parsed.has('amend');
  final allowEmpty = parsed.has('allow-empty');
  final headId = await repo.revParse('HEAD');
  if (amend && headId == null) {
    throw const GitUsage('fatal: You have nothing to amend.\n', exitCode: 128);
  }
  final amended = headId == null || !amend
      ? null
      : const GitCommitCodec().decode((await repo.show(headId.hex))!.bytes);

  _rejectResetAuthor(parsed);
  _cleanupMode(parsed.value('cleanup'));
  final date = parsed.value('date');
  if (date != null && parseGitDate(date) == null) {
    throw GitUsage('fatal: invalid date format: $date\n', exitCode: 128);
  }
  _authorLine(parsed.value('author'));
  await _prefetchRevisions(repo, parsed);
  if (_needsEditorBeforeStatus(parsed)) {
    io.stderr.writeText(_editorError);
    return 1;
  }
  final specs = await _pathspecs(io, parsed);
  final mode = _indexMode(parsed, specs.length);
  _rejectPathMode(parsed, mode, specs);
  final paths = mode == _StageMode.asIs
      ? const <String>[]
      : await _resolvePaths(repo, specs, mode);

  final current = await repo.readIndex() ?? const GitIndex();
  final prepared = await _prepareIndex(
    repo,
    current: current,
    mode: mode,
    paths: paths,
  );
  final commitIndex = prepared.commitIndex;
  final dryRun = _dryRun(parsed);
  final reference = await _statusReference(repo, amend: amend);
  final committable = await _committable(
    repo,
    commitIndex,
    reference: reference,
  );

  if (dryRun) {
    await _printStatus(
      io,
      repo,
      parsed,
      args: args,
      index: commitIndex,
      reference: amend ? 'HEAD^' : 'HEAD',
      committed: headId != null,
    );
    return committable ? 0 : 1;
  }

  if (!committable && !allowEmpty && !amend) {
    await _printStatus(
      io,
      repo,
      parsed,
      args: args,
      index: commitIndex,
      reference: 'HEAD',
      committed: headId != null,
    );
    return 1;
  }

  final built = await _buildMessage(
    io,
    repo,
    parsed,
    amended: amended,
    committer: committer,
  );
  if (built == null) {
    io.stderr.writeText(_editorError);
    return 1;
  }
  if (_messageIsEmpty(built.text, verbatim: built.verbatim) &&
      !parsed.has('allow-empty-message')) {
    io.stderr.writeText('Aborting commit due to empty commit message.\n');
    return 1;
  }

  final signature = _authorSignature(
    parsed,
    current: author,
    amended: amended,
    reused: built.authorSource,
  );
  if (prepared.writeReal) {
    await repo.writeIndex(prepared.realIndex);
    // `--only` оставляет дерево полного индекса как недостижимый объект:
    // git пишет его вместе с индексом, и loose-файл остаётся после коммита.
    if (mode == _StageMode.only) {
      await repo.writeTreeFromIndex(prepared.realIndex);
    }
  }
  final id = await repo.commit(
    author: signature,
    committer: committer,
    message: built.text,
    allowEmpty: allowEmpty || amend,
    index: commitIndex,
    parents: amended?.parents,
    reflogAction: amend ? 'commit (amend)' : 'commit',
  );
  await io.fs.writeBytes(
    '${repo.gitDirectoryPath}/COMMIT_EDITMSG',
    Uint8List.fromList(utf8.encode(built.text)),
  );
  if (!parsed.has('quiet')) {
    await _printSummary(
      io,
      repo,
      id: id,
      message: built.text,
      author: signature,
      committer: committer,
      showDate:
          parsed.has('date') ||
          ((amend || built.authorSource != null) &&
              !parsed.has('reset-author')),
      initialCommit: !amend,
    );
  }
  return 0;
}

const _commitOptions = <GitOption>[
  GitOption('message', short: 'm', valued: true),
  GitOption('file', short: 'F', valued: true),
  GitOption('author', valued: true),
  GitOption('date', valued: true),
  GitOption('reedit-message', short: 'c', valued: true),
  GitOption('reuse-message', short: 'C', valued: true),
  GitOption('fixup', valued: true),
  GitOption('squash', valued: true),
  GitOption('reset-author'),
  GitOption('trailer', valued: true),
  GitOption('signoff', short: 's'),
  GitOption('template', short: 't', valued: true),
  GitOption('edit', short: 'e'),
  GitOption('cleanup', valued: true),
  GitOption('status'),
  GitOption('gpg-sign', short: 'S', valued: true, optional: true),
  GitOption('all', short: 'a'),
  GitOption('include', short: 'i'),
  GitOption('interactive'),
  GitOption('patch', short: 'p'),
  GitOption('unified', short: 'U', valued: true),
  GitOption('inter-hunk-context', valued: true),
  GitOption('only', short: 'o'),
  GitOption('no-verify', short: 'n'),
  GitOption('verify'),
  GitOption('dry-run'),
  GitOption('short'),
  GitOption('branch'),
  GitOption('ahead-behind'),
  GitOption('porcelain', valued: true, optional: true),
  GitOption('long'),
  GitOption('null', short: 'z'),
  GitOption('amend'),
  GitOption('no-post-rewrite'),
  GitOption('post-rewrite'),
  GitOption('untracked-files', short: 'u', valued: true, optional: true),
  GitOption('pathspec-from-file', valued: true),
  GitOption('pathspec-file-nul'),
  GitOption('allow-empty'),
  GitOption('allow-empty-message'),
  GitOption('quiet', short: 'q'),
  GitOption('verbose', short: 'v'),
];

void _rejectUnsupported(GitInvocation parsed) {
  if (parsed.has('gpg-sign')) {
    throw const GitUsage(
      'fatal: gpg signing is not supported in virtual git\n',
      exitCode: 128,
    );
  }
  if (parsed.has('interactive') || parsed.has('patch')) {
    throw const GitUsage(
      'fatal: interactive mode is not supported in virtual git\n',
      exitCode: 128,
    );
  }
  if (parsed.has('no-verify') ||
      parsed.has('verify') ||
      parsed.has('no-post-rewrite') ||
      parsed.has('post-rewrite')) {
    throw const GitUsage(
      'fatal: commit hooks are not supported in virtual git\n',
      exitCode: 128,
    );
  }
  if (parsed.has('unified')) {
    throw const GitUsage(
      "fatal: the option '--unified' requires '--interactive/--patch'\n",
      exitCode: 128,
    );
  }
  if (parsed.has('inter-hunk-context')) {
    throw const GitUsage(
      "fatal: the option '--inter-hunk-context' requires '--interactive/--patch'\n",
      exitCode: 128,
    );
  }
}

void _rejectConflicts(GitInvocation parsed) {
  _rejectPair(
    parsed.has('reset-author'),
    '--reset-author',
    parsed.has('author'),
    '--author',
  );
  _rejectMany([
    (parsed.has('reuse-message'), '-C'),
    (parsed.has('reedit-message'), '-c'),
    (parsed.has('file'), '-F'),
    (parsed.has('fixup'), '--fixup'),
  ]);
  _rejectMany([
    (parsed.has('message'), '-m'),
    (parsed.has('reedit-message'), '-c'),
    (parsed.has('reuse-message'), '-C'),
    (parsed.has('file'), '-F'),
  ]);
  _rejectPair(parsed.has('squash'), '--squash', parsed.has('fixup'), '--fixup');
  if ((parsed.has('message') || parsed.has('file')) && parsed.has('fixup')) {
    final kind = _fixupKind(parsed.value('fixup') ?? '');
    if (kind.prefix == 'amend' || kind.prefix == 'reword') {
      final source = parsed.has('message') ? '-m' : '-F';
      throw GitUsage(
        "fatal: options '$source' and '--fixup:${kind.prefix}' cannot be used together\n",
        exitCode: 128,
      );
    }
  }
  _rejectMany([
    (parsed.has('include'), '-i/--include'),
    (parsed.has('only'), '-o/--only'),
    (parsed.has('all'), '-a/--all'),
  ]);
}

void _rejectPair(bool left, String leftName, bool right, String rightName) {
  if (!left || !right) return;
  throw GitUsage(
    "fatal: options '$leftName' and '$rightName' cannot be used together\n",
    exitCode: 128,
  );
}

void _rejectMany(List<(bool, String)> options) {
  final names = [
    for (final option in options)
      if (option.$1) option.$2,
  ];
  if (names.length < 2) return;
  if (names.length == 2) {
    throw GitUsage(
      "fatal: options '${names.first}' and '${names[1]}' cannot be used together\n",
      exitCode: 128,
    );
  }
  final leading = [
    for (var index = 0; index < names.length - 1; index++) "'${names[index]}'",
  ].join(', ');
  throw GitUsage(
    "fatal: options $leading, and '${names.last}' cannot be used together\n",
    exitCode: 128,
  );
}

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

final class _BuiltMessage {
  const _BuiltMessage({
    required this.text,
    required this.verbatim,
    required this.authorSource,
  });

  final String text;
  final bool verbatim;
  final GitCommit? authorSource;
}

/// `--reset-author` без `-C`/`-c`/`--amend` git отвергает до статуса.
void _rejectResetAuthor(GitInvocation parsed) {
  if (!parsed.has('reset-author')) return;
  if (parsed.has('reuse-message') ||
      parsed.has('reedit-message') ||
      parsed.has('amend')) {
    return;
  }
  throw const GitUsage(
    'fatal: --reset-author can be used only with -C, -c or --amend.\n',
    exitCode: 128,
  );
}

/// Ревизии `-C`, `--fixup` и `--squash` git проверяет до статуса.
/// Нет коммита — `fatal`, даже если индексировать нечего.
Future<void> _prefetchRevisions(
  GitRepository repo,
  GitInvocation parsed,
) async {
  if (parsed.has('reuse-message')) {
    await _lookupCommit(repo, parsed.value('reuse-message')!);
  }
  if (parsed.has('squash')) {
    await _lookupCommit(repo, parsed.value('squash')!);
  }
  if (parsed.has('fixup')) {
    await _lookupCommit(repo, _fixupKind(parsed.value('fixup') ?? '').revision);
  }
}

/// `--fixup=amend|reword` зовёт редактор раньше проверки «нечего коммитить».
bool _needsEditorBeforeStatus(GitInvocation parsed) {
  if (!parsed.has('fixup')) return false;
  final prefix = _fixupKind(parsed.value('fixup') ?? '').prefix;
  return prefix == 'amend' || prefix == 'reword';
}

Future<_BuiltMessage?> _buildMessage(
  AppletIo io,
  GitRepository repo,
  GitInvocation parsed, {
  required GitCommit? amended,
  required GitCommitSignature committer,
}) async {
  final fixup = parsed.has('fixup')
      ? _fixupKind(parsed.value('fixup') ?? '')
      : null;
  if (fixup != null && (fixup.prefix == 'amend' || fixup.prefix == 'reword')) {
    return null;
  }
  if (parsed.has('edit') || parsed.has('reedit-message')) return null;

  final cleanup = _cleanupMode(parsed.value('cleanup'));
  GitCommit? authorSource;
  final raw = StringBuffer();

  if (parsed.has('squash')) {
    final source = await _lookupCommit(repo, parsed.value('squash')!);
    raw.write('squash! ${_subject(source.message)}\n\n');
  }

  if (parsed.has('message') && fixup == null) {
    raw.write(_joinParagraphs(parsed.valuesOf('message')));
  } else if (parsed.has('file')) {
    raw.write(
      await _readText(
        io,
        parsed.value('file')!,
        missing: "fatal: could not read log file '${parsed.value('file')}': ",
      ),
    );
  } else if (parsed.has('reuse-message')) {
    authorSource = await _lookupCommit(repo, parsed.value('reuse-message')!);
    raw.write(authorSource.message);
  } else if (fixup != null) {
    final source = await _lookupCommit(repo, fixup.revision);
    raw.write('fixup! ${_subject(source.message)}\n\n');
    if (parsed.has('message')) {
      raw.write(_joinParagraphs(parsed.valuesOf('message')));
    }
  } else if (amended != null) {
    authorSource = amended;
    raw.write(amended.message);
  } else {
    return null;
  }

  if (parsed.has('squash') &&
      !parsed.has('message') &&
      !parsed.has('file') &&
      raw.toString().startsWith('squash!')) {
    return null;
  }

  var text = raw.toString();
  if (parsed.has('verbose')) text = _cutScissors(text);
  final verbatim = cleanup == _Cleanup.verbatim;
  if (!verbatim) {
    text = _stripSpace(text, stripComments: cleanup == _Cleanup.strip);
  }
  if (parsed.has('signoff')) {
    text = _appendSignoff(
      text,
      'Signed-off-by: ${committer.name} <${committer.email}>',
    );
  }
  for (final trailer in parsed.valuesOf('trailer')) {
    text = _appendTrailer(text, _normalizeTrailer(trailer));
  }
  return _BuiltMessage(
    text: text,
    verbatim: verbatim,
    authorSource: authorSource,
  );
}

enum _Cleanup { space, verbatim, strip }

_Cleanup _cleanupMode(String? raw) {
  final mode = raw ?? 'default';
  return switch (mode) {
    'default' || 'whitespace' || 'scissors' => _Cleanup.space,
    'verbatim' => _Cleanup.verbatim,
    'strip' => _Cleanup.strip,
    _ => throw GitUsage('fatal: Invalid cleanup mode $mode\n', exitCode: 128),
  };
}

({String prefix, String revision}) _fixupKind(String raw) {
  var index = 0;
  final units = raw.codeUnits;
  while (index < units.length && _isAlpha(units[index])) {
    index++;
  }
  if (index > 0 && index < units.length && units[index] == 0x3a) {
    final name = _slice(raw, 0, index);
    final revision = _slice(raw, index + 1, raw.length);
    if (name == 'amend' || name == 'reword') {
      return (prefix: name, revision: revision);
    }
    throw GitUsage(
      'fatal: unknown option: --fixup=$name:$revision\n',
      exitCode: 128,
    );
  }
  if (raw.isEmpty) {
    throw const GitUsage(
      'fatal: could not lookup commit \'\'\n',
      exitCode: 128,
    );
  }
  return (prefix: 'fixup', revision: raw);
}

bool _isAlpha(int unit) =>
    (unit >= 0x41 && unit <= 0x5a) || (unit >= 0x61 && unit <= 0x7a);

Future<GitCommit> _lookupCommit(GitRepository repo, String revision) async {
  final id = await repo.revParse(revision);
  if (id == null) {
    throw GitUsage(
      "fatal: could not lookup commit '$revision'\n",
      exitCode: 128,
    );
  }
  final object = await repo.show(id.hex);
  if (object == null) {
    throw GitUsage(
      "fatal: could not lookup commit '$revision'\n",
      exitCode: 128,
    );
  }
  return const GitCommitCodec().decode(object.bytes);
}

String _joinParagraphs(List<String> parts) {
  final buffer = StringBuffer();
  for (final part in parts) {
    if (buffer.isNotEmpty) buffer.write('\n');
    buffer.write(part);
    if (!part.endsWith('\n')) buffer.write('\n');
  }
  return buffer.toString();
}

String _stripSpace(String input, {required bool stripComments}) {
  final body = input.endsWith('\n')
      ? _slice(input, 0, input.length - 1)
      : input;
  if (body.isEmpty) return '';
  final kept = <String>[];
  for (final raw in body.split('\n')) {
    final line = _trimRight(raw);
    if (stripComments && line.startsWith('#')) continue;
    kept.add(line);
  }
  var start = 0;
  while (start < kept.length && kept[start].isEmpty) {
    start++;
  }
  var end = kept.length;
  while (end > start && kept[end - 1].isEmpty) {
    end--;
  }
  if (start >= end) return '';
  final collapsed = <String>[];
  var blank = false;
  for (var index = start; index < end; index++) {
    final line = kept[index];
    if (line.isEmpty) {
      if (blank) continue;
      blank = true;
      collapsed.add(line);
      continue;
    }
    blank = false;
    collapsed.add(line);
  }
  return '${collapsed.join('\n')}\n';
}

String _trimRight(String line) {
  var end = line.length;
  final units = line.codeUnits;
  while (end > 0 && (units[end - 1] == 0x20 || units[end - 1] == 0x09)) {
    end--;
  }
  return end == line.length ? line : _slice(line, 0, end);
}

String _cutScissors(String input) {
  if (input.startsWith('$_scissorsMarker\n') || input == _scissorsMarker) {
    return '';
  }
  final pattern = '\n$_scissorsMarker\n';
  final at = input.indexOf(pattern);
  if (at < 0) return input;
  return _slice(input, 0, at + 1);
}

String _appendSignoff(String message, String line) {
  final lines = message.split('\n');
  for (final existing in lines) {
    if (existing == line) {
      return message.endsWith('\n') ? message : '$message\n';
    }
  }
  var text = message;
  if (text.isEmpty) return '$line\n';
  if (!text.endsWith('\n')) text = '$text\n';
  if (!text.endsWith('\n\n')) text = '$text\n';
  return '$text$line\n';
}

String _normalizeTrailer(String raw) {
  final colon = raw.indexOf(':');
  final equals = raw.indexOf('=');
  var cut = -1;
  if (colon >= 0 && (equals < 0 || colon <= equals)) cut = colon;
  if (equals >= 0 && (colon < 0 || equals < colon)) cut = equals;
  if (cut < 0) return '$raw:';
  final key = _slice(raw, 0, cut).trim();
  final value = _slice(raw, cut + 1, raw.length).trim();
  if (value.isEmpty) return '$key:';
  return '$key: $value';
}

String _appendTrailer(String message, String trailer) {
  var text = message;
  if (text.isEmpty) return '$trailer\n';
  if (!text.endsWith('\n')) text = '$text\n';
  if (_endsWithTrailer(text)) return '$text$trailer\n';
  if (!text.endsWith('\n\n')) text = '$text\n';
  return '$text$trailer\n';
}

bool _endsWithTrailer(String message) {
  final lines = message.split('\n');
  var last = '';
  for (final line in lines) {
    if (line.isNotEmpty) last = line;
  }
  final colon = last.indexOf(':');
  if (colon <= 0) return false;
  final key = _slice(last, 0, colon);
  if (key.isEmpty) return false;
  for (final unit in key.codeUnits) {
    final ok =
        (unit >= 0x41 && unit <= 0x5a) ||
        (unit >= 0x61 && unit <= 0x7a) ||
        (unit >= 0x30 && unit <= 0x39) ||
        unit == 0x2d;
    if (!ok) return false;
  }
  return true;
}

bool _messageIsEmpty(String message, {required bool verbatim}) {
  if (verbatim && message.isNotEmpty) return false;
  final body = message.endsWith('\n')
      ? _slice(message, 0, message.length - 1)
      : message;
  if (body.isEmpty) return true;
  for (final line in body.split('\n')) {
    if (line.trim().isEmpty) continue;
    if (line.startsWith('Signed-off-by: ')) continue;
    return false;
  }
  return true;
}

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

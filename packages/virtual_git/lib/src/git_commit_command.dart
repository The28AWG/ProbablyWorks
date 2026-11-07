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
part 'command/commit_index.dart';
part 'command/commit_message.dart';
part 'command/commit_summary.dart';

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

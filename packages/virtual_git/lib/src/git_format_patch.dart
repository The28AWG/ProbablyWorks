// ignore_for_file: avoid-substring
// Причина: темы, хеши и base85 режутся по байтам ASCII, как в git.
/// `git format-patch`: серия писем mbox из диапазона коммитов.
///
/// Неизвестная опция — код 129. Опция, которую апплет разобрал, но не может
/// выполнить (неверный режим, нет диапазона для range-diff), пишет `fatal`
/// и завершается с кодом 128, а не молчит.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:virtual_git/src/git_cli.dart';
import 'package:virtual_git/src/git_commit.dart';
import 'package:virtual_git/src/git_diff.dart';
import 'package:virtual_git/src/git_diff_codec.dart';
import 'package:virtual_git/src/git_log.dart';
import 'package:virtual_git/src/git_path.dart' as p;
import 'package:virtual_git/src/git_repository.dart';
import 'package:virtual_git/src/git_text_diff.dart';
import 'package:virtual_host/virtual_host.dart';

const _usage =
    'usage: git format-patch [<options>] [<since> | <revision-range>]';

const _emptyTree = '4b825dc642cb6eb9a060e54bf8d69288fbee4904';

const _mboxFromDate = 'Mon Sep 17 00:00:00 2001';

/// Версия в подписи и в MIME-границе. Совпадает с `git version` апплета.
const _versionMarker = '0.1.0';

const _defaultFilenameMax = 63;

const _coverModes = {'message', 'default', 'subject', 'auto', 'none'};

/// Собирает серию патчей и пишет её в stdout или в файлы.
Future<int> runFormatPatch(
  AppletIo io,
  List<String> args,
  List<({String key, String value})> config,
) async {
  final counted = _takeCount(args);
  _rejectUnknown(counted.args);
  final prepared = _prepareArgs(counted.args);
  final parsed = parseGitArgs(prepared, _formatPatchOptions, usage: _usage);
  final opts = _FpOptions(parsed, counted.maxCount, config, prepared);
  final repo = await _open(io);
  _validate(opts);

  final selected = await _selectCommits(repo, opts);
  if (selected.isEmpty) return 0;

  final commits = await _filterUpstream(repo, opts, selected);
  if (commits.isEmpty) return 0;
  if (opts.hasCreationFactor && opts.rangeDiff == null) {
    throw const GitUsage(
      "fatal: the option '--creation-factor' requires '--range-diff'\n",
      exitCode: 128,
    );
  }

  final showCover = _coverEnabled(opts, commits.length);
  if (!showCover &&
      commits.length > 1 &&
      (opts.rangeDiff != null || opts.interdiff != null)) {
    final flag = opts.rangeDiff != null ? '--range-diff' : '--interdiff';
    throw GitUsage(
      'fatal: $flag requires --cover-letter or single patch\n',
      exitCode: 128,
    );
  }
  final numbered = _numbered(opts, commits.length, cover: showCover);
  final total = opts.startNumber + commits.length - 1;
  final actor = _actor(io, config, committer: true);
  final signature = await _signatureText(io, repo, opts);
  final description = await _description(io, opts);
  final unix = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final paths = opts.paths.isEmpty ? null : opts.paths;

  final rendered = <_Mail>[];
  if (showCover) {
    rendered.add(
      await _cover(
        repo,
        opts,
        commits,
        actor: actor,
        numbered: numbered,
        total: total,
        description: description,
        signature: signature,
        unix: unix,
        paths: paths,
      ),
    );
  }
  for (var index = 0; index < commits.length; index++) {
    final number = opts.startNumber + index;
    rendered.add(
      await _patchMail(
        repo,
        opts,
        commits[index],
        actor: actor,
        number: number,
        total: total,
        numbered: numbered,
        signature: signature,
        unix: unix,
        paths: paths,
        baseOnThis: !showCover && index == 0,
        extrasOnThis: !showCover && commits.length == 1,
      ),
    );
  }
  _thread(rendered, opts);

  if (opts.stdout) {
    final buffer = StringBuffer();
    for (var index = 0; index < rendered.length; index++) {
      // Между письмами — пустая строка. После Interdiff/Range-diff git её
      // не вставляет: следующий From идёт сразу за последней строкой diff.
      final previous = index == 0 ? '' : rendered[index - 1].text;
      final glued =
          previous.contains('\nInterdiff:\n') ||
          previous.contains('\nRange-diff:\n');
      if (index > 0 && !glued) buffer.writeln();
      buffer.write(rendered[index].text);
    }
    io.stdout.writeText(buffer.toString());
    return 0;
  }

  final outDir = opts.outputDirectory;
  if (outDir != null) {
    final dir = outDir.startsWith('/') ? outDir : p.join(io.cwd, outDir);
    await io.fs.mkdir(dir, recursive: true);
  }
  for (final mail in rendered) {
    final full = outDir == null
        ? p.join(io.cwd, mail.fileName)
        : p.join(io.cwd, outDir, mail.fileName);
    await io.fs.writeBytes(full, Uint8List.fromList(utf8.encode(mail.text)));
    if (!opts.quiet) {
      final listed = outDir == null
          ? mail.fileName
          : p.join(outDir, mail.fileName);
      io.stdout.writeText('$listed\n');
    }
  }
  return 0;
}

final class _Mail {
  _Mail({required this.fileName, required this.text, required this.messageId});

  final String fileName;
  String text;

  /// Уже с угловыми скобками, либо null, пока threading не включён.
  String? messageId;
}

final class _FpOptions {
  _FpOptions(this.parsed, this.maxCount, this.config, this.rawArgs);

  final GitInvocation parsed;
  final int? maxCount;
  final List<({String key, String value})> config;
  final List<String> rawArgs;

  bool get stdout => parsed.has('stdout');
  bool get quiet => parsed.has('quiet');
  bool get keepSubject => parsed.has('keep-subject');
  bool get zeroCommit => parsed.has('zero-commit');
  bool get signoff => parsed.has('signoff');
  bool get numberedFiles => parsed.has('numbered-files');
  bool get forceInBodyFrom => parsed.has('force-in-body-from');
  bool get ignoreUpstream => parsed.has('ignore-if-in-upstream');
  bool get noStat => parsed.has('no-stat');
  bool get gitBinary => !parsed.has('no-binary');
  bool get progress => parsed.has('progress');

  /// null — авто: несколько патчей или cover.
  bool? get numberedExplicit {
    if (parsed.has('no-numbered')) return false;
    if (parsed.has('numbered')) return true;
    return null;
  }

  /// null — авто: range-diff/interdiff при нескольких патчах.
  bool? get coverExplicit {
    if (parsed.has('no-cover-letter')) return false;
    if (parsed.has('cover-letter')) return true;
    return null;
  }

  String? get outputDirectory => parsed.value('output-directory');
  String get suffix => parsed.value('suffix') ?? '.patch';
  int get startNumber => int.tryParse(parsed.value('start-number') ?? '') ?? 1;
  int get filenameMax =>
      int.tryParse(parsed.value('filename-max-length') ?? '') ??
      int.tryParse(_cfg('format.filenameMaxLength') ?? '') ??
      _defaultFilenameMax;

  int? get reroll {
    if (!parsed.has('reroll-count')) return null;
    return int.tryParse(parsed.value('reroll-count') ?? '') ?? 0;
  }

  String get subjectPrefix =>
      parsed.value('subject-prefix') ?? _cfg('format.subjectPrefix') ?? 'PATCH';

  String get rfc => parsed.has('rfc') ? (parsed.value('rfc') ?? '') : '';

  String? get fromIdent => parsed.has('from') ? parsed.value('from') : null;

  String? get threadStyle =>
      parsed.has('thread') ? parsed.value('thread') : null;

  String? get inReplyTo => parsed.value('in-reply-to');

  String? get base => parsed.has('base') ? parsed.value('base') : null;

  String? get interdiff => parsed.value('interdiff');

  String? get rangeDiff => parsed.value('range-diff');

  int get creationFactor =>
      int.tryParse(parsed.value('creation-factor') ?? '') ?? 60;

  bool get hasCreationFactor => parsed.has('creation-factor');

  String? get coverMode => parsed.value('cover-from-description');

  String? get descriptionFile => parsed.value('description-file');

  String? get attach =>
      parsed.has('attach') ? (parsed.value('attach') ?? '') : null;

  String? get inline =>
      parsed.has('inline') ? (parsed.value('inline') ?? '') : null;

  bool get hasSignatureFlag => parsed.has('signature');
  String? get signatureValue => parsed.value('signature');
  String? get signatureFile => parsed.value('signature-file');
  bool get noSignature => parsed.has('no-signature');

  List<String> get tos => parsed.valuesOf('to');
  List<String> get ccs => parsed.valuesOf('cc');
  List<String> get extraHeaders => parsed.valuesOf('add-header');

  List<String> get paths {
    if (!parsed.separated) return const [];
    final sep = rawArgs.lastIndexOf('--');
    if (sep < 0 || sep + 1 >= rawArgs.length) return const [];
    return rawArgs.sublist(sep + 1);
  }

  List<String> get revisions {
    if (!parsed.separated) return parsed.operands;
    final tail = paths.length;
    if (tail >= parsed.operands.length) return const [];
    return parsed.operands.sublist(0, parsed.operands.length - tail);
  }

  String? _cfg(String key) {
    String? found;
    for (final item in config) {
      if (item.key == key) found = item.value;
    }
    return found;
  }
}

const _formatPatchOptions = <GitOption>[
  GitOption('numbered', short: 'n'),
  GitOption('no-numbered', short: 'N'),
  GitOption('signoff', short: 's'),
  GitOption('stdout'),
  GitOption('no-stdout'),
  GitOption('cover-letter'),
  GitOption('no-cover-letter'),
  GitOption('numbered-files'),
  GitOption('suffix', valued: true),
  GitOption('start-number', valued: true),
  GitOption('reroll-count', short: 'v', valued: true),
  GitOption('filename-max-length', valued: true),
  GitOption('rfc', valued: true, optional: true),
  GitOption('cover-from-description', valued: true),
  GitOption('description-file', valued: true),
  GitOption('subject-prefix', valued: true),
  GitOption('output-directory', short: 'o', valued: true),
  GitOption('keep-subject', short: 'k'),
  GitOption('no-binary'),
  GitOption('binary'),
  GitOption('zero-commit'),
  GitOption('ignore-if-in-upstream'),
  GitOption('no-stat', short: 'p'),
  GitOption('add-header', valued: true),
  GitOption('to', valued: true),
  GitOption('cc', valued: true),
  GitOption('from', valued: true, optional: true),
  GitOption('in-reply-to', valued: true),
  GitOption('attach', valued: true, optional: true),
  GitOption('inline', valued: true, optional: true),
  GitOption('thread', valued: true, optional: true),
  GitOption('signature', valued: true),
  GitOption('no-signature'),
  GitOption('signature-file', valued: true),
  GitOption('base', valued: true),
  GitOption('quiet', short: 'q'),
  GitOption('progress'),
  GitOption('interdiff', valued: true),
  GitOption('range-diff', valued: true),
  GitOption('creation-factor', valued: true),
  GitOption('force-in-body-from'),
];

/// Неизвестное длинное имя — `fatal: unrecognized argument` и код 128,
/// как у `git format-patch`, а не общий `error: unknown option` (129).
void _rejectUnknown(List<String> args) {
  final known = <String>{for (final option in _formatPatchOptions) option.name};
  for (final arg in args) {
    if (!arg.startsWith('--') || arg == '--') continue;
    final body = arg.substring(2);
    final eq = body.indexOf('=');
    final name = eq < 0 ? body : body.substring(0, eq);
    if (known.contains(name)) continue;
    if (name.startsWith('no-') && known.contains(name.substring(3))) continue;
    throw GitUsage('fatal: unrecognized argument: --$name\n', exitCode: 128);
  }
}

({List<String> args, int? maxCount}) _takeCount(List<String> args) {
  int? maxCount;
  final kept = <String>[];
  for (final arg in args) {
    final digit = RegExp(r'^-(\d+)$').firstMatch(arg);
    if (digit != null) {
      maxCount = int.parse(digit.group(1)!);
      continue;
    }
    kept.add(arg);
  }
  return (args: kept, maxCount: maxCount);
}

/// `--no-имя` для флагов и значений: побеждает последнее вхождение.
/// Голый `--rfc` / `--thread` / `--from` получает значение по умолчанию,
/// чтобы отличить его от `--rfc=` (пустая строка).
List<String> _prepareArgs(List<String> args) {
  const single = {
    'suffix',
    'signature',
    'signature-file',
    'from',
    'attach',
    'inline',
    'thread',
    'rfc',
    'base',
    'in-reply-to',
    'interdiff',
    'range-diff',
    'creation-factor',
    'start-number',
    'filename-max-length',
    'reroll-count',
    'cover-from-description',
    'description-file',
    'subject-prefix',
    'output-directory',
    'stdout',
    'cover-letter',
    'numbered-files',
    'keep-subject',
    'zero-commit',
    'ignore-if-in-upstream',
    'quiet',
    'progress',
    'force-in-body-from',
    'signoff',
    'numbered',
    'binary',
  };
  const repeatable = {'to', 'cc', 'add-header'};

  final lastNeg = <String, int>{};
  final lastPos = <String, int>{};
  for (var index = 0; index < args.length; index++) {
    final name = _longName(args[index]);
    if (name == null) continue;
    if (name.startsWith('no-')) {
      final base = name.substring(3);
      if (single.contains(base) || repeatable.contains(base)) {
        lastNeg[base] = index;
      }
      continue;
    }
    if (single.contains(name) || repeatable.contains(name)) {
      lastPos[name] = index;
    }
  }

  // Эти `--no-*` — отдельные опции парсера, а не «выключить положительный флаг».
  // Их отсутствие значило бы значение по умолчанию (подпись, stat, binary).
  const keepAsOption = {
    'no-binary',
    'no-numbered',
    'no-stat',
    'no-signature',
    'no-cover-letter',
    'no-stdout',
  };
  final kept = <String>[];
  for (var index = 0; index < args.length; index++) {
    final arg = args[index];
    final name = _longName(arg);
    if (name != null && keepAsOption.contains(name)) {
      final positive = name.substring(3);
      final negAt = lastNeg[positive];
      final posAt = lastPos[positive];
      if (posAt != null && negAt != null && posAt > negAt) continue;
      kept.add(arg);
      continue;
    }
    if (name != null && name.startsWith('no-')) {
      final base = name.substring(3);
      if (single.contains(base) || repeatable.contains(base)) continue;
    }
    if (name != null && (single.contains(name) || repeatable.contains(name))) {
      final neg = lastNeg[name];
      final pos = lastPos[name];
      if (neg != null && (pos == null || pos < neg)) continue;
      if (neg != null && index < neg) continue;
    }
    kept.add(_defaultOptional(arg));
  }
  return kept;
}

String? _longName(String arg) {
  if (!arg.startsWith('--') || arg == '--') return null;
  final body = arg.substring(2);
  final eq = body.indexOf('=');
  return eq < 0 ? body : body.substring(0, eq);
}

String _defaultOptional(String arg) {
  if (arg == '--rfc') return '--rfc=RFC';
  if (arg == '--thread') return '--thread=shallow';
  if (arg == '--from') return '--from=__COMMITTER__';
  if (arg == '--attach') return '--attach=__DEFAULT__';
  if (arg == '--inline') return '--inline=__DEFAULT__';
  return arg;
}

void _validate(_FpOptions opts) {
  final mode = opts.coverMode;
  if (mode != null && !_coverModes.contains(mode)) {
    throw GitUsage(
      'fatal: $mode: invalid cover from description mode\n',
      exitCode: 128,
    );
  }
  final thread = opts.threadStyle;
  if (thread != null && thread != 'shallow' && thread != 'deep') {
    throw const GitUsage('', exitCode: 129);
  }
  if (opts.ignoreUpstream && opts.maxCount != null) {
    throw const GitUsage('fatal: need exactly one range\n', exitCode: 128);
  }
  if (opts.attach != null && opts.inline != null) {
    throw const GitUsage(
      'fatal: --attach and --inline are mutually exclusive\n',
      exitCode: 128,
    );
  }
  // progress печатается только на tty. У виртуального stderr его нет,
  // поэтому флаг принимается и молчит — как git вне терминала.
  if (opts.progress) return;
}

Future<GitRepository> _open(AppletIo io) async {
  final repository = await GitRepository.discover(io.cwd);
  if (repository == null) {
    throw const GitUsage(
      'fatal: not a git repository (or any of the parent directories): .git\n',
      exitCode: 128,
    );
  }
  return repository;
}

Future<List<GitLogEntry>> _selectCommits(
  GitRepository repo,
  _FpOptions opts,
) async {
  final revs = opts.revisions;
  if (revs.length > 1) {
    throw const GitUsage(
      'fatal: multiple revision arguments are not supported in virtual git\n',
      exitCode: 128,
    );
  }
  if (revs.isEmpty) {
    await _requireCommits(repo);
    if (opts.maxCount == null || opts.maxCount == 0) return const [];
    return _last(repo, 'HEAD', opts.maxCount!);
  }
  final spec = revs.single;
  if (spec.contains('...')) {
    return _dotDot(repo, spec.replaceAll('...', '..'), opts.maxCount);
  }
  if (spec.contains('..')) {
    return _dotDot(repo, spec, opts.maxCount);
  }
  await _requireRevision(repo, spec);
  if (opts.maxCount != null) return _last(repo, spec, opts.maxCount!);
  final list = await repo.revListAncestryPath(
    base: spec,
    tip: 'HEAD',
    excludeMerges: false,
  );
  return _trimCount(list, opts.maxCount);
}

Future<List<GitLogEntry>> _dotDot(
  GitRepository repo,
  String spec,
  int? maxCount,
) async {
  final idx = spec.indexOf('..');
  var base = spec.substring(0, idx);
  var tip = spec.substring(idx + 2);
  if (tip.isEmpty) tip = 'HEAD';
  if (base.isEmpty) {
    await _requireRevision(repo, tip);
    final all = await repo.log(tip);
    return _trimCount(all.reversed.toList(), maxCount);
  }
  await _requireRevision(repo, base);
  await _requireRevision(repo, tip);
  final list = await repo.revListAncestryPath(
    base: base,
    tip: tip,
    excludeMerges: false,
  );
  return _trimCount(list, maxCount);
}

Future<List<GitLogEntry>> _last(
  GitRepository repo,
  String revision,
  int count,
) async {
  final history = await repo.log(revision, maxCount: count);
  return history.reversed.toList();
}

List<GitLogEntry> _trimCount(List<GitLogEntry> oldestFirst, int? maxCount) {
  if (maxCount == null || oldestFirst.length <= maxCount) return oldestFirst;
  return oldestFirst.sublist(oldestFirst.length - maxCount);
}

Future<void> _requireCommits(GitRepository repo) async {
  if (await repo.revParse('HEAD') != null) return;
  final head = await repo.readReference('HEAD');
  final target = head?.targetReferenceName;
  final name = target != null && target.startsWith('refs/heads/')
      ? target.substring('refs/heads/'.length)
      : 'HEAD';
  throw GitUsage(
    "fatal: your current branch '$name' does not have any commits yet\n",
    exitCode: 128,
  );
}

Future<void> _requireRevision(GitRepository repo, String revision) async {
  final id = await repo.revParse(revision);
  if (id != null) return;
  throw GitUsage(
    "fatal: ambiguous argument '$revision': unknown revision or path not in the working tree.\n"
    "Use '--' to separate paths from revisions, like this:\n"
    "'git <command> [<revision>...] -- [<file>...]'\n",
    exitCode: 128,
  );
}

Future<List<GitLogEntry>> _filterUpstream(
  GitRepository repo,
  _FpOptions opts,
  List<GitLogEntry> commits,
) async {
  if (!opts.ignoreUpstream) {
    if (opts.paths.isEmpty) return commits;
    return _dropUntouched(repo, commits, opts.paths);
  }
  final upstream = opts.revisions.single;
  final known = await _upstreamPatchIds(repo, upstream);
  final kept = <GitLogEntry>[];
  for (final entry in commits) {
    final diff = await _diffOf(repo, entry, null);
    final id = _patchFingerprint(_diffText(diff, gitBinary: false));
    if (known.contains(id)) continue;
    if (opts.paths.isNotEmpty) {
      final limited = await _diffOf(repo, entry, opts.paths);
      if (limited.isEmpty) continue;
    }
    kept.add(entry);
  }
  return kept;
}

Future<List<GitLogEntry>> _dropUntouched(
  GitRepository repo,
  List<GitLogEntry> commits,
  List<String> paths,
) async {
  final kept = <GitLogEntry>[];
  for (final entry in commits) {
    final diff = await _diffOf(repo, entry, paths);
    if (diff.isNotEmpty) kept.add(entry);
  }
  return kept;
}

Future<Set<String>> _upstreamPatchIds(
  GitRepository repo,
  String upstream,
) async {
  final history = await repo.log(upstream);
  final ids = <String>{};
  for (final entry in history) {
    final diff = await _diffOf(repo, entry, null);
    ids.add(_patchFingerprint(_diffText(diff, gitBinary: false)));
  }
  return ids;
}

/// Отпечаток diff без index и номеров строк: так cherry-pick совпадает
/// с исходным коммитом, даже если хеш другой.
String _patchFingerprint(String diff) {
  final lines = <String>[];
  for (final line in diff.split('\n')) {
    if (line.startsWith('index ')) continue;
    if (line.startsWith('diff --git ')) continue;
    if (line.startsWith('new file mode') ||
        line.startsWith('deleted file mode') ||
        line.startsWith('old mode ') ||
        line.startsWith('new mode ') ||
        line.startsWith('--- ') ||
        line.startsWith('+++ ')) {
      continue;
    }
    if (line.startsWith('@@')) {
      lines.add('@@');
      continue;
    }
    lines.add(line);
  }
  return lines.join('\n');
}

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

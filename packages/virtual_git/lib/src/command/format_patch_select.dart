// ignore_for_file: avoid-substring
// Причина: темы, хеши и base85 режутся по байтам ASCII, как в git.
part of '../git_format_patch.dart';

/// Опции format-patch и выбор коммитов серии.
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

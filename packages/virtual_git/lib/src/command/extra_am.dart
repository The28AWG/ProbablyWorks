// ignore_for_file: avoid-substring
// Причина: короткие хеши и fanout LFS режутся по фиксированной длине, как в git.
part of '../git_extra_commands.dart';

/// git am: разбор mbox и состояние `.git/rebase-apply`.
Future<int> _am(
  AppletIo io,
  List<String> args,
  List<({String key, String value})> config,
) async {
  const usage =
      'usage: git am [<options>] [(<mbox> | <Maildir>)...]\n'
      '   or: git am [<options>] (--continue | --skip | --abort)\n';
  final parsed = parseGitArgs(args, const [
    GitOption('interactive', short: 'i'),
    GitOption('no-verify', short: 'n'),
    GitOption('verify'),
    GitOption('3way', short: '3'),
    GitOption('quiet', short: 'q'),
    GitOption('signoff', short: 's'),
    GitOption('utf8', short: 'u', negatable: true),
    GitOption('keep', short: 'k'),
    GitOption('keep-non-patch'),
    GitOption('message-id'),
    GitOption('keep-cr'),
    GitOption('scissors', short: 'c'),
    GitOption('quoted-cr', valued: true),
    GitOption('whitespace', valued: true),
    GitOption('ignore-space-change'),
    GitOption('ignore-whitespace'),
    GitOption('directory', valued: true),
    GitOption('exclude', valued: true),
    GitOption('include', valued: true),
    GitOption('C', short: 'C', valued: true),
    GitOption('p', short: 'p', valued: true),
    GitOption('patch-format', valued: true),
    GitOption('reject'),
    GitOption('resolvemsg', valued: true),
    GitOption('continue'),
    GitOption('resolved', short: 'r'),
    GitOption('skip'),
    GitOption('abort'),
    GitOption('quit'),
    GitOption('show-current-patch', valued: true, optional: true),
    GitOption('retry'),
    GitOption('allow-empty'),
    GitOption('committer-date-is-author-date'),
    GitOption('ignore-date'),
    GitOption('rerere-autoupdate'),
    GitOption('gpg-sign', short: 'S', valued: true, optional: true),
    GitOption('empty', valued: true),
  ], usage: usage);
  final repo = await _repo(io);

  if (parsed.has('interactive')) {
    throw GitUsage(
      'fatal: interactive mode is not supported in virtual git\n',
      exitCode: 128,
    );
  }
  if (parsed.has('gpg-sign')) {
    throw GitUsage(
      'fatal: gpg signing is not supported in virtual git\n',
      exitCode: 128,
    );
  }
  if (parsed.has('rerere-autoupdate')) {
    throw GitUsage(
      'fatal: rerere is not supported in virtual git\n',
      exitCode: 128,
    );
  }
  if (parsed.has('no-verify') || parsed.has('verify')) {
    throw GitUsage(
      'fatal: applypatch hooks are not supported in virtual git\n',
      exitCode: 128,
    );
  }

  final patchFormat = parsed.value('patch-format');
  if (patchFormat != null && patchFormat != 'mbox') {
    throw GitUsage(
      "fatal: unsupported patch format: '$patchFormat'\n",
      exitCode: 128,
    );
  }

  final emptyMode = parsed.value('empty') ?? 'stop';
  if (emptyMode != 'stop' && emptyMode != 'drop' && emptyMode != 'keep') {
    throw GitUsage(
      "fatal: invalid mode '$emptyMode' for --empty\n",
      exitCode: 128,
    );
  }

  if (parsed.has('continue') || parsed.has('resolved')) {
    return _amContinue(io, repo, config, parsed);
  }
  if (parsed.has('skip')) {
    return _amSkip(io, repo);
  }
  if (parsed.has('abort')) {
    return _amAbort(io, repo);
  }
  if (parsed.has('quit')) {
    return _amQuit(io, repo);
  }
  if (parsed.has('retry')) {
    return _amRetry(io, repo, config, parsed);
  }
  final showPatch = parsed.value('show-current-patch');
  if (parsed.has('show-current-patch')) {
    return _amShowCurrentPatch(
      io,
      repo,
      diff: showPatch == 'diff' || showPatch == '',
    );
  }

  if (parsed.operands.isEmpty) {
    throw GitUsage('$usage\n');
  }
  if (await _amRebaseApplyExists(repo)) {
    io.stderr.writeText(
      'fatal: previous rebase directory .git/rebase-apply still exists but mbox given.\n',
    );
    return 128;
  }

  for (final operand in parsed.operands) {
    final path = operand.startsWith('/') ? operand : '${io.cwd}/$operand';
    final bytes = await io.fs.readBytes(path);
    var text = utf8.decode(bytes, allowMalformed: true);
    if (!parsed.has('keep-cr')) {
      text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    }
    final messages = splitMboxMessages(text);
    for (final message in messages) {
      final code = await _amApplyOneMailboxMessage(
        io,
        repo,
        config,
        parsed,
        message,
        emptyMode: emptyMode,
      );
      if (code != 0) return code;
    }
  }
  return 0;
}

String _amRebaseApplyDir(GitRepository repo) =>
    p.join(repo.gitDirectoryPath, 'rebase-apply');

Future<bool> _amRebaseApplyExists(GitRepository repo) async =>
    await Directory(_amRebaseApplyDir(repo)).exists();

Future<void> _amClearRebaseApply(GitRepository repo) async {
  final dir = Directory(_amRebaseApplyDir(repo));
  if (await dir.exists()) {
    await dir.delete(recursive: true);
  }
}

Future<void> _amWriteRebaseApplyFile(
  GitRepository repo,
  String name,
  String content,
) async {
  final file = File(p.join(_amRebaseApplyDir(repo), name));
  await file.parent.create(recursive: true);
  await file.writeAsString(content.endsWith('\n') ? content : '$content\n');
}

Future<String?> _amReadRebaseApplyFile(GitRepository repo, String name) async {
  final file = File(p.join(_amRebaseApplyDir(repo), name));
  if (!await file.exists()) return null;
  return file.readAsString();
}

Future<int> _amAbort(AppletIo io, GitRepository repo) async {
  if (!await _amRebaseApplyExists(repo)) {
    io.stderr.writeText('fatal: No patch am in progress\n');
    return 128;
  }
  final abortSafety = await _amReadRebaseApplyFile(repo, 'abort-safety');
  final headId =
      await repo.revParse('HEAD') ??
      (abortSafety == null ? null : GitObjectId.fromHex(abortSafety.trim()));
  if (headId != null) {
    await repo.reset(headId.hex, mode: GitResetMode.hard, reflogActor: null);
  }
  await _amClearRebaseApply(repo);
  final orig = File(repo.origHeadFilePath);
  if (await orig.exists()) await orig.delete();
  return 0;
}

Future<int> _amQuit(AppletIo io, GitRepository repo) async {
  if (!await _amRebaseApplyExists(repo)) {
    io.stderr.writeText('fatal: No patch am in progress\n');
    return 128;
  }
  await _amClearRebaseApply(repo);
  final orig = File(repo.origHeadFilePath);
  if (await orig.exists()) await orig.delete();
  return 0;
}

Future<int> _amShowCurrentPatch(
  AppletIo io,
  GitRepository repo, {
  required bool diff,
}) async {
  if (!await _amRebaseApplyExists(repo)) {
    return 128;
  }
  final patchText = await _amReadRebaseApplyFile(repo, 'patch');
  if (patchText == null) {
    return 128;
  }
  if (diff) {
    final start = patchText.indexOf('diff --git ');
    final body = start >= 0 ? patchText.substring(start) : patchText;
    io.stdout.writeText(body);
    if (!body.endsWith('\n')) io.stdout.writeText('\n');
    return 0;
  }
  io.stdout.writeText(patchText);
  if (!patchText.endsWith('\n')) io.stdout.writeText('\n');
  return 0;
}

Future<int> _amRetry(
  AppletIo io,
  GitRepository repo,
  List<({String key, String value})> config,
  GitInvocation parsed,
) async {
  if (!await _amRebaseApplyExists(repo)) {
    io.stderr.writeText('fatal: No patch am in progress\n');
    return 128;
  }
  final patchText = await _amReadRebaseApplyFile(repo, 'patch');
  if (patchText == null) {
    await _amClearRebaseApply(repo);
    io.stderr.writeText('fatal: patch state corrupted\n');
    return 128;
  }
  final message = await _amReadRebaseApplyFile(repo, '0001');
  if (message == null) {
    await _amClearRebaseApply(repo);
    io.stderr.writeText('fatal: patch state corrupted\n');
    return 128;
  }
  return _amApplyParsedMessage(
    io,
    repo,
    config,
    parsed,
    message,
    patchText,
    resumeAfterConflict: true,
  );
}

Future<int> _amSkip(AppletIo io, GitRepository repo) async {
  if (!await _amRebaseApplyExists(repo)) {
    io.stderr.writeText('fatal: No patch am in progress\n');
    return 128;
  }
  await _amClearRebaseApply(repo);
  final orig = File(repo.origHeadFilePath);
  if (await orig.exists()) await orig.delete();
  return 0;
}

Future<int> _amContinue(
  AppletIo io,
  GitRepository repo,
  List<({String key, String value})> config,
  GitInvocation parsed,
) async {
  if (!await _amRebaseApplyExists(repo)) {
    io.stderr.writeText('fatal: No patch am in progress\n');
    return 128;
  }
  final resume = await _AmResumeState.load(repo);
  if (resume == null) {
    await _amClearRebaseApply(repo);
    io.stderr.writeText('fatal: patch state corrupted\n');
    return 128;
  }
  final opts = _AmEffectiveOptions(parsed: parsed, resume: resume);
  final invalidQuotedContinue = _amValidateQuotedCr(opts.quotedCrEffective);
  if (invalidQuotedContinue != null) {
    io.stderr.writeText(invalidQuotedContinue);
    return 128;
  }
  final wsRawContinue = opts.wsPolicyRaw;
  if (wsRawContinue != null && wsRawContinue.trim().isNotEmpty) {
    if (parseWhitespacePolicy(wsRawContinue.trim()) == null) {
      io.stderr.writeText('fatal: Invalid whitespace option: $wsRawContinue\n');
      return 128;
    }
  }

  final patchText = await _amReadRebaseApplyFile(repo, 'patch');
  final message = await _amReadRebaseApplyFile(repo, '0001');
  if (patchText == null || message == null) {
    await _amClearRebaseApply(repo);
    io.stderr.writeText('fatal: patch state corrupted\n');
    return 128;
  }
  final diffStart = patchText.indexOf('diff --git ');
  final patchBody = diffStart >= 0 ? patchText.substring(diffStart) : patchText;
  if (!_amPatchHasApplicableHunks(patchBody)) {
    final subjectLine =
        await _amReadRebaseApplyFile(repo, 'final-commit') ??
        _amExtractSubjectFromMbox(message);
    io.stderr.writeText(
      'hint: When you have resolved this problem, run "git am --continue".\n',
    );
    io.stderr.writeText(
      'hint: If you prefer to skip this patch, run "git am --skip" instead.\n',
    );
    io.stderr.writeText(
      'hint: To restore the original branch and stop patching, run "git am --abort".\n',
    );
    io.stderr.writeText(
      'hint: Disable this message with "git config set advice.mergeConflict false"\n',
    );
    io.stderr.writeText('Applying: $subjectLine\n');
    io.stderr.writeText("No changes - did you forget to use 'git add'?\n");
    io.stderr.writeText(
      'If there is nothing left to stage, chances are that something else\n',
    );
    io.stderr.writeText(
      'already introduced the same changes; you might want to skip this patch.\n',
    );
    return 128;
  }
  final apply = await repo.applyPatch(
    patchBody,
    threeWay: opts.threeway,
    reject: opts.reject,
    stripPathSegments: opts.stripPathSegments,
    whitespaceMode: opts.applyWhitespaceMode,
    whitespacePolicy: opts.applyWhitespacePolicy,
    includePaths: _amPathSet(parsed, 'include'),
    excludePaths: _amPathSet(parsed, 'exclude'),
    applyContextLines: opts.applyContextLines,
    applyDirectoryPrefix: opts.applyDirectoryPrefix,
    patchFileLabel: _amPatchFileLabel(),
  );
  _amEmitApplyStderr(io, apply, quiet: opts.quiet);
  if (!apply.success) {
    if (apply.whitespaceBlocked) {
      await _amPersistRebaseApplyForFailure(
        io,
        repo,
        config,
        fullMessage: message,
        subjectLine:
            await _amReadRebaseApplyFile(repo, 'final-commit') ??
            _amExtractSubjectFromMbox(message),
        opts: opts,
      );
      _amPrintStandardAmHints(io);
      final subjectLine =
          await _amReadRebaseApplyFile(repo, 'final-commit') ??
          _amExtractSubjectFromMbox(message);
      if (!opts.quiet) {
        io.stderr.writeText('Applying: $subjectLine\n');
        io.stderr.writeText(
          "${parsed.value('resolvemsg') ?? 'Patch failed at 0001 $subjectLine'}\n",
        );
      }
      return 128;
    }
    if (apply.hasConflicts) {
      final conflictPath = apply.files
          .firstWhere((f) => f.conflict, orElse: () => apply.files.first)
          .path;
      if (!opts.quiet) {
        io.stderr.writeText('error: patch failed: $conflictPath\n');
        io.stderr.writeText('error: $conflictPath: patch does not apply\n');
      }
      _amPrintStandardAmHints(io);
      final subjectLine =
          await _amReadRebaseApplyFile(repo, 'final-commit') ??
          _amExtractSubjectFromMbox(message);
      if (!opts.quiet) {
        io.stderr.writeText('Applying: $subjectLine\n');
        io.stderr.writeText(
          "${parsed.value('resolvemsg') ?? 'Patch failed at 0001 $subjectLine'}\n",
        );
      }
      return 128;
    }
    return 128;
  }
  final paths = _amPathsFromPatch(patchBody);
  if (paths.isNotEmpty) await repo.add(paths);

  final subjectLine =
      await _amReadRebaseApplyFile(repo, 'final-commit') ??
      _amExtractSubjectFromMbox(message);
  var bodyText = _amMessageBodyAfterSubject(message, subjectLine);
  bodyText = applyScissorsToBody(bodyText, scissors: opts.scissors);
  bodyText = _stripAmDiffFooter(bodyText);
  if (opts.signoff) {
    final signer = _signature(io, config);
    bodyText = _amAppendSignoff(bodyText, signer);
  }
  final headers = parseMailHeaders(message);
  final msg = _amBuildCommitMessage(
    subjectLine: subjectLine,
    bodyText: bodyText,
    headers: headers,
    opts: opts,
  );
  final author = await _amAuthorFromScript(repo) ?? _signature(io, config);
  final committer = _amCommitterFromEffectiveOptions(
    io,
    config,
    opts,
    authorFallback: author,
  );
  await repo.commit(
    author: author,
    committer: committer,
    message: msg,
    allowEmpty: false,
  );
  if (!opts.quiet) {
    io.stdout.writeText('Applying: $subjectLine\n');
  }
  await _amClearRebaseApply(repo);
  final orig = File(repo.origHeadFilePath);
  if (await orig.exists()) await orig.delete();
  return 0;
}

Set<String>? _amPathSet(GitInvocation parsed, String name) {
  final values = parsed.valuesOf(name);
  if (values.isEmpty) return null;
  return values.toSet();
}

List<String> _amPathsFromPatch(String patchBody) {
  final paths = <String>[];
  final seen = <String>{};
  for (final match in RegExp(
    r'^diff --git a/(.+?) b/(.+?)$',
    multiLine: true,
  ).allMatches(patchBody)) {
    final path = match.group(2)!;
    if (seen.add(path)) paths.add(path);
  }
  return paths;
}

/// Каталог патча в состоянии `am` — как у git в сообщениях про пробелы.
String _amPatchFileLabel() => '.git/rebase-apply/patch';

GitApplyWhitespaceMode _amWhitespaceModeForFlags({
  required bool ignoreSpaceChange,
  required bool ignoreWhitespace,
}) {
  if (ignoreWhitespace) {
    return GitApplyWhitespaceMode.ignoreAllWhitespace;
  }
  if (ignoreSpaceChange) {
    return GitApplyWhitespaceMode.ignoreSpaceChange;
  }
  return GitApplyWhitespaceMode.exact;
}

void _amEmitApplyStderr(
  AppletIo io,
  GitApplyResult apply, {
  required bool quiet,
}) {
  if (quiet || apply.stderrLines.isEmpty) return;
  for (final line in apply.stderrLines) {
    io.stderr.writeText('$line\n');
  }
}

/// Флаги `git am`, сохранённые в `.git/rebase-apply` для `--continue` / `--retry`.
final class _AmResumeState {
  const _AmResumeState({
    required this.quiet,
    required this.signoff,
    required this.utf8,
    required this.threeway,
    required this.scissors,
    required this.keep,
    required this.messageId,
    required this.keepNonPatch,
    required this.allowEmpty,
    required this.committerDateIsAuthorDate,
    required this.ignoreDate,
    required this.ignoreSpaceChange,
    required this.ignoreWhitespace,
    required this.wsPolicyRaw,
    required this.reject,
    required this.quotedCr,
  });

  final bool quiet;
  final bool signoff;
  final bool utf8;
  final bool threeway;
  final bool scissors;
  final bool keep;
  final bool messageId;
  final bool keepNonPatch;
  final bool allowEmpty;
  final bool committerDateIsAuthorDate;
  final bool ignoreDate;
  final bool ignoreSpaceChange;
  final bool ignoreWhitespace;
  final String wsPolicyRaw;
  final bool reject;
  final String quotedCr;

  static Future<_AmResumeState?> load(GitRepository repo) async {
    final quiet = await _amReadRebaseApplyFile(repo, 'quiet');
    if (quiet == null) return null;
    Future<bool> flag(String name) async =>
        (await _amReadRebaseApplyFile(repo, name))?.trim() == 't';
    return _AmResumeState(
      quiet: quiet.trim() == 't',
      signoff: await flag('sign'),
      utf8: await flag('utf8'),
      threeway: await flag('threeway'),
      scissors: await flag('scissors'),
      keep: await flag('keep'),
      messageId: await flag('messageid'),
      keepNonPatch: await flag('keep-non-patch'),
      allowEmpty: await flag('allow-empty'),
      committerDateIsAuthorDate: await flag('cda'),
      ignoreDate: await flag('idate'),
      ignoreSpaceChange: await flag('isc'),
      ignoreWhitespace: await flag('iw'),
      wsPolicyRaw:
          (await _amReadRebaseApplyFile(repo, 'ws-policy'))?.trim() ?? 'warn',
      reject: await flag('reject'),
      quotedCr: (await _amReadRebaseApplyFile(repo, 'qc'))?.trim() ?? 'warn',
    );
  }
}

/// Эффективные опции: CLI при `am` заново, иначе значения из [resume] (как у git).
final class _AmEffectiveOptions {
  _AmEffectiveOptions({required GitInvocation parsed, _AmResumeState? resume})
    : _p = parsed,
      _r = resume;

  final GitInvocation _p;
  final _AmResumeState? _r;

  bool get quiet => _p.has('quiet') || (_r?.quiet ?? false);

  bool get signoff => _p.has('signoff') || (_r?.signoff ?? false);

  /// Как у git: без флага mailinfo перекодирует в UTF-8, `--no-utf8` выключает.
  ///
  /// Явный `--utf8` и отрицание важнее значения, сохранённого для `--continue`.
  bool get utf8 {
    if (_p.isNegated('utf8')) return false;
    if (_p.has('utf8')) return true;
    return _r?.utf8 ?? true;
  }

  bool get threeway => _p.has('3way') || (_r?.threeway ?? false);

  bool get scissors => _p.has('scissors') || (_r?.scissors ?? false);

  bool get keep => _p.has('keep') || (_r?.keep ?? false);

  bool get messageId => _p.has('message-id') || (_r?.messageId ?? false);

  bool get keepNonPatch =>
      _p.has('keep-non-patch') || (_r?.keepNonPatch ?? false);

  bool get allowEmpty => _p.has('allow-empty') || (_r?.allowEmpty ?? false);

  bool get committerDateIsAuthorDate =>
      _p.has('committer-date-is-author-date') ||
      (_r?.committerDateIsAuthorDate ?? false);

  bool get ignoreDate => _p.has('ignore-date') || (_r?.ignoreDate ?? false);

  bool get ignoreSpaceChange =>
      _p.has('ignore-space-change') || (_r?.ignoreSpaceChange ?? false);

  bool get ignoreWhitespace =>
      _p.has('ignore-whitespace') || (_r?.ignoreWhitespace ?? false);

  String? get wsPolicyRaw => _p.value('whitespace') ?? _r?.wsPolicyRaw;

  bool get reject => _p.has('reject') || (_r?.reject ?? false);

  String? get quotedCr => _p.value('quoted-cr') ?? _r?.quotedCr;

  /// Эффективное значение `--quoted-cr` (git по умолчанию предупреждает).
  String get quotedCrEffective {
    final raw = quotedCr;
    if (raw == null || raw.trim().isEmpty) return 'warn';
    return raw.trim();
  }

  int get stripPathSegments => int.tryParse(_p.value('p') ?? '0') ?? 0;

  int get applyContextLines => int.tryParse(_p.value('C') ?? '3') ?? 3;

  String? get applyDirectoryPrefix => _p.value('directory');

  GitApplyWhitespaceMode get applyWhitespaceMode => _amWhitespaceModeForFlags(
    ignoreSpaceChange: ignoreSpaceChange,
    ignoreWhitespace: ignoreWhitespace,
  );

  GitApplyWhitespacePolicy get applyWhitespacePolicy {
    final raw = wsPolicyRaw;
    return parseWhitespacePolicy(raw) ?? GitApplyWhitespacePolicy.warn;
  }
}

/// Сохраняет флаги в `.git/rebase-apply` по эффективным опциям (CLI ∪ resume).
Future<void> _amWriteRebaseApplyAmFlags(
  GitRepository repo,
  _AmEffectiveOptions o,
) async {
  await _amWriteRebaseApplyFile(repo, 'quiet', o.quiet ? 't\n' : 'f\n');
  await _amWriteRebaseApplyFile(repo, 'sign', o.signoff ? 't\n' : 'f\n');
  await _amWriteRebaseApplyFile(repo, 'utf8', o.utf8 ? 't\n' : 'f\n');
  await _amWriteRebaseApplyFile(repo, 'threeway', o.threeway ? 't\n' : 'f\n');
  await _amWriteRebaseApplyFile(repo, 'scissors', o.scissors ? 't\n' : 'f\n');
  await _amWriteRebaseApplyFile(repo, 'keep', o.keep ? 't\n' : 'f\n');
  await _amWriteRebaseApplyFile(repo, 'messageid', o.messageId ? 't\n' : 'f\n');
  await _amWriteRebaseApplyFile(
    repo,
    'keep-non-patch',
    o.keepNonPatch ? 't\n' : 'f\n',
  );
  await _amWriteRebaseApplyFile(
    repo,
    'allow-empty',
    o.allowEmpty ? 't\n' : 'f\n',
  );
  await _amWriteRebaseApplyFile(
    repo,
    'cda',
    o.committerDateIsAuthorDate ? 't\n' : 'f\n',
  );
  await _amWriteRebaseApplyFile(repo, 'idate', o.ignoreDate ? 't\n' : 'f\n');
  await _amWriteRebaseApplyFile(
    repo,
    'isc',
    o.ignoreSpaceChange ? 't\n' : 'f\n',
  );
  await _amWriteRebaseApplyFile(repo, 'iw', o.ignoreWhitespace ? 't\n' : 'f\n');
  await _amWriteRebaseApplyFile(
    repo,
    'ws-policy',
    '${o.wsPolicyRaw ?? 'warn'}\n',
  );
  await _amWriteRebaseApplyFile(repo, 'reject', o.reject ? 't\n' : 'f\n');
  await _amWriteRebaseApplyFile(repo, 'qc', '${o.quotedCrEffective}\n');
}

/// Патч пригоден для `git apply`: есть блоки `@@` или нулевой размер при
/// добавлении файла (как у системного git: «пустой» новый файл без `@@` — ок).
bool _amPatchHasApplicableHunks(String patchBody) {
  if (patchBody.trim().isEmpty) return false;
  final List<GitDiffEntry> entries;
  try {
    entries = const GitDiffCodec().decode(patchBody);
  } on FormatException {
    return false;
  }
  if (entries.isEmpty) return false;
  for (final entry in entries) {
    if (entry.hunks.isNotEmpty) return true;
    if (entry.changeType == GitDiffChangeType.added) return true;
  }
  return false;
}

Future<GitCommitSignature?> _amAuthorFromScript(GitRepository repo) async {
  final script = await _amReadRebaseApplyFile(repo, 'author-script');
  if (script == null) return null;
  String? name;
  String? email;
  String? dateRaw;
  for (final line in script.split('\n')) {
    if (line.startsWith("GIT_AUTHOR_NAME='")) {
      name = line.substring("GIT_AUTHOR_NAME='".length, line.length - 1);
    } else if (line.startsWith("GIT_AUTHOR_EMAIL='")) {
      email = line.substring("GIT_AUTHOR_EMAIL='".length, line.length - 1);
    } else if (line.startsWith("GIT_AUTHOR_DATE='")) {
      dateRaw = line.substring("GIT_AUTHOR_DATE='".length, line.length - 1);
    }
  }
  if (name == null || email == null) return null;
  if (dateRaw != null) {
    final parts = dateRaw.split(' ');
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
  return GitCommitSignature(
    name: name,
    email: email,
    timestampSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    timezoneOffset: '+0000',
  );
}

GitCommitSignature _amCommitterFromEffectiveOptions(
  AppletIo io,
  List<({String key, String value})> config,
  _AmEffectiveOptions opts, {
  required GitCommitSignature authorFallback,
}) {
  if (opts.committerDateIsAuthorDate) {
    final base = _committer(io, config);
    return GitCommitSignature(
      name: base.name,
      email: base.email,
      timestampSeconds: authorFallback.timestampSeconds,
      timezoneOffset: authorFallback.timezoneOffset,
    );
  }
  if (opts.ignoreDate) {
    return _committer(io, config);
  }
  return _committer(io, config);
}

String _amAppendSignoff(String body, GitCommitSignature signer) {
  final trailer = 'Signed-off-by: ${signer.name} <${signer.email}>\n';
  if (body.trim().isEmpty) return trailer;
  if (!body.endsWith('\n')) return '$body\n\n$trailer';
  return '$body\n$trailer';
}

String _stripAmDiffFooter(String body) {
  const marker = '\ndiff --git ';
  final index = body.indexOf(marker);
  if (index < 0) return body;
  return body.substring(0, index).trimRight();
}

/// Префикс до тела письма (заголовки и пустая строка), как после первого `\n\n`.
String _amMailHeadersPrefix(String message) {
  final idx = message.indexOf('\n\n');
  if (idx < 0) return '';
  return message.substring(0, idx + 2);
}

String _amMessageBodyAfterSubject(String message, String subjectLine) {
  final lines = message.split('\n');
  var i = 0;
  while (i < lines.length && lines[i].trim().isNotEmpty) {
    if (lines[i].toLowerCase().startsWith('subject:')) {
      final rest = lines[i].substring(lines[i].indexOf(':') + 1).trim();
      final stripped = rest.startsWith('[PATCH]')
          ? rest.substring('[PATCH]'.length).trim()
          : rest;
      if (stripped == subjectLine) {
        i++;
        while (i < lines.length && lines[i].trim().isNotEmpty) {
          i++;
        }
        if (i < lines.length && lines[i].trim().isEmpty) i++;
        return lines.sublist(i).join('\n');
      }
    }
    i++;
  }
  final hdrEnd = message.indexOf('\n\n');
  return hdrEnd < 0 ? message : message.substring(hdrEnd + 2);
}

Future<int> _amApplyOneMailboxMessage(
  AppletIo io,
  GitRepository repo,
  List<({String key, String value})> config,
  GitInvocation parsed,
  String rawMessage, {
  required String emptyMode,
}) async {
  final opts = _AmEffectiveOptions(parsed: parsed);
  final invalidQuoted = _amValidateQuotedCr(opts.quotedCrEffective);
  if (invalidQuoted != null) {
    io.stderr.writeText(invalidQuoted);
    return 128;
  }
  final wsRaw = opts.wsPolicyRaw;
  if (wsRaw != null && wsRaw.trim().isNotEmpty) {
    if (parseWhitespacePolicy(wsRaw.trim()) == null) {
      io.stderr.writeText('fatal: Invalid whitespace option: $wsRaw\n');
      return 128;
    }
  }

  var message = rawMessage;
  if (opts.keep) {
    message = stripMboxGreaterThanBody(message);
  }
  message = normalizeMboxNewlines(message, keepCr: parsed.has('keep-cr'));
  final headers = parseMailHeaders(message);
  final foreignCharset = mailCharsetNeedingConversion(message);
  if (foreignCharset != null) {
    throw GitUsage(
      'fatal: cannot convert from $foreignCharset to UTF-8\n',
      exitCode: 128,
    );
  }
  var body = mailBodyAfterHeaders(message);
  body = applyScissorsToBody(body, scissors: opts.scissors);

  final patchStart = body.indexOf('diff --git ');
  var preamble = patchStart < 0 ? body : body.substring(0, patchStart);
  final patchTail = patchStart < 0 ? '' : body.substring(patchStart);
  final quotedCr = applyQuotedCrToBody(
    preamble,
    action: opts.quotedCrEffective,
  );
  preamble = quotedCr.body;
  if (quotedCr.warnCount > 0 &&
      opts.quotedCrEffective == 'warn' &&
      !opts.quiet) {
    io.stderr.writeText(
      'warning: quoted-printable CRLF in body; see git-mailinfo(1)\n',
    );
  }
  body = patchTail.isEmpty ? preamble : '$preamble$patchTail';

  final patchStartAfterQuoted = body.indexOf('diff --git ');
  final patchText = patchStartAfterQuoted < 0
      ? ''
      : body.substring(patchStartAfterQuoted);

  if (patchText.isEmpty) {
    if (emptyMode == 'drop') {
      return 0;
    }
    if (emptyMode == 'keep') {
      final rawSubject = headers['subject'] ?? '';
      final subjectLine = mailinfoSubjectLine(
        rawSubject,
        keepSubject: opts.keep,
        keepNonPatchBrackets: opts.keepNonPatch,
      );
      var bodyText = preamble.trim();
      bodyText = _stripAmDiffFooter(bodyText);
      if (opts.signoff) {
        bodyText = _amAppendSignoff(bodyText, _signature(io, config));
      }
      final msg = _amBuildCommitMessage(
        subjectLine: subjectLine,
        bodyText: bodyText,
        headers: headers,
        opts: opts,
      );
      await repo.commit(
        author: _amAuthorFromMailHeaders(headers) ?? _signature(io, config),
        committer: _amCommitterFromEffectiveOptions(
          io,
          config,
          opts,
          authorFallback:
              _amAuthorFromMailHeaders(headers) ?? _signature(io, config),
        ),
        message: msg,
        allowEmpty: true,
      );
      if (!opts.quiet) {
        io.stdout.writeText('Applying: $subjectLine\n');
      }
      return 0;
    }
    io.stderr.writeText('Patch is empty.\n');
    return 128;
  }

  final prefix = _amMailHeadersPrefix(message);
  final fullMessageForAm = prefix.isEmpty ? patchText : '$prefix$body';

  return _amApplyParsedMessage(
    io,
    repo,
    config,
    parsed,
    fullMessageForAm,
    patchText,
    resumeAfterConflict: false,
  );
}

String _amExtractSubjectFromMbox(String message) =>
    _amSubjectFromHeaders(parseMailHeaders(message), message);

String _amSubjectFromHeaders(Map<String, String> headers, String message) {
  final subjectHeader = headers['subject'];
  if (subjectHeader != null) {
    var s = subjectHeader.trim();
    if (s.toLowerCase().startsWith('[patch]')) {
      s = s.substring('[patch]'.length).trim();
    }
    return s;
  }
  final match = RegExp(
    r'^Subject:\s*(?:\[PATCH\]\s*)?(.+)$',
    multiLine: true,
  ).firstMatch(message);
  return match?.group(1)?.trim() ?? 'am';
}

GitCommitSignature? _amAuthorFromMailHeaders(Map<String, String> headers) {
  final from = headers['from'];
  if (from == null) return null;
  final parsedFrom = parseFromHeader(from);
  final date = parseDateHeader(headers['date']);
  if (date != null) {
    return GitCommitSignature(
      name: parsedFrom.name,
      email: parsedFrom.email,
      timestampSeconds: date.seconds,
      timezoneOffset: date.tz,
    );
  }
  return GitCommitSignature(
    name: parsedFrom.name,
    email: parsedFrom.email,
    timestampSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    timezoneOffset: '+0000',
  );
}

String? _amValidateQuotedCr(String action) {
  switch (action) {
    case 'nowarn':
    case 'warn':
    case 'strip':
      return null;
    default:
      return 'fatal: invalid quoted-cr action: $action\n';
  }
}

void _amPrintStandardAmHints(AppletIo io) {
  io.stderr.writeText(
    "hint: Use 'git am --show-current-patch=diff' to see the failed patch\n",
  );
  io.stderr.writeText(
    'hint: When you have resolved this problem, run "git am --continue".\n',
  );
  io.stderr.writeText(
    'hint: If you prefer to skip this patch, run "git am --skip" instead.\n',
  );
  io.stderr.writeText(
    'hint: To restore the original branch and stop patching, run "git am --abort".\n',
  );
  io.stderr.writeText(
    'hint: Disable this message with "git config set advice.mergeConflict false"\n',
  );
}

String _amMailinfoSubjectFromHeaders(
  Map<String, String> headers,
  _AmEffectiveOptions opts,
) {
  final raw = headers['subject'];
  if (raw == null || raw.trim().isEmpty) return 'am';
  return mailinfoSubjectLine(
    raw,
    keepSubject: opts.keep,
    keepNonPatchBrackets: opts.keepNonPatch,
  );
}

String _amBuildCommitMessage({
  required String subjectLine,
  required String bodyText,
  required Map<String, String> headers,
  required _AmEffectiveOptions opts,
}) {
  var body = bodyText;
  if (opts.messageId) {
    final trailer = messageIdTrailer(headers);
    if (trailer != null) {
      if (body.trim().isEmpty) {
        body = trailer;
      } else {
        if (!body.endsWith('\n')) body = '$body\n';
        body = '$body\n$trailer';
      }
    }
  }
  final combined = '$subjectLine\n\n$body'.trim();
  return combined.endsWith('\n') ? combined : '$combined\n';
}

Future<void> _amPersistRebaseApplyForFailure(
  AppletIo io,
  GitRepository repo,
  List<({String key, String value})> config, {
  required String fullMessage,
  required String subjectLine,
  required _AmEffectiveOptions opts,
}) async {
  await Directory(_amRebaseApplyDir(repo)).create(recursive: true);
  final headNow = await repo.revParse('HEAD');
  if (headNow != null) {
    await _amWriteRebaseApplyFile(repo, 'abort-safety', headNow.hex);
  }
  await _amWriteRebaseApplyFile(repo, 'patch', fullMessage);
  await _amWriteRebaseApplyFile(repo, '0001', fullMessage);
  await _amWriteRebaseApplyFile(repo, 'final-commit', subjectLine);
  final author =
      _amAuthorFromMailHeaders(parseMailHeaders(fullMessage)) ??
      _signature(io, config);
  await _amWriteAuthorScript(repo, author);
  await _amWriteRebaseApplyFile(repo, 'last', '1\n');
  await _amWriteRebaseApplyFile(repo, 'next', '1\n');
  await _amWriteRebaseApplyAmFlags(repo, opts);
}

Future<int> _amApplyParsedMessage(
  AppletIo io,
  GitRepository repo,
  List<({String key, String value})> config,
  GitInvocation parsed,
  String fullMessage,
  String patchBody, {
  required bool resumeAfterConflict,
}) async {
  final resume = resumeAfterConflict ? await _AmResumeState.load(repo) : null;
  final opts = _AmEffectiveOptions(parsed: parsed, resume: resume);

  final invalidQuoted = _amValidateQuotedCr(opts.quotedCrEffective);
  if (invalidQuoted != null) {
    io.stderr.writeText(invalidQuoted);
    return 128;
  }

  final wsRaw = opts.wsPolicyRaw;
  if (wsRaw != null && wsRaw.trim().isNotEmpty) {
    if (parseWhitespacePolicy(wsRaw.trim()) == null) {
      io.stderr.writeText('fatal: Invalid whitespace option: $wsRaw\n');
      return 128;
    }
  }

  final headers = parseMailHeaders(fullMessage);
  final subjectLine = _amMailinfoSubjectFromHeaders(headers, opts);

  if (!resumeAfterConflict) {
    final head = await repo.revParse('HEAD');
    if (head != null) {
      await File(repo.origHeadFilePath).writeAsString('${head.hex}\n');
    }
  }

  final diffStart = patchBody.indexOf('diff --git ');
  final applyBody = diffStart >= 0 ? patchBody.substring(diffStart) : '';
  if (!_amPatchHasApplicableHunks(applyBody)) {
    if (!opts.quiet) {
      io.stderr.writeText(
        'error: No valid patches in input (allow with "--allow-empty")\n',
      );
      _amPrintStandardAmHints(io);
      io.stderr.writeText('Applying: $subjectLine\n');
      io.stderr.writeText(
        '${parsed.value('resolvemsg') ?? 'Patch failed at 0001 $subjectLine'}\n',
      );
    }
    await _amPersistRebaseApplyForFailure(
      io,
      repo,
      config,
      fullMessage: fullMessage,
      subjectLine: subjectLine,
      opts: opts,
    );
    return 128;
  }

  final apply = await repo.applyPatch(
    applyBody,
    threeWay: opts.threeway,
    reject: opts.reject,
    stripPathSegments: opts.stripPathSegments,
    whitespaceMode: opts.applyWhitespaceMode,
    whitespacePolicy: opts.applyWhitespacePolicy,
    includePaths: _amPathSet(parsed, 'include'),
    excludePaths: _amPathSet(parsed, 'exclude'),
    applyContextLines: opts.applyContextLines,
    applyDirectoryPrefix: opts.applyDirectoryPrefix,
    patchFileLabel: _amPatchFileLabel(),
  );
  _amEmitApplyStderr(io, apply, quiet: opts.quiet);

  if (!apply.success) {
    final resolveMsg =
        parsed.value('resolvemsg') ?? 'Patch failed at 0001 $subjectLine';
    if (!opts.quiet) {
      if (!apply.whitespaceBlocked && apply.hasConflicts) {
        final conflictPath = apply.files
            .firstWhere((f) => f.conflict, orElse: () => apply.files.first)
            .path;
        io.stderr.writeText('error: patch failed: $conflictPath\n');
        io.stderr.writeText('error: $conflictPath: patch does not apply\n');
        _amPrintStandardAmHints(io);
      }
      io.stderr.writeText('Applying: $subjectLine\n');
      io.stderr.writeText('$resolveMsg\n');
    }
    await _amPersistRebaseApplyForFailure(
      io,
      repo,
      config,
      fullMessage: fullMessage,
      subjectLine: subjectLine,
      opts: opts,
    );
    return 128;
  }

  final paths = _amPathsFromPatch(applyBody);
  if (paths.isNotEmpty) await repo.add(paths);

  var bodyText = _amMessageBodyAfterSubject(fullMessage, subjectLine);
  bodyText = applyScissorsToBody(bodyText, scissors: opts.scissors);
  bodyText = _stripAmDiffFooter(bodyText);
  if (opts.signoff) {
    bodyText = _amAppendSignoff(bodyText, _signature(io, config));
  }
  final msg = _amBuildCommitMessage(
    subjectLine: subjectLine,
    bodyText: bodyText,
    headers: headers,
    opts: opts,
  );

  final author = _amAuthorFromMailHeaders(headers) ?? _signature(io, config);
  final committer = _amCommitterFromEffectiveOptions(
    io,
    config,
    opts,
    authorFallback: author,
  );
  await repo.commit(
    author: author,
    committer: committer,
    message: msg,
    allowEmpty: opts.allowEmpty,
  );

  if (!opts.quiet) {
    io.stdout.writeText('Applying: $subjectLine\n');
  }

  await _amClearRebaseApply(repo);
  final orig = File(repo.origHeadFilePath);
  if (await orig.exists()) await orig.delete();
  return 0;
}

Future<void> _amWriteAuthorScript(
  GitRepository repo,
  GitCommitSignature author,
) async {
  final date = '${author.timestampSeconds} ${author.timezoneOffset}';
  await _amWriteRebaseApplyFile(
    repo,
    'author-script',
    "GIT_AUTHOR_NAME='${author.name}'\n"
        "GIT_AUTHOR_EMAIL='${author.email}'\n"
        "GIT_AUTHOR_DATE='$date'\n",
  );
}

part of '../git_commit_command.dart';

/// Сборка сообщения: cleanup, fixup, signoff и trailers.
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

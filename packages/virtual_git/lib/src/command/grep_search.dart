// ignore_for_file: avoid-substring
// Причина: шаблоны и пути режутся по индексам разбора, это не пользовательский текст.
part of '../git_grep.dart';

/// Источники строк, поиск и печать совпадений.
final class _Layout {
  _Layout(this.sources, this.specs);

  final List<_Source> sources;
  final List<_Spec> specs;
}

Future<_Layout> _layout(
  _Parsed parsed, {
  required GitRepository? repo,
  required String cwd,
  required String cwdPrefix,
}) async {
  final pathsOnly = parsed.noIndex || parsed.untracked;
  final revs = <String>[];
  final pathArgs = <({String token, bool strict})>[];
  if (!pathsOnly && repo != null) {
    var revPhase = true;
    for (final token in parsed.leading) {
      if (revPhase && await _isRevision(repo, token)) {
        revs.add(token);
        continue;
      }
      revPhase = false;
      pathArgs.add((token: token, strict: true));
    }
  } else {
    for (final token in parsed.leading) {
      pathArgs.add((token: token, strict: true));
    }
  }
  for (final token in parsed.trailing) {
    pathArgs.add((token: token, strict: false));
  }
  if (parsed.cached && revs.isNotEmpty) {
    throw const GitUsage(
      'fatal: both --cached and trees are given\n',
      exitCode: 128,
    );
  }
  final specs = <_Spec>[];
  if (pathArgs.isEmpty) {
    specs.add(_literalSpec(cwdPrefix));
  } else {
    for (final arg in pathArgs) {
      final spec = _specOf(cwdPrefix, arg.token);
      if (arg.strict && !spec.wild) {
        final known = await _known(repo, cwd, spec.prefix, revs: revs);
        if (!known) _unknownPath(arg.token, pathsOnly: pathsOnly);
      }
      specs.add(spec);
    }
  }
  final sources = await _sources(parsed, repo: repo, cwd: cwd, revs: revs);
  return _Layout(sources, specs);
}

Future<bool> _isRevision(GitRepository repo, String token) async {
  if (token.startsWith('-')) return false;
  try {
    return await repo.revParse(token) != null;
  } on FormatException {
    return false;
  } on ArgumentError {
    return false;
  }
}

void _unknownPath(String token, {required bool pathsOnly}) {
  if (pathsOnly) {
    throw GitUsage(
      'fatal: $token: no such path in the working tree.\n'
      "Use 'git <command> -- <path>...' to specify paths that do not exist locally.\n",
      exitCode: 128,
    );
  }
  if (token.startsWith('-')) {
    throw GitUsage(
      'fatal: unable to resolve revision: $token\n',
      exitCode: 128,
    );
  }
  throw GitUsage(
    "fatal: ambiguous argument '$token': unknown revision or path not in the working tree.\n"
    "Use '--' to separate paths from revisions, like this:\n"
    "'git <command> [<revision>...] -- [<file>...]'\n",
    exitCode: 128,
  );
}

_Spec _specOf(String cwdPrefix, String token) {
  final joined = cwdPrefix.isEmpty ? token : '$cwdPrefix/$token';
  final norm = _normRel(joined);
  if (norm == null) return _literalSpec('\u0000');
  final wild = norm.contains('*') || norm.contains('?');
  if (!wild) return _literalSpec(norm);
  final basenameOnly = !norm.contains('/');
  return _Spec(
    prefix: norm,
    wild: true,
    basenameOnly: basenameOnly,
    pattern: _glob(norm, basenameOnly: basenameOnly),
  );
}

_Spec _literalSpec(String prefix) =>
    _Spec(prefix: prefix, wild: false, basenameOnly: false, pattern: null);

Future<bool> _known(
  GitRepository? repo,
  String cwd,
  String prefix, {
  required List<String> revs,
}) async {
  if (prefix.isEmpty) return true;
  if (repo != null && !repo.bare) {
    if (await _workExists(repo, prefix)) return true;
    final index = await repo.readIndex();
    if (index != null && _indexHas(index, prefix)) return true;
  } else if (repo == null) {
    final abs = prefix.startsWith('/')
        ? prefix
        : p.normalize(p.join(cwd, prefix));
    if (await File(abs).exists() || await Directory(abs).exists()) return true;
  }
  if (repo == null) return false;
  for (final rev in revs) {
    if (await _treeHas(repo, rev, prefix)) return true;
  }
  return false;
}

bool _indexHas(GitIndex index, String prefix) {
  for (final entry in index.entries) {
    if (entry.path == prefix || entry.path.startsWith('$prefix/')) return true;
  }
  return false;
}

Future<bool> _workExists(GitRepository repo, String prefix) async {
  try {
    final absolute = repo.resolveWorkTreePath(prefix);
    if (await File(absolute).exists()) return true;
    if (await Directory(absolute).exists()) return true;
  } on ArgumentError {
    return false;
  }
  return false;
}

Future<bool> _treeHas(GitRepository repo, String rev, String prefix) async {
  final rows = await repo.listTree(rev, recursive: true);
  for (final row in rows) {
    if (row.path == prefix || row.path.startsWith('$prefix/')) return true;
  }
  return false;
}

Future<List<_Source>> _sources(
  _Parsed parsed, {
  required GitRepository? repo,
  required String cwd,
  required List<String> revs,
}) async {
  if (parsed.noIndex || repo == null) {
    final root = repo?.path ?? cwd;
    final exclude = parsed.excludeStandard ?? false;
    final paths = await _walk(root);
    final sources = <_Source>[];
    for (final path in paths) {
      if (exclude && repo != null) {
        final ignored = await repo.checkIgnore([path]);
        if (ignored.isNotEmpty) continue;
      }
      final bytes = await _readAbsolute(p.normalize(p.join(root, path)));
      if (bytes == null) continue;
      sources.add(_Source('', path, bytes));
    }
    return sources;
  }
  if (revs.isNotEmpty) {
    final sources = <_Source>[];
    for (final rev in revs) {
      final rows = await repo.listTree(rev, recursive: true);
      final paths = [for (final row in rows) row]
        ..sort((left, right) => left.path.compareTo(right.path));
      for (final row in paths) {
        final object = await repo.readObject(row.entry.objectId);
        if (object == null || object.type != GitObjectType.blob) continue;
        sources.add(_Source(rev, row.path, object.bytes));
      }
    }
    return sources;
  }
  if (parsed.cached) {
    final index = await repo.readIndex() ?? const GitIndex();
    final sources = <_Source>[];
    final entries = [...index.entries]
      ..sort((left, right) => left.path.compareTo(right.path));
    for (final entry in entries) {
      if (entry.stage != 0) continue;
      final object = await repo.readObject(entry.objectId);
      if (object == null || object.type != GitObjectType.blob) continue;
      sources.add(_Source('', entry.path, object.bytes));
    }
    return sources;
  }
  final index = await repo.readIndex() ?? const GitIndex();
  final paths = <String>{
    for (final entry in index.entries)
      if (entry.stage == 0) entry.path,
  };
  if (parsed.untracked && !repo.bare) {
    final exclude = parsed.excludeStandard != false;
    for (final path in await _walk(repo.path)) {
      if (paths.contains(path)) continue;
      if (exclude) {
        final ignored = await repo.checkIgnore([path]);
        if (ignored.isNotEmpty) continue;
      }
      paths.add(path);
    }
  }
  final ordered = paths.toList()..sort();
  final sources = <_Source>[];
  for (final path in ordered) {
    if (repo.bare) continue;
    final bytes = await _readWork(repo, path);
    if (bytes == null) continue;
    sources.add(_Source('', path, bytes));
  }
  return sources;
}

Future<List<String>> _walk(String root) async {
  final directory = Directory(root);
  if (!await directory.exists()) return const [];
  final paths = <String>[];
  await for (final entity in directory.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File && entity is! Link) continue;
    final relative = p.relative(entity.path, from: root);
    if (relative == '.' || relative.isEmpty) continue;
    if (relative == '.git' ||
        relative.startsWith('.git/') ||
        relative.contains('/.git/')) {
      continue;
    }
    paths.add(relative);
  }
  paths.sort();
  return paths;
}

Future<Uint8List?> _readWork(GitRepository repo, String path) async {
  try {
    return await _readAbsolute(repo.resolveWorkTreePath(path));
  } on ArgumentError {
    return null;
  }
}

Future<Uint8List?> _readAbsolute(String absolute) async {
  try {
    final file = File(absolute);
    if (!await file.exists()) return null;
    return await file.readAsBytes();
  } on FileSystemException {
    return null;
  }
}

void _compile(_Expr expr, _Parsed parsed) {
  final pats = <_Pat>[];
  expr.collect(pats);
  for (final pat in pats) {
    pat.needle = _needle(pat, parsed);
  }
}

_Needle _needle(_Pat pat, _Parsed parsed) {
  if (parsed.kind == _Kind.fixed) {
    return _Needle.fixed(
      pat.text,
      ignoreCase: parsed.ignoreCase,
      word: parsed.word,
    );
  }
  try {
    final dart = _toDart(pat.text, extended: parsed.kind == _Kind.extended);
    return _Needle.regex(
      RegExp(dart, caseSensitive: !parsed.ignoreCase),
      word: parsed.word,
    );
  } on FormatException catch (error, stack) {
    Error.throwWithStackTrace(
      GitUsage(_regexFatal(pat, error.message), exitCode: 128),
      stack,
    );
  }
}

String _regexFatal(_Pat pat, String reason) {
  final why = reason == 'backref'
      ? 'backreferences are not supported'
      : 'Invalid regular expression';
  return switch (pat.where) {
    _Where.command => "fatal: command line, '${pat.text}': $why\n",
    _Where.optionE => "fatal: -e option, '${pat.text}': $why\n",
    _Where.file =>
      "fatal: In '${pat.file}' at ${pat.line}, '${pat.text}': $why\n",
  };
}

String _toDart(String pattern, {required bool extended}) {
  final out = StringBuffer();
  var atom = false;
  for (var index = 0; index < pattern.length; index++) {
    final char = pattern[index];
    if (char == r'\') {
      if (index + 1 >= pattern.length) {
        throw const FormatException('invalid');
      }
      final next = pattern[index + 1];
      index++;
      if (next.codeUnitAt(0) >= 0x31 && next.codeUnitAt(0) <= 0x39) {
        throw const FormatException('backref');
      }
      if (!extended && next == '{') {
        final interval = _breInterval(pattern, index);
        if (interval == null) throw const FormatException('invalid');
        _emitQuant(out, interval.text, atom);
        atom = true;
        index = interval.next - 1;
        continue;
      }
      if (!extended && (next == '+' || next == '?' || next == '*')) {
        _emitQuant(out, next, atom);
        atom = true;
        continue;
      }
      if (!extended && next == '(') {
        out.write('(');
        atom = false;
        continue;
      }
      if (!extended && next == ')') {
        out.write(')');
        atom = true;
        continue;
      }
      if (!extended && next == '|') {
        out.write('|');
        atom = false;
        continue;
      }
      if (next == '<') {
        out.write(r'(?<![0-9A-Za-z_])');
        atom = false;
        continue;
      }
      if (next == '>') {
        out.write(r'(?![0-9A-Za-z_])');
        atom = false;
        continue;
      }
      _emitLiteral(out, next);
      atom = true;
      continue;
    }
    if (char == '[') {
      index = _copyClass(pattern, index, out) - 1;
      atom = true;
      continue;
    }
    if (char == '(') {
      if (!extended) {
        _emitLiteral(out, char);
        atom = true;
        continue;
      }
      out.write('(');
      atom = false;
      continue;
    }
    if (char == ')') {
      if (!extended) {
        _emitLiteral(out, char);
        atom = true;
        continue;
      }
      out.write(')');
      atom = true;
      continue;
    }
    if (char == '|') {
      if (!extended) {
        _emitLiteral(out, char);
        atom = true;
        continue;
      }
      out.write('|');
      atom = false;
      continue;
    }
    if (char == '*' || (extended && (char == '+' || char == '?'))) {
      _emitQuant(out, char, atom);
      atom = true;
      continue;
    }
    if (extended && char == '{') {
      final interval = _ereInterval(pattern, index);
      if (interval == null || !atom) {
        _emitLiteral(out, char);
        atom = true;
        continue;
      }
      out.write(interval.text);
      index = interval.next - 1;
      atom = true;
      continue;
    }
    if (char == '^' || char == r'$') {
      out.write(char);
      atom = false;
      continue;
    }
    if (char == '.') {
      out.write('.');
      atom = true;
      continue;
    }
    _emitLiteral(out, char);
    atom = true;
  }
  return out.toString();
}

void _emitQuant(StringBuffer out, String text, bool atom) {
  if (!atom) {
    for (final unit in text.codeUnits) {
      _emitLiteral(out, String.fromCharCode(unit));
    }
    return;
  }
  out.write(text);
}

void _emitLiteral(StringBuffer out, String char) {
  if (r'\^$.|?*+()[]{}'.contains(char)) out.write(r'\');
  out.write(char);
}

int _copyClass(String pattern, int open, StringBuffer out) {
  out.write('[');
  var index = open + 1;
  if (index < pattern.length && pattern[index] == '^') {
    out.write('^');
    index++;
  }
  if (index < pattern.length && pattern[index] == ']') {
    out.write(r'\]');
    index++;
  }
  while (index < pattern.length && pattern[index] != ']') {
    if (pattern[index] == '[' &&
        index + 1 < pattern.length &&
        pattern[index + 1] == ':') {
      final end = pattern.indexOf(':]', index + 2);
      if (end < 0) throw const FormatException('invalid');
      final name = _cut(pattern, index + 2, end);
      final mapped = _posix[name];
      if (mapped == null) throw const FormatException('invalid');
      out.write(mapped);
      index = end + 2;
      continue;
    }
    if (pattern[index] == r'\') {
      out.write(r'\');
      if (index + 1 < pattern.length) out.write(pattern[index + 1]);
      index += 2;
      continue;
    }
    out.write(pattern[index]);
    index++;
  }
  if (index >= pattern.length || pattern[index] != ']') {
    throw const FormatException('invalid');
  }
  out.write(']');
  return index + 1;
}

const _posix = <String, String>{
  'alnum': '0-9A-Za-z',
  'alpha': 'A-Za-z',
  'blank': r' \t',
  'cntrl': r'\x00-\x1F\x7F',
  'digit': '0-9',
  'graph': r'\x21-\x7E',
  'lower': 'a-z',
  'print': r'\x20-\x7E',
  'punct': r'!-/:-@\[-`{-~',
  'space': ' \t\n\r\x0B\x0C',
  'upper': 'A-Z',
  'word': '0-9A-Za-z_',
  'xdigit': '0-9A-Fa-f',
};

({String text, int next})? _breInterval(String pattern, int open) {
  final body = _intervalBody(pattern, open);
  if (body == null) return null;
  if (body.next + 1 >= pattern.length ||
      pattern[body.next] != r'\' ||
      pattern[body.next + 1] != '}') {
    return null;
  }
  return (text: '${body.text}}', next: body.next + 2);
}

({String text, int next})? _ereInterval(String pattern, int open) {
  final body = _intervalBody(pattern, open);
  if (body == null) return null;
  if (body.next >= pattern.length || pattern[body.next] != '}') return null;
  return (text: '${body.text}}', next: body.next + 1);
}

({String text, int next})? _intervalBody(String pattern, int open) {
  var index = open + 1;
  final start = index;
  while (index < pattern.length && _digit(pattern, index)) {
    index++;
  }
  if (index == start) return null;
  if (index < pattern.length && pattern[index] == ',') {
    index++;
    while (index < pattern.length && _digit(pattern, index)) {
      index++;
    }
  }
  return (text: _cut(pattern, open, index), next: index);
}

bool _digit(String text, int index) {
  final unit = text.codeUnitAt(index);
  return unit >= 0x30 && unit <= 0x39;
}

Future<int> _search(
  AppletIo io,
  _Parsed parsed,
  _Expr expr,
  _Layout layout, {
  required String cwdPrefix,
}) async {
  final pats = <_Pat>[];
  expr.collect(pats);
  var found = false;
  var emitted = false;
  final context = parsed.before > 0 || parsed.after > 0;
  for (final source in layout.sources) {
    if (!_allowed(source.path, layout.specs, parsed.maxDepth)) continue;
    final binary = _isBinary(source.bytes);
    if (binary && parsed.skipBinary) {
      if (parsed.mode == _Mode.without) {
        found = true;
        if (parsed.quiet) return 0;
        _writeName(io, parsed, _name(source, cwdPrefix, parsed.fullName));
      }
      continue;
    }
    final lines = _bytesLines(source.bytes);
    final matches = <int>[];
    final seen = <_Pat>{};
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      for (final pat in pats) {
        if (pat.needle.hits(line)) seen.add(pat);
      }
      final matched = expr.eval((pat) => pat.needle.hits(line)) ^ parsed.invert;
      if (!matched) continue;
      if (parsed.maxCount != null && matches.length >= parsed.maxCount!) {
        continue;
      }
      matches.add(index);
    }
    final all = !parsed.allMatch || pats.every(seen.contains);
    final hit = matches.isNotEmpty && all;
    if (parsed.mode == _Mode.without) {
      if (hit) continue;
      found = true;
      if (parsed.quiet) return 0;
      _writeName(io, parsed, _name(source, cwdPrefix, parsed.fullName));
      continue;
    }
    if (!hit) continue;
    found = true;
    if (parsed.quiet) return 0;
    final name = _name(source, cwdPrefix, parsed.fullName);
    if (parsed.mode == _Mode.withMatch) {
      _writeName(io, parsed, name);
      continue;
    }
    if (parsed.mode == _Mode.count) {
      _writeCount(io, parsed, name, matches.length);
      continue;
    }
    if (binary && !parsed.text) {
      io.stdout.writeText('Binary file $name matches\n');
      emitted = true;
      continue;
    }
    if (emitted && parsed.breakFiles) io.stdout.writeText('\n');
    if (emitted && context) io.stdout.writeText('--\n');
    final showName = parsed.showName && !parsed.heading;
    if (parsed.heading && parsed.showName) io.stdout.writeText('$name\n');
    final shown = _withContext(
      matches,
      lines.length,
      parsed.before,
      parsed.after,
    );
    final selected = {for (final index in matches) index};
    var previous = -2;
    for (final index in shown) {
      if (previous >= 0 && index > previous + 1 && context) {
        io.stdout.writeText('--\n');
      }
      final line = lines[index];
      final isMatch = selected.contains(index);
      if (parsed.onlyMatching && isMatch) {
        _writeOnly(
          io,
          parsed,
          name: showName ? name : null,
          number: parsed.lineNumber ? index + 1 : null,
          line: line,
          spans: _visibleSpans(line, pats),
        );
      } else if (!parsed.onlyMatching || !isMatch) {
        final spans = _visibleSpans(line, pats);
        final column = parsed.column && isMatch
            ? (spans.isEmpty ? 1 : spans.first.start + 1)
            : null;
        _writeLine(
          io,
          parsed,
          name: showName ? name : null,
          number: parsed.lineNumber ? index + 1 : null,
          column: column,
          text: line,
          match: isMatch,
        );
      }
      previous = index;
    }
    emitted = true;
  }
  return found ? 0 : 1;
}

List<int> _withContext(List<int> matches, int length, int before, int after) {
  final chosen = <int>{};
  for (final index in matches) {
    final start = index - before < 0 ? 0 : index - before;
    final end = index + after >= length ? length - 1 : index + after;
    for (var cursor = start; cursor <= end; cursor++) {
      chosen.add(cursor);
    }
  }
  return chosen.toList()..sort();
}

List<_Span> _visibleSpans(String line, List<_Pat> pats) {
  final spans = <_Span>[];
  for (final pat in pats) {
    for (final span in pat.needle.spans(line)) {
      if (span.end <= span.start) continue;
      final duplicate = spans.any(
        (item) => item.start == span.start && item.end == span.end,
      );
      if (!duplicate) spans.add(span);
    }
  }
  spans.sort((left, right) => left.start.compareTo(right.start));
  return spans;
}

void _writeOnly(
  AppletIo io,
  _Parsed parsed, {
  required String? name,
  required int? number,
  required String line,
  required List<_Span> spans,
}) {
  for (final span in spans) {
    _writeLine(
      io,
      parsed,
      name: name,
      number: number,
      column: parsed.column ? span.start + 1 : null,
      text: _cut(line, span.start, span.end),
      match: true,
    );
  }
}

void _writeLine(
  AppletIo io,
  _Parsed parsed, {
  required String? name,
  required int? number,
  required int? column,
  required String text,
  required bool match,
}) {
  final sep = parsed.nul ? '\x00' : (match ? ':' : '-');
  final out = StringBuffer();
  var any = false;
  void field(String value) {
    if (any) out.write(sep);
    out.write(value);
    any = true;
  }

  if (name != null) field(name);
  if (number != null) field('$number');
  if (column != null) field('$column');
  if (any) out.write(sep);
  out
    ..write(text)
    ..write('\n');
  io.stdout.writeText(out.toString());
}

void _writeName(AppletIo io, _Parsed parsed, String name) {
  if (parsed.nul) {
    io.stdout.writeText('$name\x00');
    return;
  }
  io.stdout.writeText('$name\n');
}

void _writeCount(AppletIo io, _Parsed parsed, String name, int count) {
  if (parsed.nul) {
    if (parsed.showName) {
      io.stdout.writeText('$name\x00$count\n');
    } else {
      io.stdout.writeText('$count\n');
    }
    return;
  }
  if (parsed.showName) {
    io.stdout.writeText('$name:$count\n');
  } else {
    io.stdout.writeText('$count\n');
  }
}

String _name(_Source source, String cwdPrefix, bool fullName) {
  final shown = fullName ? source.path : _relWithin(source.path, cwdPrefix);
  if (source.label.isEmpty) return shown;
  return '${source.label}:$shown';
}

bool _allowed(String path, List<_Spec> specs, int maxDepth) {
  for (final spec in specs) {
    if (!_matchSpec(path, spec)) continue;
    if (spec.wild || maxDepth < 0) return true;
    if (_depth(path, spec.prefix) <= maxDepth) return true;
  }
  return false;
}

bool _matchSpec(String path, _Spec spec) {
  if (!spec.wild) {
    if (spec.prefix.isEmpty) return true;
    if (spec.prefix == '\u0000') return false;
    return path == spec.prefix || path.startsWith('${spec.prefix}/');
  }
  final target = spec.basenameOnly ? _base(path) : path;
  return spec.pattern!.hasMatch(target);
}

int _depth(String path, String prefix) {
  if (prefix.isEmpty) return _slashes(path);
  if (path == prefix) return 0;
  return _slashes(_cut(path, prefix.length + 1, path.length));
}

int _slashes(String text) {
  var count = 0;
  for (final unit in text.codeUnits) {
    if (unit == 0x2f) count++;
  }
  return count;
}

String _base(String path) {
  final slash = path.lastIndexOf('/');
  if (slash < 0) return path;
  return _cut(path, slash + 1, path.length);
}

bool _isBinary(Uint8List bytes) {
  for (final byte in bytes) {
    if (byte == 0) return true;
  }
  return false;
}

List<String> _bytesLines(Uint8List bytes) {
  final lines = <String>[];
  var start = 0;
  for (var index = 0; index < bytes.length; index++) {
    if (bytes[index] != 0x0a) continue;
    lines.add(String.fromCharCodes(bytes.sublist(start, index)));
    start = index + 1;
  }
  if (start < bytes.length) {
    lines.add(String.fromCharCodes(bytes.sublist(start)));
  }
  return lines;
}

RegExp _glob(String pattern, {required bool basenameOnly}) {
  final out = StringBuffer('^');
  for (var index = 0; index < pattern.length; index++) {
    final char = pattern[index];
    if (char == '*') {
      final doubled = index + 1 < pattern.length && pattern[index + 1] == '*';
      if (doubled) {
        out.write('.*');
        index++;
      } else {
        out.write(basenameOnly ? '.*' : '[^/]*');
      }
      continue;
    }
    if (char == '?') {
      out.write(basenameOnly ? '.' : '[^/]');
      continue;
    }
    out.write(RegExp.escape(char));
  }
  out.write(r'$');
  return RegExp(out.toString());
}

String _cwdPrefix(String root, String cwd) {
  final relative = p.relative(p.normalize(cwd), from: p.normalize(root));
  if (relative == '.' || relative.startsWith('..')) return '';
  return relative;
}

String _relWithin(String path, String from) {
  if (from.isEmpty) return path;
  if (path == from) return _base(path);
  if (path.startsWith('$from/')) {
    return _cut(path, from.length + 1, path.length);
  }
  final fromParts = from.split('/');
  final pathParts = path.split('/');
  var common = 0;
  while (common < fromParts.length &&
      common < pathParts.length &&
      fromParts[common] == pathParts[common]) {
    common++;
  }
  return [
    for (var index = 0; index < fromParts.length - common; index++) '..',
    ...pathParts.sublist(common),
  ].join('/');
}

/// `..` выше корня репозитория даёт null: такой pathspec не существует.
String? _normRel(String path) {
  final parts = <String>[];
  var escaped = false;
  for (final segment in path.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (parts.isEmpty) {
        escaped = true;
      } else {
        parts.removeLast();
      }
      continue;
    }
    parts.add(segment);
  }
  if (escaped) return null;
  return parts.join('/');
}

String _cut(String text, int start, int end) =>
    String.fromCharCodes(text.codeUnits.getRange(start, end));

// ignore_for_file: avoid-substring
// Причина: шаблоны и пути режутся по индексам разбора, это не пользовательский текст.
/// `git grep`: строки tracked-файлов, индекса, деревьев и `--no-index`.
///
/// Регулярные выражения — POSIX BRE (по умолчанию) и ERE (`-E`); `-F` ищет
/// фиксированную строку. Образцы комбинируются `--and` / `--or` / `--not`
/// и скобками, пустой образец совпадает с каждой строкой.
/// PCRE, цвет, pager, textconv, потоки, function-context и submodule
/// в разбор не входят: `error: unknown option`, код 129.
library;

import 'dart:typed_data';

import 'package:virtual_git/src/git_cli.dart';
import 'package:virtual_git/src/git_host_io.dart';
import 'package:virtual_git/src/git_index.dart';
import 'package:virtual_git/src/git_object_type.dart';
import 'package:virtual_git/src/git_path.dart' as p;
import 'package:virtual_git/src/git_repository.dart';
import 'package:virtual_host/virtual_host.dart';

/// Ищет образец так же, как `git grep` в `LC_ALL=C`, и возвращает код выхода.
///
/// 0 — есть совпадение (для `-L` — есть файл без совпадения), 1 — нет,
/// 128 — фатальная ошибка, 129 — чужая опция или нет значения.
/// Неподдерживаемые флаги справки не прячутся: их нет в разборе, поэтому
/// апплет отвечает `error: unknown option` / `unknown switch`.
Future<int> gitGrep(AppletIo io, List<String> args) async {
  final parsed = await _parse(io, args);
  final expr = parsed.builder.finish();
  if (expr == null) {
    throw const GitUsage('fatal: no pattern given\n', exitCode: 128);
  }
  _rejectConflicts(parsed);
  final repo = await GitRepository.discover(io.cwd);
  if (repo == null && !parsed.noIndex) {
    throw const GitUsage(
      'fatal: not a git repository (or any of the parent directories): .git\n',
      exitCode: 128,
    );
  }
  final cwdPrefix = repo == null ? '' : _cwdPrefix(repo.path, io.cwd);
  final layout = await _layout(
    parsed,
    repo: repo,
    cwd: io.cwd,
    cwdPrefix: cwdPrefix,
  );
  if (parsed.maxCount == 0) return 1;
  _compile(expr, parsed);
  return _search(io, parsed, expr, layout, cwdPrefix: cwdPrefix);
}

const _usage =
    'usage: git grep [<options>] [-e] <pattern> [<rev>...] [[--] <path>...]';

enum _Kind { basic, extended, fixed }

enum _Mode { lines, count, withMatch, without }

enum _Where { command, optionE, file }

final class _Pat {
  _Pat(this.text, this.where, {this.file, this.line = 1});

  final String text;
  final _Where where;
  final String? file;
  final int line;
  late final _Needle needle;
}

final class _Span {
  const _Span(this.start, this.end);

  final int start;
  final int end;
}

/// Совпадение фиксированной строки или регулярного выражения на одной строке.
final class _Needle {
  _Needle.fixed(this.fixed, {required this.ignoreCase, required this.word})
    : regex = null;

  _Needle.regex(this.regex, {required this.word})
    : fixed = null,
      ignoreCase = false;

  final String? fixed;
  final bool ignoreCase;
  final RegExp? regex;
  final bool word;

  bool hits(String line) => spans(line).isNotEmpty;

  List<_Span> spans(String line) {
    final found = fixed == null ? _regexSpans(line) : _fixedSpans(line);
    if (!word) return found;
    return [
      for (final span in found)
        if (_wordBoundary(line, span.start, span.end)) span,
    ];
  }

  List<_Span> _fixedSpans(String line) {
    final needle = fixed!;
    if (needle.isEmpty) return const [_Span(0, 0)];
    final haystack = ignoreCase ? _foldAscii(line) : line;
    final probe = ignoreCase ? _foldAscii(needle) : needle;
    final found = <_Span>[];
    var from = 0;
    while (from <= haystack.length) {
      final at = haystack.indexOf(probe, from);
      if (at < 0) break;
      found.add(_Span(at, at + probe.length));
      from = at + probe.length;
    }
    return found;
  }

  List<_Span> _regexSpans(String line) => [
    for (final match in regex!.allMatches(line)) _Span(match.start, match.end),
  ];
}

bool _wordBoundary(String line, int start, int end) {
  if (start > 0 && _wordChar(line.codeUnitAt(start - 1))) return false;
  if (end < line.length && _wordChar(line.codeUnitAt(end))) return false;
  return true;
}

bool _wordChar(int unit) =>
    (unit >= 0x30 && unit <= 0x39) ||
    (unit >= 0x41 && unit <= 0x5a) ||
    (unit >= 0x61 && unit <= 0x7a) ||
    unit == 0x5f;

String _foldAscii(String text) {
  final out = StringBuffer();
  for (final unit in text.codeUnits) {
    out.writeCharCode(unit >= 0x41 && unit <= 0x5a ? unit + 0x20 : unit);
  }
  return out.toString();
}

sealed class _Expr {
  bool eval(bool Function(_Pat pat) hit);

  void collect(List<_Pat> into);
}

final class _Leaf extends _Expr {
  _Leaf(this.pat);

  final _Pat pat;

  @override
  bool eval(bool Function(_Pat pat) hit) => hit(pat);

  @override
  void collect(List<_Pat> into) => into.add(pat);
}

final class _Not extends _Expr {
  _Not(this.inner);

  final _Expr inner;

  @override
  bool eval(bool Function(_Pat pat) hit) => !inner.eval(hit);

  @override
  void collect(List<_Pat> into) => inner.collect(into);
}

final class _And extends _Expr {
  _And(this.left, this.right);

  final _Expr left;
  final _Expr right;

  @override
  bool eval(bool Function(_Pat pat) hit) => left.eval(hit) && right.eval(hit);

  @override
  void collect(List<_Pat> into) {
    left.collect(into);
    right.collect(into);
  }
}

final class _Or extends _Expr {
  _Or(this.left, this.right);

  final _Expr left;
  final _Expr right;

  @override
  bool eval(bool Function(_Pat pat) hit) => left.eval(hit) || right.eval(hit);

  @override
  void collect(List<_Pat> into) {
    left.collect(into);
    right.collect(into);
  }
}

/// Собирает булево выражение. `--and` теснее `--or`, лишний `--or` молчит.
final class _Builder {
  final _out = <_Expr>[];
  final _stack = <String>[];
  final _parenNots = <int>[];
  var _nots = 0;
  var _atom = false;
  String? _pending;

  void orOp() {
    if (_atom) {
      _pending = 'or';
      _atom = false;
      return;
    }
    if (_pending != null) _pending = 'or';
  }

  void andOp() {
    if (_atom) {
      _pending = 'and';
      _atom = false;
      return;
    }
    if (_pending != null) {
      _pending = 'and';
      return;
    }
    throw const GitUsage(
      'fatal: --and not preceded by pattern expression\n',
      exitCode: 128,
    );
  }

  void notOp() {
    if (_atom) {
      _pending ??= 'or';
      _atom = false;
    }
    _nots++;
  }

  void addAtom(_Pat pat) {
    if (_atom) _pending ??= 'or';
    _applyPending();
    _out.add(_wrap(_Leaf(pat), _nots));
    _nots = 0;
    _atom = true;
  }

  void lparen() {
    if (_atom) _pending ??= 'or';
    _applyPending();
    _stack.add('(');
    _parenNots.add(_nots);
    _nots = 0;
    _atom = false;
  }

  void rparen() {
    if (!_atom || _pending != null || _nots != 0) {
      throw const GitUsage(
        'fatal: incomplete pattern expression group: )\n',
        exitCode: 128,
      );
    }
    while (_stack.isNotEmpty && _stack.last != '(') {
      _reduce();
    }
    if (_stack.isEmpty || _stack.last != '(') {
      throw const GitUsage(
        'fatal: incomplete pattern expression group: )\n',
        exitCode: 128,
      );
    }
    _stack.removeLast();
    final saved = _parenNots.removeLast();
    final expr = _wrap(_out.removeLast(), saved);
    _out.add(expr);
    _atom = true;
  }

  /// Корень выражения или null, если образцов не было.
  _Expr? finish() {
    if (_nots > 0) {
      throw const GitUsage(
        'fatal: --not not followed by pattern expression\n',
        exitCode: 128,
      );
    }
    if (_pending == 'and') {
      throw const GitUsage(
        'fatal: --and not followed by pattern expression\n',
        exitCode: 128,
      );
    }
    _pending = null;
    while (_stack.isNotEmpty) {
      if (_stack.last == '(') {
        throw const GitUsage(
          'fatal: unmatched ( for expression group\n',
          exitCode: 128,
        );
      }
      _reduce();
    }
    if (_out.isEmpty) return null;
    return _out.single;
  }

  void _applyPending() {
    final op = _pending;
    if (op == null) return;
    _pending = null;
    while (_stack.isNotEmpty &&
        _stack.last != '(' &&
        _prec(_stack.last) >= _prec(op)) {
      _reduce();
    }
    _stack.add(op);
  }

  void _reduce() {
    final op = _stack.removeLast();
    final right = _out.removeLast();
    final left = _out.removeLast();
    _out.add(op == 'and' ? _And(left, right) : _Or(left, right));
  }

  _Expr _wrap(_Expr expr, int count) {
    var current = expr;
    for (var index = 0; index < count; index++) {
      current = _Not(current);
    }
    return current;
  }

  int _prec(String op) => op == 'and' ? 2 : 1;
}

final class _Parsed {
  final builder = _Builder();
  var kind = _Kind.basic;
  var ignoreCase = false;
  var word = false;
  var invert = false;
  var text = false;
  var skipBinary = false;
  var cached = false;
  var untracked = false;
  var noIndex = false;
  bool? excludeStandard;
  var fullName = false;
  var showName = true;
  var lineNumber = false;
  var column = false;
  var onlyMatching = false;
  var nul = false;
  var breakFiles = false;
  var heading = false;
  var quiet = false;
  var allMatch = false;
  var mode = _Mode.lines;
  var before = 0;
  var after = 0;
  var maxDepth = -1;
  int? maxCount;
  var separated = false;
  var sawPattern = false;

  /// Токены до `--`: ведущие ревизии, затем пути.
  final leading = <String>[];

  /// Токены после `--`: только пути, отсутствующий pathspec не фатален.
  final trailing = <String>[];
}

final class _Spec {
  _Spec({
    required this.prefix,
    required this.wild,
    required this.basenameOnly,
    required this.pattern,
  });

  final String prefix;
  final bool wild;
  final bool basenameOnly;
  final RegExp? pattern;
}

final class _Source {
  _Source(this.label, this.path, this.bytes);

  final String label;
  final String path;
  final Uint8List bytes;
}

Future<_Parsed> _parse(AppletIo io, List<String> args) async {
  final parsed = _Parsed();
  var optionsOpen = true;
  for (var index = 0; index < args.length; index++) {
    final arg = args[index];
    if (arg == '--' && !parsed.separated) {
      parsed.separated = true;
      optionsOpen = false;
      continue;
    }
    if (optionsOpen && (arg == '(' || arg == ')')) {
      if (arg == '(') {
        parsed.builder.lparen();
      } else {
        parsed.builder.rparen();
      }
      continue;
    }
    if (!optionsOpen) {
      if (!parsed.sawPattern) {
        _addPattern(parsed, arg, _Where.command);
      } else if (parsed.separated) {
        parsed.trailing.add(arg);
      } else if (arg.startsWith('-')) {
        throw GitUsage(
          "fatal: option '$arg' must come before non-option arguments\n",
          exitCode: 128,
        );
      } else {
        parsed.leading.add(arg);
      }
      continue;
    }
    if (arg == '-' || !arg.startsWith('-')) {
      if (parsed.sawPattern) {
        parsed.leading.add(arg);
      } else {
        _addPattern(parsed, arg, _Where.command);
      }
      optionsOpen = false;
      continue;
    }
    if (_numericContext.hasMatch(arg)) {
      final count = int.parse(_cut(arg, 1, arg.length));
      parsed
        ..before = count
        ..after = count;
      continue;
    }
    if (arg.startsWith('--')) {
      _longOption(parsed, arg, args, index);
      if (_consumedNext(arg)) index++;
      continue;
    }
    final body = _cut(arg, 1, arg.length);
    for (var cursor = 0; cursor < body.length; cursor++) {
      final letter = body[cursor];
      if (_valuedShort(letter)) {
        final rest = _cut(body, cursor + 1, body.length);
        final value = rest.isNotEmpty
            ? rest
            : _require(args, index, label: letter, long: false);
        if (rest.isEmpty) index++;
        await _applyShort(io, parsed, letter, value);
        break;
      }
      _applyShortFlag(parsed, letter);
    }
  }
  return parsed;
}

final _numericContext = RegExp(r'^-[0-9]+$');

bool _consumedNext(String arg) {
  if (!arg.startsWith('--')) return false;
  final body = _cut(arg, 2, arg.length);
  if (body.contains('=')) return false;
  return _valuedLong(body);
}

bool _valuedLong(String name) => switch (name) {
  'max-depth' ||
  'max-count' ||
  'context' ||
  'after-context' ||
  'before-context' => true,
  _ => false,
};

bool _valuedShort(String letter) => switch (letter) {
  'A' || 'B' || 'C' || 'm' || 'e' || 'f' => true,
  _ => false,
};

String _require(
  List<String> args,
  int index, {
  required String label,
  required bool long,
}) {
  if (index + 1 >= args.length) {
    final kind = long ? 'option' : 'switch';
    throw GitUsage("error: $kind `$label' requires a value\n");
  }
  return args[index + 1];
}

void _longOption(_Parsed parsed, String arg, List<String> args, int index) {
  final body = _cut(arg, 2, arg.length);
  final eq = body.indexOf('=');
  final name = eq < 0 ? body : _cut(body, 0, eq);
  final inline = eq < 0 ? null : _cut(body, eq + 1, body.length);
  if (_valuedLong(name)) {
    final value = inline ?? _require(args, index, label: name, long: true);
    _applyValued(parsed, name, value, long: true);
    return;
  }
  if (inline != null) {
    throw GitUsage("error: unknown option `$name'\n$_usage\n");
  }
  if (_applyBool(parsed, name, on: true)) return;
  if (name == 'and') {
    parsed.builder.andOp();
    return;
  }
  if (name == 'or') {
    parsed.builder.orOp();
    return;
  }
  if (name == 'not') {
    parsed.builder.notOp();
    return;
  }
  throw GitUsage("error: unknown option `$name'\n$_usage\n");
}

Future<void> _applyShort(
  AppletIo io,
  _Parsed parsed,
  String letter,
  String value,
) async {
  switch (letter) {
    case 'e':
      _addPattern(parsed, value, _Where.optionE);
    case 'f':
      await _addFile(io, parsed, value);
    case 'A':
      parsed.after = _number(value, label: 'A', long: false, suffix: false);
    case 'B':
      parsed.before = _number(value, label: 'B', long: false, suffix: false);
    case 'C':
      final count = _number(value, label: 'C', long: false, suffix: false);
      parsed
        ..before = count
        ..after = count;
    case 'm':
      final count = _number(value, label: 'm', long: false, suffix: false);
      parsed.maxCount = count < 0 ? null : count;
    default:
      throw GitUsage("error: unknown switch `$letter'\n$_usage\n");
  }
}

void _applyShortFlag(_Parsed parsed, String letter) {
  switch (letter) {
    case 'a':
      parsed
        ..text = true
        ..skipBinary = false;
    case 'I':
      parsed
        ..skipBinary = true
        ..text = false;
    case 'i':
      parsed.ignoreCase = true;
    case 'w':
      parsed.word = true;
    case 'v':
      parsed.invert = true;
    case 'E':
      parsed.kind = _Kind.extended;
    case 'G':
      parsed.kind = _Kind.basic;
    case 'F':
      parsed.kind = _Kind.fixed;
    case 'n':
      parsed.lineNumber = true;
    case 'h':
      parsed.showName = false;
    case 'H':
      parsed.showName = true;
    case 'l':
      parsed.mode = _Mode.withMatch;
    case 'L':
      parsed.mode = _Mode.without;
    case 'c':
      if (parsed.mode == _Mode.lines) parsed.mode = _Mode.count;
    case 'q':
      parsed.quiet = true;
    case 'o':
      parsed.onlyMatching = true;
    case 'z':
      parsed.nul = true;
    case 'r':
      parsed.maxDepth = -1;
    case '(':
      parsed.builder.lparen();
    case ')':
      parsed.builder.rparen();
    default:
      throw GitUsage("error: unknown switch `$letter'\n$_usage\n");
  }
}

void _applyValued(
  _Parsed parsed,
  String name,
  String value, {
  required bool long,
}) {
  switch (name) {
    case 'max-depth':
      parsed.maxDepth = _number(value, label: name, long: long, suffix: true);
    case 'max-count':
      final count = _number(value, label: name, long: long, suffix: false);
      parsed.maxCount = count < 0 ? null : count;
    case 'context':
      final count = _number(value, label: name, long: long, suffix: false);
      parsed
        ..before = count
        ..after = count;
    case 'after-context':
      parsed.after = _number(value, label: name, long: long, suffix: false);
    case 'before-context':
      parsed.before = _number(value, label: name, long: long, suffix: false);
    default:
      throw GitUsage("error: unknown option `$name'\n$_usage\n");
  }
}

bool _applyBool(_Parsed parsed, String name, {required bool on}) {
  final base = name.startsWith('no-') ? _cut(name, 3, name.length) : name;
  final enable = name.startsWith('no-') ? !on : on;
  switch (base) {
    case 'cached':
      parsed.cached = enable;
    case 'untracked':
      parsed.untracked = enable;
    case 'index':
      parsed.noIndex = !enable;
    case 'exclude-standard':
      parsed.excludeStandard = enable;
    case 'text':
      parsed.text = enable;
      if (enable) parsed.skipBinary = false;
    case 'ignore-case':
      parsed.ignoreCase = enable;
    case 'word-regexp':
      parsed.word = enable;
    case 'invert-match':
      parsed.invert = enable;
    case 'full-name':
      parsed.fullName = enable;
    case 'line-number':
      parsed.lineNumber = enable;
    case 'column':
      parsed.column = enable;
    case 'null':
      parsed.nul = enable;
    case 'only-matching':
      parsed.onlyMatching = enable;
    case 'count':
      if (enable) {
        if (parsed.mode == _Mode.lines) parsed.mode = _Mode.count;
      } else if (parsed.mode == _Mode.count) {
        parsed.mode = _Mode.lines;
      }
    case 'break':
      parsed.breakFiles = enable;
    case 'heading':
      parsed.heading = enable;
    case 'quiet':
      parsed.quiet = enable;
    case 'all-match':
      parsed.allMatch = enable;
    case 'files-with-matches' || 'name-only':
      parsed.mode = enable ? _Mode.withMatch : _Mode.lines;
    case 'files-without-match':
      parsed.mode = enable ? _Mode.without : _Mode.lines;
    case 'recursive':
      parsed.maxDepth = enable ? -1 : 0;
    case 'extended-regexp':
      parsed.kind = enable ? _Kind.extended : _Kind.basic;
    case 'basic-regexp':
      parsed.kind = enable ? _Kind.basic : _Kind.extended;
    case 'fixed-strings':
      parsed.kind = enable ? _Kind.fixed : _Kind.basic;
    default:
      if (name.startsWith('no-')) {
        throw GitUsage("error: unknown option `$name'\n$_usage\n");
      }
      return false;
  }
  return true;
}

int _number(
  String raw, {
  required String label,
  required bool long,
  required bool suffix,
}) {
  final match = RegExp(r'^(-?\d+)([kmgKMG])?$').firstMatch(raw);
  if (match == null || (!suffix && match.group(2) != null)) {
    final kind = long ? 'option' : 'switch';
    final expect = suffix
        ? 'an integer value with an optional k/m/g suffix'
        : 'a numerical value';
    throw GitUsage("error: $kind `$label' expects $expect\n");
  }
  var value = int.parse(match.group(1)!);
  final scale = match.group(2);
  if (scale != null) {
    final factor = switch (scale.toLowerCase()) {
      'k' => 1024,
      'm' => 1024 * 1024,
      'g' => 1024 * 1024 * 1024,
      _ => 1,
    };
    value *= factor;
  }
  if (!suffix && value < 0 && label != 'm' && label != 'max-count') {
    final kind = long ? 'option' : 'switch';
    throw GitUsage("error: $kind `$label' expects a numerical value\n");
  }
  return value;
}

void _addPattern(_Parsed parsed, String text, _Where where) {
  parsed.sawPattern = true;
  if (!text.contains('\n')) {
    parsed.builder.addAtom(_Pat(text, where));
    return;
  }
  final lines = text.split('\n');
  for (final line in lines) {
    if (line.isEmpty) continue;
    parsed.builder.addAtom(_Pat(line, where));
  }
}

Future<void> _addFile(AppletIo io, _Parsed parsed, String name) async {
  final absolute = name.startsWith('/')
      ? p.normalize(name)
      : p.normalize(p.join(io.cwd, name));
  final file = File(absolute);
  if (!await file.exists()) {
    throw GitUsage(
      "fatal: cannot open '$name': No such file or directory\n",
      exitCode: 128,
    );
  }
  final bytes = await file.readAsBytes();
  parsed.sawPattern = true;
  final lines = _bytesLines(bytes);
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    if (line.isEmpty) continue;
    parsed.builder.addAtom(
      _Pat(line, _Where.file, file: name, line: index + 1),
    );
  }
}

void _rejectConflicts(_Parsed parsed) {
  if (parsed.cached && parsed.untracked) {
    throw const GitUsage(
      "fatal: options '--untracked' and '--cached' cannot be used together\n",
      exitCode: 128,
    );
  }
  if (parsed.noIndex && parsed.cached) {
    throw const GitUsage(
      "fatal: options '--no-index' and '--cached' cannot be used together\n",
      exitCode: 128,
    );
  }
  if (parsed.noIndex && parsed.untracked) {
    throw const GitUsage(
      "fatal: options '--no-index' and '--untracked' cannot be used together\n",
      exitCode: 128,
    );
  }
}

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

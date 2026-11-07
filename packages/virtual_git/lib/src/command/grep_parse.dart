// ignore_for_file: avoid-substring
// Причина: шаблоны и пути режутся по индексам разбора, это не пользовательский текст.
part of '../git_grep.dart';

/// Разбор опций `git grep`.
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

// ignore_for_file: avoid-substring
// Причина: шаблоны и пути режутся по индексам разбора, это не пользовательский текст.
part of '../git_grep.dart';

/// Образцы grep: BRE/ERE, скобки и логические связки.
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

import 'package:probably_works/host/virtual/shell/applets/applet.dart';
import 'package:probably_works/host/virtual/shell/shell_io.dart';
import 'package:probably_works/host/virtual/vfs_store.dart';

/// Апплеты `test` и `[`: проверки строк, чисел и файлов. Код 0 — истина, 1 — ложь, 2 — ошибка синтаксиса,
/// как у POSIX test.
final List<Applet> testApplets = [const _Test(), const _Bracket()];

/// `test EXPR`.
final class _Test implements Applet {
  const _Test();

  @override
  String get name => 'test';

  @override
  Future<int> run(AppletIo io, List<String> args) => _evaluate(io, name, args);
}

/// `[ EXPR ]`: то же, что `test`, но последний аргумент обязан быть `]`.
final class _Bracket implements Applet {
  const _Bracket();

  @override
  String get name => '[';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    if (args.isEmpty || args.last != ']') {
      io.stderr.writeText("[: missing ']'\n");
      return 2;
    }
    return _evaluate(io, name, args.sublist(0, args.length - 1));
  }
}

/// Разбирает и вычисляет выражение. Ошибки разбора и числовых сравнений дают код 2.
Future<int> _evaluate(AppletIo io, String name, List<String> args) async {
  try {
    final expr = _TestParser(args).parse();
    return await _eval(io, expr) ? 0 : 1;
  } on _TestSyntax catch (e) {
    io.stderr.writeText('$name: ${e.message}\n');
    return 2;
  }
}

/// Выражение `test`: логические операторы, сравнения и проверки.
sealed class _Expr {
  const _Expr();
}

final class _Literal extends _Expr {
  const _Literal(this.text);

  /// Строка, истинная если непуста: одиночный аргумент `test STRING`.
  final String text;
}

final class _Unary extends _Expr {
  const _Unary(this.op, this.arg);

  final String op;
  final String arg;
}

final class _Binary extends _Expr {
  const _Binary(this.left, this.op, this.right);

  final String left;
  final String op;
  final String right;
}

final class _Negate extends _Expr {
  const _Negate(this.inner);

  final _Expr inner;
}

final class _Both extends _Expr {
  const _Both(this.left, this.right);

  final _Expr left;
  final _Expr right;
}

final class _Either extends _Expr {
  const _Either(this.left, this.right);

  final _Expr left;
  final _Expr right;
}

/// Пустое выражение `test` (без аргументов): ложь.
final class _Nothing extends _Expr {
  const _Nothing();
}

/// Ошибка разбора `test`: код 2 и сообщение, как у POSIX.
final class _TestSyntax implements Exception {
  const _TestSyntax(this.message);

  final String message;
}

const _unaryOps = {
  '-n',
  '-z',
  '-e',
  '-f',
  '-d',
  '-s',
  '-L',
  '-h',
  '-r',
  '-w',
  '-x',
};

const _stringOps = {'=', '==', '!=', '<', '>'};
const _intOps = {'-eq', '-ne', '-lt', '-le', '-gt', '-ge'};

/// Разбор `test` по POSIX: `or := and ('-o' and)*`, `and := not ('-a' not)*`, `not := '!' not | primary`.
/// Примитив выбирается по числу оставшихся аргументов, поэтому `test -n` (строка `-n`) остаётся строкой.
final class _TestParser {
  _TestParser(this._args);

  final List<String> _args;
  int _pos = 0;

  _Expr parse() {
    if (_args.isEmpty) return const _Nothing();
    final expr = _or();
    if (_pos < _args.length) {
      throw _TestSyntax("extra argument '${_args[_pos]}'");
    }
    return expr;
  }

  _Expr _or() {
    var left = _and();
    while (_peek == '-o') {
      _pos++;
      left = _Either(left, _and());
    }
    return left;
  }

  _Expr _and() {
    var left = _not();
    while (_peek == '-a') {
      _pos++;
      left = _Both(left, _not());
    }
    return left;
  }

  _Expr _not() {
    if (_peek == '!' && _remaining > 1) {
      _pos++;
      return _Negate(_not());
    }
    return _primary();
  }

  _Expr _primary() {
    final remaining = _remaining;
    final token = _args[_pos];
    if (token == '(' && remaining > 1) {
      _pos++;
      final inner = _or();
      if (_peek != ')') throw const _TestSyntax("missing ')'");
      _pos++;
      return inner;
    }
    if (_unaryOps.contains(token) && remaining >= 2) {
      _pos += 2;
      return _Unary(token, _args[_pos - 1]);
    }
    if (remaining >= 3) {
      final op = _args[_pos + 1];
      if (_stringOps.contains(op) || _intOps.contains(op)) {
        _pos += 3;
        return _Binary(token, op, _args[_pos - 1]);
      }
    }
    if (remaining == 1 || _connectives.contains(_args[_pos + 1])) {
      _pos++;
      return _Literal(token);
    }
    if (remaining == 2) throw _TestSyntax('$token: unary operator expected');
    throw _TestSyntax('${_args[_pos + 1]}: binary operator expected');
  }

  int get _remaining => _args.length - _pos;

  String? get _peek => _pos < _args.length ? _args[_pos] : null;
}

/// Токены, которые завершают операнд строки: за строкой может идти связка или закрывающая скобка.
const _connectives = {'-a', '-o', ')'};

Future<bool> _eval(AppletIo io, _Expr expr) async => switch (expr) {
  _Nothing() => false,
  _Literal(:final text) => text.isNotEmpty,
  _Negate(:final inner) => !await _eval(io, inner),
  _Both(:final left, :final right) =>
    await _eval(io, left) && await _eval(io, right),
  _Either(:final left, :final right) =>
    await _eval(io, left) || await _eval(io, right),
  _Unary(:final op, :final arg) => await _unary(io, op, arg),
  _Binary(:final left, :final op, :final right) => _binary(left, op, right),
};

Future<bool> _unary(AppletIo io, String op, String arg) async {
  if (op == '-n') return arg.isNotEmpty;
  if (op == '-z') return arg.isEmpty;
  final node = await io.fs.stat(
    arg,
    cwd: io.cwd,
    followLast: op != '-L' && op != '-h',
  );
  if (node == null) return false;
  return switch (op) {
    '-e' => true,
    '-f' => node.kind == VfsNodeKind.file,
    '-d' => node.kind == VfsNodeKind.dir,
    '-s' => node.kind != VfsNodeKind.dir && node.size > 0,
    '-L' || '-h' => node.kind == VfsNodeKind.symlink,
    // Права владельца: у единственного пользователя Host проверки совпадают с его битами.
    '-r' => (node.mode & 0x100) != 0,
    '-w' => (node.mode & 0x80) != 0,
    '-x' => (node.mode & 0x40) != 0,
    _ => false,
  };
}

bool _binary(String left, String op, String right) {
  if (_intOps.contains(op)) {
    final a = _integer(left);
    final b = _integer(right);
    return switch (op) {
      '-eq' => a == b,
      '-ne' => a != b,
      '-lt' => a < b,
      '-le' => a <= b,
      '-gt' => a > b,
      _ => a >= b,
    };
  }
  return switch (op) {
    '=' || '==' => left == right,
    '!=' => left != right,
    '<' => left.compareTo(right) < 0,
    _ => left.compareTo(right) > 0,
  };
}

/// Целое для `-eq` и родственных. Не число — ошибка выполнения, код 2 (через исключение).
int _integer(String text) {
  final value = int.tryParse(text.trim());
  if (value == null) throw _TestSyntax("integer expression expected: '$text'");
  return value;
}

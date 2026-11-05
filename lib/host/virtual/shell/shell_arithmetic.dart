import 'package:probably_works/host/virtual/shell/shell_errors.dart';

/// Вычисление выражения `$((...))` в целых числах со знаком, как в bash (64 бита).
///
/// Поддерживаются числа (десятичные, `0x...`, восьмеричные с ведущим нулём), имена переменных без `$`
/// (неустановленная или пустая переменная равна 0, значение-строка вычисляется как выражение), унарные
/// `+ - ! ~`, бинарные `* / % + - << >> < <= > >= == != & ^ | && ||`, `?:` и скобки. Выражение без
/// побочных эффектов: вычисление в непринятой ветке `&&`, `||` и `?:` пропускается, поэтому деление на ноль
/// там не ошибка, как в bash.
///
/// Присваивания (`=`, `+=`) и инкремент (`++`, `--`) не поддерживаются: это явная ошибка, а не молчаливое
/// отличие от bash.
abstract final class ShellArithmetic {
  const ShellArithmetic._();

  /// Предел косвенных вычислений переменных (`a=b`, `b=a`): защита от бесконечной рекурсии.
  static const _maxIndirection = 16;

  /// Вычисляет [source]. [lookup] отдаёт значение переменной или null, если её нет.
  /// Ошибки разбора и деление на ноль — [ShellRuntimeError].
  static int evaluate(String source, String? Function(String name) lookup) =>
      _evaluate(source, lookup, 0);

  static int _evaluate(
    String source,
    String? Function(String name) lookup,
    int indirection,
  ) {
    if (indirection > _maxIndirection) {
      throw ShellRuntimeError('$source: expression recursion level exceeded');
    }
    final parser = _Parser(source, lookup, indirection);
    return parser.parseAll();
  }
}

/// Лексема выражения. Для числа заполнен [value], для имени и оператора — [text].
final class _Token {
  const _Token(this.kind, this.text, this.start, {this.value = 0});

  /// `number`, `name`, `op` или `end`.
  final String kind;
  final String text;

  /// Позиция в исходной строке: сообщение об ошибке печатает остаток выражения с этого места.
  final int start;
  final int value;
}

/// Рекурсивный спуск по приоритетам. [_skip] > 0 означает, что результат ветки не нужен: ошибки
/// деления в ней не возникают.
final class _Parser {
  _Parser(this._source, this._lookup, this._indirection)
    : _tokens = _tokenize(_source);

  final String _source;
  final String? Function(String name) _lookup;
  final int _indirection;
  final List<_Token> _tokens;
  int _at = 0;
  int _skip = 0;

  /// Операторы от длинных к коротким: первым совпадает самый длинный.
  static const _operators = [
    '**',
    '<<',
    '>>',
    '<=',
    '>=',
    '==',
    '!=',
    '&&',
    '||',
    '+',
    '-',
    '*',
    '/',
    '%',
    '<',
    '>',
    '&',
    '|',
    '^',
    '!',
    '~',
    '(',
    ')',
    '?',
    ':',
  ];

  /// Инкремент и составные присваивания. Проверяются раньше обычных операторов: иначе `++` разрезалось бы
  /// на два `+` и выражение `5++3` молча давало бы 8 вместо ошибки bash.
  static const _unsupported = {'++', '--', '+=', '-=', '*=', '/=', '%='};

  static List<_Token> _tokenize(String source) {
    final tokens = <_Token>[];
    var i = 0;
    while (i < source.length) {
      final c = source[i];
      if (c == ' ' || c == '\t' || c == '\n') {
        i++;
        continue;
      }
      if (_isDigit(c)) {
        var end = i;
        while (end < source.length && _isWordChar(source[end])) {
          end++;
        }
        tokens.add(
          _Token(
            'number',
            _slice(source, i, end),
            i,
            value: _parseNumber(source, _slice(source, i, end), i),
          ),
        );
        i = end;
        continue;
      }
      if (_isNameStart(c)) {
        var end = i;
        while (end < source.length && _isWordChar(source[end])) {
          end++;
        }
        tokens.add(_Token('name', _slice(source, i, end), i));
        i = end;
        continue;
      }
      final op = _operatorAt(source, i);
      if (op == null) {
        throw ShellRuntimeError(_syntax(source, i));
      }
      if (op == '=' || _unsupported.contains(op)) {
        throw ShellRuntimeError(
          '$source: unsupported syntax: arithmetic assignment or increment',
        );
      }
      tokens.add(_Token('op', op, i));
      i += op.length;
    }
    tokens.add(_Token('end', '', source.length));
    return tokens;
  }

  /// Оператор в позиции [i] или null. Неподдерживаемые присваивания и инкремент идут первыми; одиночное `=`
  /// — после обычных операторов, потому что `==` и `<=` обычные. Любой из них даёт явную ошибку.
  static String? _operatorAt(String source, int i) {
    for (final op in _unsupported) {
      if (source.startsWith(op, i)) return op;
    }
    for (final op in _operators) {
      if (source.startsWith(op, i)) return op;
    }
    if (source.startsWith('=', i)) return '=';
    return null;
  }

  static int _parseNumber(String source, String text, int start) {
    final lower = text.toLowerCase();
    final int? value;
    if (lower.startsWith('0x')) {
      value = lower.length > 2
          ? int.tryParse(_slice(lower, 2), radix: 16)
          : null;
    } else if (text.length > 1 && text.startsWith('0')) {
      value = int.tryParse(text, radix: 8);
    } else {
      value = int.tryParse(text);
    }
    if (value == null) {
      throw ShellRuntimeError(_syntax(source, start));
    }
    return value;
  }

  static bool _isDigit(String c) =>
      c.compareTo('0') >= 0 && c.compareTo('9') <= 0;

  static bool _isNameStart(String c) =>
      c == '_' ||
      (c.compareTo('a') >= 0 && c.compareTo('z') <= 0) ||
      (c.compareTo('A') >= 0 && c.compareTo('Z') <= 0);

  static bool _isWordChar(String c) => _isNameStart(c) || _isDigit(c);

  /// Сообщение, как у bash: остаток выражения с места ошибки.
  static String _syntax(String source, int at) =>
      '$source: syntax error: operand expected '
      '(error token is "${_slice(source, at)}")';

  int parseAll() {
    final value = _ternary();
    if (_peek.kind != 'end') throw _error(_peek);
    return value;
  }

  _Token get _peek => _tokens[_at];

  bool _isOp(String op) => _peek.kind == 'op' && _peek.text == op;

  ShellRuntimeError _error(_Token token) =>
      ShellRuntimeError(_syntax(_source, token.start));

  void _expectOp(String op) {
    if (!_isOp(op)) throw _error(_peek);
    _at++;
  }

  /// Выполняет [parse] без вычисления результата: деление на ноль там не ошибка.
  int _unevaluated(int Function() parse) {
    _skip++;
    try {
      return parse();
    } finally {
      _skip--;
    }
  }

  int _ternary() {
    final condition = _logicalOr();
    if (!_isOp('?')) return condition;
    _at++;
    final int whenTrue;
    final int whenFalse;
    if (condition != 0) {
      whenTrue = _ternary();
      _expectOp(':');
      whenFalse = _unevaluated(_ternary);
    } else {
      whenTrue = _unevaluated(_ternary);
      _expectOp(':');
      whenFalse = _ternary();
    }
    return condition != 0 ? whenTrue : whenFalse;
  }

  int _logicalOr() {
    var value = _logicalAnd();
    while (_isOp('||')) {
      _at++;
      final right = value != 0 ? _unevaluated(_logicalAnd) : _logicalAnd();
      value = (value != 0 || right != 0) ? 1 : 0;
    }
    return value;
  }

  int _logicalAnd() {
    var value = _bitOr();
    while (_isOp('&&')) {
      _at++;
      final right = value == 0 ? _unevaluated(_bitOr) : _bitOr();
      value = (value != 0 && right != 0) ? 1 : 0;
    }
    return value;
  }

  int _bitOr() {
    var value = _bitXor();
    while (_isOp('|')) {
      _at++;
      value |= _bitXor();
    }
    return value;
  }

  int _bitXor() {
    var value = _bitAnd();
    while (_isOp('^')) {
      _at++;
      value ^= _bitAnd();
    }
    return value;
  }

  int _bitAnd() {
    var value = _equality();
    while (_isOp('&')) {
      _at++;
      value &= _equality();
    }
    return value;
  }

  int _equality() {
    var value = _relational();
    while (_isOp('==') || _isOp('!=')) {
      final equal = _advance().text == '==';
      final right = _relational();
      value = (value == right) == equal ? 1 : 0;
    }
    return value;
  }

  int _relational() {
    var value = _shift();
    while (_isOp('<') || _isOp('<=') || _isOp('>') || _isOp('>=')) {
      final op = _advance().text;
      final right = _shift();
      final holds = switch (op) {
        '<' => value < right,
        '<=' => value <= right,
        '>' => value > right,
        _ => value >= right,
      };
      value = holds ? 1 : 0;
    }
    return value;
  }

  int _shift() {
    var value = _additive();
    while (_isOp('<<') || _isOp('>>')) {
      final left = _advance().text == '<<';
      final count = _additive();
      if (count < 0) {
        throw const ShellRuntimeError('negative shift count');
      }
      value = left ? value << count : value >> count;
    }
    return value;
  }

  int _additive() {
    var value = _multiplicative();
    while (_isOp('+') || _isOp('-')) {
      final add = _advance().text == '+';
      final right = _multiplicative();
      value = add ? value + right : value - right;
    }
    return value;
  }

  int _multiplicative() {
    var value = _power();
    while (_isOp('*') || _isOp('/') || _isOp('%')) {
      final op = _advance();
      final right = _power();
      value = switch (op.text) {
        '*' => value * right,
        _ => _divide(value, right, op.text == '%'),
      };
    }
    return value;
  }

  /// Деление с усечением к нулю, как в C и bash; остаток имеет знак делимого. На нуле — ошибка, если
  /// результат нужен.
  int _divide(int left, int right, bool remainder) {
    if (right == 0) {
      if (_skip > 0) return 0;
      throw ShellRuntimeError(
        '$_source: division by 0 (error token is "${_slice(_source, _tokens[_at - 1].start)}")',
      );
    }
    return remainder ? left.remainder(right) : left ~/ right;
  }

  /// `**` правоассоциативна. Отрицательная степень в целых — ошибка, как у bash.
  int _power() {
    final base = _unary();
    if (!_isOp('**')) return base;
    _at++;
    final exponent = _power();
    if (exponent < 0) {
      throw ShellRuntimeError('$_source: exponent less than 0');
    }
    var result = 1;
    var factor = base;
    var rest = exponent;
    while (rest > 0) {
      if (rest.isOdd) result *= factor;
      factor *= factor;
      rest ~/= 2;
    }
    return result;
  }

  int _unary() {
    if (_isOp('+')) {
      _at++;
      return _unary();
    }
    if (_isOp('-')) {
      _at++;
      return -_unary();
    }
    if (_isOp('!')) {
      _at++;
      return _unary() == 0 ? 1 : 0;
    }
    if (_isOp('~')) {
      _at++;
      return ~_unary();
    }
    return _primary();
  }

  int _primary() {
    final token = _peek;
    if (token.kind == 'number') {
      _at++;
      return token.value;
    }
    if (token.kind == 'name') {
      _at++;
      return _variable(token.text);
    }
    if (_isOp('(')) {
      _at++;
      final value = _ternary();
      _expectOp(')');
      return value;
    }
    throw _error(token);
  }

  /// Значение переменной: неустановленная или пустая — 0, число — оно, иначе — выражение, которое
  /// вычисляется рекурсивно (`x='1+2'; $((x*2))` даёт 6, как в bash).
  int _variable(String name) {
    final value = _lookup(name);
    if (value == null || value.trim().isEmpty) return 0;
    return ShellArithmetic._evaluate(value.trim(), _lookup, _indirection + 1);
  }

  _Token _advance() {
    final token = _peek;
    _at++;
    return token;
  }
}

/// Срез по единицам UTF-16. Лексер и парсер считают позиции в тех же единицах (`source[i]`), поэтому срез
/// согласован с ними и не расходится с позициями токенов.
String _slice(String text, int start, [int? end]) =>
    String.fromCharCodes(text.codeUnits, start, end);

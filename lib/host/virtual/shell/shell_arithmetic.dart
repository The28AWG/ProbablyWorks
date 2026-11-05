import 'package:probably_works/host/virtual/shell/shell_errors.dart';
import 'package:probably_works/host/virtual/shell/shell_text.dart';

/// Чтение переменной для вычислителя. [subscript] — текст индекса (`i+1` в `a[i+1]`) без вычисления или null,
/// если ссылка без индекса. Возвращает значение или null, если переменной либо элемента нет.
typedef ArithmeticRead = String? Function(String name, String? subscript);

/// Запись результата присваивания или инкремента. [value] уже вычислено и передаётся десятичной строкой.
typedef ArithmeticWrite = void Function(
  String name,
  String? subscript,
  String value,
);

/// Вычисление арифметических выражений оболочки по правилам bash: 64-битные целые со знаком, переполнение
/// переносится по модулю 2^64, сдвиг берёт счётчик по модулю 64, как процессор (`1 << 64` даёт 1).
///
/// Поддерживаются: числа (десятичные, `0x`, восьмеричные с ведущим нулём, `base#digits` для оснований 2–64,
/// где цифры `0-9a-z`, затем `A-Z` (для основания до 36 регистр не важен), `@` и `_`), имена переменных и
/// элементы `a[i]` (индекс — выражение, для ассоциативного массива строка), унарные `+ - ! ~`, префиксный и
/// постфиксный `++`/`--` у переменных, бинарные операторы в порядке приоритетов bash, `?:`, запятая,
/// присваивания `= += -= *= /= %= <<= >>= &= |= ^=`.
///
/// Вычисление идёт сразу при разборе, как в bash. Ветка, которую не выбрали `&&`, `||` или `?:`, не
/// вычисляется: в ней нет записей и ошибок деления. Записи переменных идут через [ArithmeticWrite]: сама
/// оболочка их не делает, поэтому выражение не знает про [ShellState].
///
/// Ошибки разбора и вычисления бросаются как [ShellRuntimeError] с текстом bash. Исключения из [read] и
/// [write] (например, `readonly`) проходят без изменений.
abstract final class ShellArithmetic {
  const ShellArithmetic._();

  /// Предел косвенных вычислений переменных (`a=b`, `b=a`): защита от бесконечной рекурсии.
  static const _maxIndirection = 16;

  /// Вычисляет [source] и возвращает значение. [read] отдаёт значения переменных, [write] принимает
  /// присваивания. [context] — префикс сообщения об ошибке: `((` для арифметической команды, `let` для
  /// встроенной команды; null для `$((...))`.
  ///
  /// Пустое выражение равно 0. Текст сообщения повторяет bash: `source: message (error token is "...")`.
  static int evaluate(
    String source,
    ArithmeticRead read,
    ArithmeticWrite write, {
    String? context,
  }) => _evaluate(source, read, write, context, 0);

  static int _evaluate(
    String source,
    ArithmeticRead read,
    ArithmeticWrite write,
    String? context,
    int indirection,
  ) {
    if (indirection > _maxIndirection) {
      throw ShellRuntimeError(
        '${_prefix(context)}$source: expression recursion level exceeded',
      );
    }
    return _Parser(source, read, write, context, indirection).parseAll();
  }

  /// Префикс сообщения: `((: ` или `let: `, пусто для `$((...))`.
  static String _prefix(String? context) => context == null ? '' : '$context: ';
}

/// Вид лексемы выражения.
enum _Kind {
  /// Число; значение в [_Token.value].
  number,

  /// Имя переменной; индекс в [_Token.subscript], если он был.
  name,

  /// Оператор или скобка; текст — сам оператор.
  op,

  /// Конец выражения.
  end,

  /// Недопустимая лексема. Ошибка возникает только тогда, когда разбор до неё дошёл, как у bash.
  invalid,
}

/// Лексема выражения. [start] и [end] — диапазон в исходной строке.
final class _Token {
  const _Token(
    this.kind,
    this.text,
    this.start,
    this.end, {
    this.value = 0,
    this.subscript,
    this.message,
    this.errorToken,
  });

  final _Kind kind;
  final String text;
  final int start;
  final int end;

  /// Значение числа.
  final int value;

  /// Текст индекса у имени: `a[i]` даёт `i`.
  final String? subscript;

  /// Для недопустимой лексемы: текст ошибки без префикса.
  final String? message;

  /// Что печатается как error token. null — остаток строки с [start], как у большинства ошибок bash.
  final String? errorToken;
}

/// Рекурсивный спуск по приоритетам bash с вычислением на ходу. [_skip] больше нуля, пока ветка не выбрана:
/// тогда присваивания не записываются, а деление на ноль и отрицательная степень не дают ошибки.
final class _Parser {
  _Parser(
    this._source,
    this._read,
    this._write,
    this._context,
    this._indirection,
  ) : _tokens = _tokenize(_source);

  final String _source;
  final ArithmeticRead _read;
  final ArithmeticWrite _write;
  final String? _context;
  final int _indirection;
  final List<_Token> _tokens;
  int _at = 0;
  int _skip = 0;

  /// Бинарные операторы от длинных к коротким: первым совпадает самый длинный.
  static const _operators = [
    '<<=',
    '>>=',
    '<<',
    '>>',
    '<=',
    '>=',
    '==',
    '!=',
    '&&',
    '||',
    '**',
    '+=',
    '-=',
    '*=',
    '/=',
    '%=',
    '&=',
    '|=',
    '^=',
    '=',
    '<',
    '>',
    '&',
    '|',
    '^',
    '+',
    '-',
    '*',
    '/',
    '%',
    '!',
    '~',
    '(',
    ')',
    '?',
    ':',
    ',',
  ];

  static const _assignOps = {
    '=',
    '+=',
    '-=',
    '*=',
    '/=',
    '%=',
    '<<=',
    '>>=',
    '&=',
    '|=',
    '^=',
  };

  /// Лексемы, которые могут начинать операнд: нужны для сообщения `expression expected` у `?:`.
  static const _operandStarts = {'(', '+', '-', '!', '~', '++', '--'};

  /// Разбирает и вычисляет всё выражение. Остаток после него — ошибка, как у bash.
  int parseAll() {
    if (_peek.kind == _Kind.end) return 0;
    final value = _comma();
    if (_peek.kind != _Kind.end) {
      throw _error('arithmetic syntax error in expression', _peek.start);
    }
    return value;
  }

  // Лексер.

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
        final number = _number(source, i);
        tokens.add(number);
        i = number.end;
        continue;
      }
      if (_isNameStart(c)) {
        final name = _name(source, i);
        if (name == null) {
          tokens.add(
            _Token(
              _Kind.invalid,
              '',
              i,
              source.length,
              message: 'arithmetic syntax error: invalid arithmetic operator',
            ),
          );
          break;
        }
        tokens.add(name);
        i = name.end;
        continue;
      }
      if ((c == '+' || c == '-') &&
          i + 1 < source.length &&
          source[i + 1] == c) {
        // `++` и `--` — инкремент только у переменной, перед которой или после которой он стоит. После
        // значения (`5++3`) это два знака: `5 + +3`, как в bash.
        if (tokens.isNotEmpty && _endsValue(tokens.last)) {
          tokens.add(_Token(_Kind.op, c, i, i + 1));
          i++;
        } else {
          tokens.add(_Token(_Kind.op, '$c$c', i, i + 2));
          i += 2;
        }
        continue;
      }
      final op = _operatorAt(source, i);
      if (op != null) {
        tokens.add(_Token(_Kind.op, op, i, i + op.length));
        i += op.length;
        continue;
      }
      // Кавычка в выражении — не оператор, а операнд, который не принят: как у bash, ошибка операнда.
      tokens.add(
        c == "'"
            ? _Token(
                _Kind.invalid,
                '',
                i,
                source.length,
                message: 'arithmetic syntax error: operand expected',
              )
            : _Token(
                _Kind.invalid,
                '',
                i,
                source.length,
                message: 'arithmetic syntax error: invalid arithmetic operator',
              ),
      );
      break;
    }
    tokens.add(_Token(_Kind.end, '', source.length, source.length));
    return tokens;
  }

  /// Число с первой цифры: десятичное, `0x`, восьмеричное или `base#digits`. Ошибку возвращает как
  /// недопустимую лексему с текстом самого числа в error token.
  static _Token _number(String source, int start) {
    var end = start;
    while (end < source.length && _isWordChar(source[end])) {
      end++;
    }
    final word = ShellText.cut(source, start, end);
    if (end < source.length && source[end] == '#') {
      var digitsEnd = end + 1;
      while (digitsEnd < source.length &&
          (_isWordChar(source[digitsEnd]) || source[digitsEnd] == '@')) {
        digitsEnd++;
      }
      return _baseNumber(
        ShellText.cut(source, start, digitsEnd),
        start,
        digitsEnd,
        word,
        ShellText.cut(source, end + 1, digitsEnd),
      );
    }
    return _plainNumber(word, start, end);
  }

  /// `base#digits`. Основание — десятичное число от 2 до 64 без ведущего нуля (`10#08` верно, `010#10` нет).
  static _Token _baseNumber(
    String lexeme,
    int start,
    int end,
    String baseText,
    String digits,
  ) {
    _Token invalid(String message) => _Token(
      _Kind.invalid,
      lexeme,
      start,
      end,
      message: message,
      errorToken: lexeme,
    );
    if (baseText.startsWith('0') || !_isDecimal(baseText)) {
      return invalid('invalid number');
    }
    final base = int.tryParse(baseText);
    if (base == null || base < 2 || base > 64) {
      return invalid('invalid arithmetic base');
    }
    if (digits.isEmpty) return invalid('invalid integer constant');
    final value = _parseRadix(digits, base);
    if (value == null) return invalid('value too great for base');
    return _Token(_Kind.number, lexeme, start, end, value: value);
  }

  /// Число без основания: `0x` (шестнадцатеричное, пустое — 0), `0` с цифрами (восьмеричное), иначе десятичное.
  static _Token _plainNumber(String word, int start, int end) {
    final int radix;
    final String digits;
    if (word.length > 1 &&
        word[0] == '0' &&
        (word[1] == 'x' || word[1] == 'X')) {
      radix = 16;
      digits = ShellText.cut(word, 2);
    } else if (word.length > 1 && word[0] == '0') {
      radix = 8;
      digits = ShellText.cut(word, 1);
    } else {
      radix = 10;
      digits = word;
    }
    final value = _parseRadix(digits, radix);
    if (value == null) {
      return _Token(
        _Kind.invalid,
        word,
        start,
        end,
        message: 'value too great for base',
        errorToken: word,
      );
    }
    return _Token(_Kind.number, word, start, end, value: value);
  }

  /// Имя с необязательным `[индекс]`. null, если `[` не закрыта.
  static _Token? _name(String source, int start) {
    var end = start + 1;
    while (end < source.length && _isWordChar(source[end])) {
      end++;
    }
    final name = ShellText.cut(source, start, end);
    if (end >= source.length || source[end] != '[') {
      return _Token(_Kind.name, name, start, end);
    }
    final close = _closingBracket(source, end);
    if (close < 0) return null;
    return _Token(
      _Kind.name,
      name,
      start,
      close + 1,
      subscript: ShellText.cut(source, end + 1, close),
    );
  }

  /// Индекс `]`, парного `[` в позиции [open], с учётом вложенных `[`. -1, если пары нет.
  static int _closingBracket(String source, int open) {
    var depth = 0;
    for (var i = open; i < source.length; i++) {
      if (source[i] == '[') {
        depth++;
      } else if (source[i] == ']') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  /// Оператор в позиции [i] или null.
  static String? _operatorAt(String source, int i) {
    for (final op in _operators) {
      if (source.startsWith(op, i)) return op;
    }
    return null;
  }

  /// Лексема, после которой `++` или `--` — это два знака, а не инкремент: число или `)`.
  static bool _endsValue(_Token token) =>
      token.kind == _Kind.number ||
      (token.kind == _Kind.op && token.text == ')');

  /// Значение цифр [digits] в основании [radix] с переносом по модулю 2^64. null — есть цифра не из основания.
  static int? _parseRadix(String digits, int radix) {
    var value = 0;
    for (final unit in digits.codeUnits) {
      final digit = _digitValue(unit, radix);
      if (digit >= radix) return null;
      value = value * radix + digit;
    }
    return value;
  }

  /// Значение символа как цифры. Для основания до 36 регистр не важен; выше строчные — 10–35, заглавные — 36–61.
  static int _digitValue(int unit, int radix) {
    if (unit >= 0x30 && unit <= 0x39) return unit - 0x30;
    if (unit >= 0x61 && unit <= 0x7a) return unit - 0x61 + 10;
    if (unit >= 0x41 && unit <= 0x5a) {
      return (radix <= 36 ? 10 : 36) + unit - 0x41;
    }
    if (unit == 0x40) return 62;
    return 63;
  }

  static bool _isDecimal(String text) =>
      text.isNotEmpty && text.codeUnits.every((u) => u >= 0x30 && u <= 0x39);

  static bool _isDigit(String c) =>
      c.compareTo('0') >= 0 && c.compareTo('9') <= 0;

  static bool _isNameStart(String c) =>
      c == '_' ||
      (c.compareTo('a') >= 0 && c.compareTo('z') <= 0) ||
      (c.compareTo('A') >= 0 && c.compareTo('Z') <= 0);

  static bool _isWordChar(String c) => _isNameStart(c) || _isDigit(c);

  // Доступ к лексемам и ошибки.

  _Token get _peek {
    final token = _tokens[_at];
    if (token.kind == _Kind.invalid) throw _invalid(token);
    return token;
  }

  _Token _advance() {
    final token = _peek;
    _at++;
    return token;
  }

  bool _isOp(String op) => _peek.kind == _Kind.op && _peek.text == op;

  /// Позиция для ошибки «ожидался операнд»: если выражение кончилось, bash показывает последнюю лексему.
  int _errorPosition() =>
      _peek.kind == _Kind.end && _at > 0 ? _tokens[_at - 1].start : _peek.start;

  ShellRuntimeError _error(String message, int position, {String? token}) {
    final shown = token ?? ShellText.cut(_source, position);
    return ShellRuntimeError(
      '${ShellArithmetic._prefix(_context)}$_source: $message '
      '(error token is "$shown")',
    );
  }

  ShellRuntimeError _invalid(_Token token) =>
      _error(token.message!, token.start, token: token.errorToken);

  /// Вычисляет [parse] без последствий: записи и деление на ноль в нём не происходят.
  int _skipped(int Function() parse) {
    _skip++;
    try {
      return parse();
    } finally {
      _skip--;
    }
  }

  /// Значение переменной: неустановленная или пустая — 0, число — оно, иначе выражение, которое
  /// вычисляется рекурсивно (`x='1+2'; $((x*2))` даёт 6, как в bash).
  int _variable(String name, String? subscript) {
    final value = _read(name, subscript);
    if (value == null || value.trim().isEmpty) return 0;
    return ShellArithmetic._evaluate(
      value.trim(),
      _read,
      _write,
      _context,
      _indirection + 1,
    );
  }

  /// Запись значения, если ветка выбрана.
  void _store(String name, String? subscript, int value) {
    if (_skip == 0) _write(name, subscript, '$value');
  }

  // Грамматика: от низкого приоритета к высокому.

  /// Запятая: значение последнего выражения.
  int _comma() {
    var value = _assign();
    while (_isOp(',')) {
      _at++;
      value = _assign();
    }
    return value;
  }

  /// Присваивание. Правая часть разбирается снова присваиванием, поэтому `a = b = 3` правоассоциативно.
  /// Слева допустима только переменная: `1 = 2` и `(x) = 2` — ошибка, как у bash.
  int _assign() {
    final target = _peek;
    if (target.kind == _Kind.name) {
      final next = _tokens[_at + 1];
      if (next.kind == _Kind.op && _assignOps.contains(next.text)) {
        _at += 2;
        final op = next.text;
        final old = op == '=' ? 0 : _variable(target.text, target.subscript);
        final rightStart = _peek.start;
        final right = _assign();
        final value = op == '='
            ? right
            : _apply(
                ShellText.cut(op, 0, op.length - 1),
                old,
                right,
                rightStart,
              );
        _store(target.text, target.subscript, value);
        return value;
      }
    }
    final value = _conditional();
    if (_peek.kind == _Kind.op && _assignOps.contains(_peek.text)) {
      throw _error('attempted assignment to non-variable', _peek.start);
    }
    return value;
  }

  /// `условие ? a : b`. Средняя ветка — запятая (в ней разрешено присваивание), правая — условное выражение.
  int _conditional() {
    final condition = _logicalOr();
    if (!_isOp('?')) return condition;
    _at++;
    final taken = condition != 0;
    final whenTrue = taken ? _branch(_comma) : _skipped(() => _branch(_comma));
    _expectColon();
    final whenFalse = taken
        ? _skipped(() => _branch(_conditional))
        : _branch(_conditional);
    return taken ? whenTrue : whenFalse;
  }

  /// Ветка `?:`: пустая ветка — своя ошибка `expression expected`, как у bash.
  int _branch(int Function() parse) {
    if (!_startsOperand()) {
      throw _error('expression expected', _errorPosition());
    }
    return parse();
  }

  void _expectColon() {
    if (!_isOp(':')) {
      throw _error("`:' expected for conditional expression", _errorPosition());
    }
    _at++;
  }

  bool _startsOperand() {
    final token = _peek;
    return switch (token.kind) {
      _Kind.number || _Kind.name => true,
      _Kind.op => _operandStarts.contains(token.text),
      _ => false,
    };
  }

  /// `||`. Правая часть не вычисляется, если левая уже истинна.
  int _logicalOr() {
    var value = _logicalAnd();
    while (_isOp('||')) {
      _at++;
      final right = value != 0 ? _skipped(_logicalAnd) : _logicalAnd();
      value = value != 0 || right != 0 ? 1 : 0;
    }
    return value;
  }

  /// `&&`. Правая часть не вычисляется, если левая ложна.
  int _logicalAnd() {
    var value = _bitOr();
    while (_isOp('&&')) {
      _at++;
      final right = value == 0 ? _skipped(_bitOr) : _bitOr();
      value = value != 0 && right != 0 ? 1 : 0;
    }
    return value;
  }

  int _bitOr() => _leftAssoc(_bitXor, const {'|'});

  int _bitXor() => _leftAssoc(_bitAnd, const {'^'});

  int _bitAnd() => _leftAssoc(_equality, const {'&'});

  int _equality() => _leftAssoc(_relational, const {'==', '!='});

  int _relational() => _leftAssoc(_shift, const {'<', '<=', '>', '>='});

  int _shift() => _leftAssoc(_additive, const {'<<', '>>'});

  int _additive() => _leftAssoc(_multiplicative, const {'+', '-'});

  int _multiplicative() => _leftAssoc(_power, const {'*', '/', '%'});

  /// Левоассоциативный бинарный уровень: [operand] — следующий уровень, [ops] — его операторы.
  int _leftAssoc(int Function() operand, Set<String> ops) {
    var value = operand();
    while (_peek.kind == _Kind.op && ops.contains(_peek.text)) {
      final op = _advance().text;
      final rightStart = _peek.start;
      value = _apply(op, value, operand(), rightStart);
    }
    return value;
  }

  /// Бинарная операция. [rightStart] — позиция правого операнда, с неё начинается error token деления.
  int _apply(String op, int left, int right, int rightStart) => switch (op) {
    '+' => left + right,
    '-' => left - right,
    '*' => left * right,
    '/' => _divide(left, right, rightStart, remainder: false),
    '%' => _divide(left, right, rightStart, remainder: true),
    '<<' => left << (right & 63),
    '>>' => left >> (right & 63),
    '&' => left & right,
    '|' => left | right,
    '^' => left ^ right,
    '<' => left < right ? 1 : 0,
    '<=' => left <= right ? 1 : 0,
    '>' => left > right ? 1 : 0,
    '>=' => left >= right ? 1 : 0,
    '==' => left == right ? 1 : 0,
    '!=' => left != right ? 1 : 0,
    _ => throw StateError('неизвестный оператор арифметики: $op'),
  };

  /// Деление с усечением к нулю; остаток имеет знак делимого. На нуле — ошибка, если результат нужен.
  int _divide(int left, int right, int rightStart, {required bool remainder}) {
    if (right == 0) {
      if (_skip > 0) return 0;
      throw _error('division by 0', rightStart);
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
      if (_skip > 0) return 0;
      throw _error('exponent less than 0', _tokens[_at - 1].start);
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

  /// Унарные операторы. `++` и `--` перед переменной — инкремент; перед числом — два унарных знака, как в bash.
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
    if (_isOp('++') || _isOp('--')) {
      final op = _advance().text;
      if (_peek.kind == _Kind.name) {
        final target = _advance();
        final value =
            _variable(target.text, target.subscript) + (op == '++' ? 1 : -1);
        _store(target.text, target.subscript, value);
        return value;
      }
      return _unary();
    }
    return _postfix();
  }

  /// Переменная с постфиксным `++`/`--` (значение до изменения) или первичное выражение.
  int _postfix() {
    final token = _peek;
    if (token.kind != _Kind.name) return _primary();
    _at++;
    final old = _variable(token.text, token.subscript);
    if (_isOp('++') || _isOp('--')) {
      final delta = _advance().text == '++' ? 1 : -1;
      _store(token.text, token.subscript, old + delta);
    }
    return old;
  }

  /// Число или выражение в скобках.
  int _primary() {
    final token = _peek;
    if (token.kind == _Kind.number) {
      _at++;
      return token.value;
    }
    if (_isOp('(')) {
      _at++;
      final value = _comma();
      if (!_isOp(')')) {
        throw _error('arithmetic syntax error in expression', _errorPosition());
      }
      _at++;
      return value;
    }
    throw _error('arithmetic syntax error: operand expected', _errorPosition());
  }
}

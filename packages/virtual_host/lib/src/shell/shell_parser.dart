import 'package:virtual_host/src/shell/shell_ast.dart';
import 'package:virtual_host/src/shell/shell_errors.dart';
import 'package:virtual_host/src/shell/shell_lexer.dart';
import 'package:virtual_host/src/shell/shell_scan.dart';
import 'package:virtual_host/src/shell/shell_text.dart';
import 'package:virtual_host/src/shell/shell_token.dart';
import 'package:virtual_host/src/shell/shell_word_parser.dart';
import 'package:virtual_host/src/virtual_limits.dart';

/// Рекурсивный разбор токенов в [ScriptNode]. Поддерживаемое подмножество задано здесь:
/// всё вне него отвергается с [ShellSyntaxException.unsupported], а не разбирается «как-нибудь».
///
/// Разбор всего скрипта выполняется до исполнения: как и bash, синтаксическая ошибка в любой строке
/// означает, что ни одна команда не запустилась.
final class ShellParser {
  ShellParser._(this._tokens, this._source, this._depth, this._limits);

  final String _source;

  final List<Token> _tokens;
  final int _depth;
  final VirtualLimits _limits;
  int _at = 0;

  /// Текущая глубина вложенных списков составных команд. Ограничивает рекурсию разбора.
  int _nesting = 0;

  /// Ключевые слова bash, которые виртуальный shell не поддерживает. В начале команды они дают явный отказ,
  /// а не запуск команды с таким именем.
  static const _unsupportedKeywords = {
    'time',
    'coproc',
    'shopt',
    'exec',
    'wait',
    'jobs',
    'kill',
    'bg',
    'fg',
    'umask',
    'ulimit',
    'times',
    'enable',
    'builtin',
    'caller',
    'history',
    'fc',
    'bind',
    'complete',
  };

  /// Слова, которые закрывают конструкцию. В начале команды вне своей конструкции это синтаксическая ошибка,
  /// как в bash.
  static const _closers = {
    'then',
    'elif',
    'else',
    'fi',
    'do',
    'done',
    'esac',
    '}',
    'in',
    ']]',
  };

  /// Операторы, которые лексер выдаёт, но которых в подмножестве нет: фон, `&>`, `<&`, `>|`, `<>`.
  static const _unsupportedOperators = {'&', '&>', '<&', '>|', '<>'};

  /// Команды, которых нет в модели. Отказ до запуска, в том числе после `NAME=value`.
  static const _rejectedCommands = {
    'shopt',
    'exec',
    'wait',
    'jobs',
    'kill',
    'bg',
    'fg',
    'umask',
    'ulimit',
    'times',
    'enable',
    'builtin',
    'caller',
    'history',
    'fc',
    'bind',
    'complete',
  };

  /// `**` и конструкции `?(`, `*(`, `+(`, `@(`, `!(`.
  static final _extglob = RegExp(r'\*\*|[*?+@!]\(');

  static const _redirectOperators = {'<', '>', '>>', '<<', '<<-', '<<<', '>&'};

  /// `NAME=значение` или `NAME+=значение` в начале команды. Значение может быть пустым.
  static final _assignment = RegExp(
    r'^([A-Za-z_][A-Za-z0-9_]*)(\+?)=(.*)$',
    dotAll: true,
  );

  /// Начало элемента `NAME[` — присваивание `NAME[индекс]=значение`. Закрывающую `]` ищет [ShellScan].
  static final _subscripted = RegExp(r'^([A-Za-z_][A-Za-z0-9_]*)\[');

  /// Слово, перед которым стоит `(`, — начало литерала массива: `NAME=`, `NAME+=`, `NAME[i]=`, `NAME[i]+=`.
  static final _arrayAssignmentHead = RegExp(
    r'^[A-Za-z_][A-Za-z0-9_]*(\[.*\])?\+?=$',
    dotAll: true,
  );

  /// Имя переменной цикла `for` и параметра функции: POSIX-идентификатор.
  static final _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  /// Имя функции: bash допускает точку, двоеточие и дефис. Остальное — ошибка.
  static final _functionName = RegExp(r'^[A-Za-z_][A-Za-z0-9_.:-]*$');

  /// Разбирает скрипт верхнего уровня.
  static ScriptNode parse(
    String source, {
    VirtualLimits limits = const VirtualLimits(),
  }) => _parseAt(source, 0, limits);

  /// Разбирает подстановку `$(...)` на глубине [depth]. Слишком глубокая вложенность — ошибка.
  static ScriptNode parseNested(
    String source,
    int depth,
    VirtualLimits limits,
  ) => _parseAt(source, depth, limits);

  static ScriptNode _parseAt(String source, int depth, VirtualLimits limits) {
    if (depth > limits.maxNestingDepth) {
      throw const ShellSyntaxException.unsupported(
        'command substitution nested too deeply',
      );
    }
    final tokens = ShellLexer(source).tokenize();
    return ShellParser._(tokens, source, depth, limits)._script();
  }

  Token get _peek => _tokens[_at];

  /// Токен на [offset] позиций вперёд. За концом — `eof`, последний элемент списка.
  Token _peekAt(int offset) {
    final index = _at + offset;
    return _tokens[index < _tokens.length ? index : _tokens.length - 1];
  }

  Token _advance() {
    final token = _tokens[_at];
    if (token.kind != TokenKind.eof) _at++;
    return token;
  }

  void _skipNewlines() {
    while (_peek.kind == TokenKind.newline) {
      _advance();
    }
  }

  bool _isWord(String text) =>
      _peek.kind == TokenKind.word && _peek.text == text;

  void _expectWord(String text) {
    if (!_isWord(text)) throw _unexpected(_peek);
    _advance();
  }

  void _expectOperator(String text) {
    if (!_peek.isOperator(text)) throw _unexpected(_peek);
    _advance();
  }

  /// Пустой список в месте, где нужна команда (`if ...; then fi`, `()`), — синтаксическая ошибка на
  /// закрывающем слове, как в bash.
  void _requireNonEmpty(ScriptNode body) {
    if (body.lists.isEmpty) throw _unexpected(_peek);
  }

  /// Скрипт верхнего уровня: разбирается до конца входа.
  ScriptNode _script() => _body(const {});

  /// Список команд до одного из ограничителей [stop] или до конца входа. Ограничитель проверяется только в
  /// начале команды: `echo fi` — аргумент, как и в bash.
  ScriptNode _body(Set<String> stop) {
    _nesting++;
    if (_nesting > _limits.maxCompoundNesting) {
      throw ShellLimitExceeded(
        'compound commands nested more than ${_limits.maxCompoundNesting} levels deep',
      );
    }
    try {
      final lists = <AndOrList>[];
      _skipNewlines();
      while (!_atListEnd(stop)) {
        lists.add(_andOr());
        final token = _peek;
        if (token.kind == TokenKind.newline || token.isOperator(';')) {
          _advance();
          _skipNewlines();
        } else if (!_atListEnd(stop)) {
          _rejectUnsupported(token);
          throw _unexpected(token);
        }
      }
      return ScriptNode(lists);
    } finally {
      _nesting--;
    }
  }

  /// Конец списка: конец входа или ограничитель. Ограничитель — слово или оператор с этим текстом.
  bool _atListEnd(Set<String> stop) {
    final token = _peek;
    if (token.kind == TokenKind.eof) return true;
    return (token.kind == TokenKind.word || token.kind == TokenKind.operator) &&
        stop.contains(token.text);
  }

  /// Оператор, который лексер выдал, но подмножество его не знает, — отказ, а не синтаксическая ошибка.
  void _rejectUnsupported(Token token) {
    if (token.kind == TokenKind.operator &&
        _unsupportedOperators.contains(token.text)) {
      throw ShellSyntaxException.unsupported(
        'operator ${token.text}',
        line: token.line,
      );
    }
  }

  AndOrList _andOr() {
    final pipelines = [_pipeline()];
    final operators = <AndOrOperator>[];
    while (_peek.isOperator('&&') || _peek.isOperator('||')) {
      operators.add(
        _advance().text == '&&' ? AndOrOperator.and : AndOrOperator.or,
      );
      _skipNewlines();
      pipelines.add(_pipeline());
    }
    return AndOrList(pipelines, operators);
  }

  Pipeline _pipeline() {
    final negated = _peek.kind == TokenKind.word && _peek.text == '!';
    if (negated) _advance();
    final commands = [_command()];
    while (_peek.isOperator('|')) {
      _advance();
      _skipNewlines();
      commands.add(_command());
    }
    if (commands.length > _limits.maxPipelineLength) {
      throw ShellLimitExceeded(
        'pipeline has more than ${_limits.maxPipelineLength} commands',
      );
    }
    return Pipeline(commands, negated: negated);
  }

  /// Одна команда: составная конструкция, определение функции или простая команда.
  ShellCommand _command() {
    final token = _peek;
    // `((...))` лексер уже отделил токеном; `( (...) )` с пробелом или без пары `))` — подоболочка.
    if (token.kind == TokenKind.arith) return _arithmeticCommand();
    if (token.isOperator('(')) return _subshell();
    if (token.kind == TokenKind.word) {
      final keyword = token.text;
      if (_unsupportedKeywords.contains(keyword)) {
        throw ShellSyntaxException.unsupported(keyword, line: token.line);
      }
      if (_closers.contains(keyword)) throw _unexpected(token);
      switch (keyword) {
        case 'if':
          return _if();
        case 'while':
          return _loop(until: false);
        case 'until':
          return _loop(until: true);
        case 'for':
          return _for();
        case 'select':
          return _select();
        case 'case':
          return _case();
        case '{':
          return _group();
        case 'function':
          return _functionKeyword();
        case '[[':
          return _conditional();
      }
      // `name()` — функция. `x=()` сюда не попадает: `=` не входит в имя, это пустой литерал массива.
      if (_functionName.hasMatch(keyword) &&
          _peekAt(1).isOperator('(') &&
          _peekAt(2).isOperator(')')) {
        return _functionDefinition();
      }
    }
    return _simpleCommand();
  }

  /// `( список )`. Пустые скобки — синтаксическая ошибка на `)`.
  SubshellCommand _subshell() {
    final line = _advance().line;
    final body = _body({')'});
    _requireNonEmpty(body);
    _expectOperator(')');
    return SubshellCommand(body, line, _redirects());
  }

  /// `{ список; }`. Закрывающий `}` — слово только в начале команды, поэтому `{ echo }` без `;` — ошибка,
  /// как в bash.
  GroupCommand _group() {
    final line = _advance().line;
    final body = _body({'}'});
    _requireNonEmpty(body);
    _expectWord('}');
    return GroupCommand(body, line, _redirects());
  }

  IfCommand _if() {
    final line = _advance().line;
    final branches = [_branch()];
    while (_isWord('elif')) {
      _advance();
      branches.add(_branch());
    }
    ScriptNode? elseBody;
    if (_isWord('else')) {
      _advance();
      elseBody = _body({'fi'});
      _requireNonEmpty(elseBody);
    }
    _expectWord('fi');
    return IfCommand(branches, elseBody, line, _redirects());
  }

  /// Условие до `then` и тело до `elif`, `else` или `fi`. Тело не может быть пустым.
  ConditionalBranch _branch() {
    final condition = _body({'then'});
    _requireNonEmpty(condition);
    _expectWord('then');
    final body = _body({'elif', 'else', 'fi'});
    _requireNonEmpty(body);
    return ConditionalBranch(condition, body);
  }

  LoopCommand _loop({required bool until}) {
    final line = _advance().line;
    final condition = _body({'do'});
    _requireNonEmpty(condition);
    _expectWord('do');
    final body = _body({'done'});
    _requireNonEmpty(body);
    _expectWord('done');
    return LoopCommand(
      condition,
      body,
      until: until,
      line: line,
      redirects: _redirects(),
    );
  }

  /// `((выражение))` как команда. Перенаправления после неё — как у составной команды.
  ArithmeticCommand _arithmeticCommand() {
    final token = _advance();
    final wordParser = ShellWordParser(depth: _depth, limits: _limits);
    return ArithmeticCommand(
      wordParser.parseArithmetic(token.text),
      token.line,
      _redirects(),
    );
  }

  /// `for ((init; cond; step)); do ... done`. Части делятся по `;` вне кавычек и подстановок. Пустая часть
  /// даёт null; ровно три части обязательны, как у bash.
  ArithmeticFor _arithmeticFor(int line) {
    final token = _advance();
    final parts = _splitArithmetic(token.text);
    if (parts.length < 3) {
      throw ShellSyntaxException(
        'syntax error: arithmetic expression required',
        line: token.line,
      );
    }
    if (parts.length > 3) {
      throw ShellSyntaxException(
        "syntax error: `;' unexpected",
        line: token.line,
      );
    }
    final wordParser = ShellWordParser(depth: _depth, limits: _limits);
    ShellWord? part(String text) =>
        text.trim().isEmpty ? null : wordParser.parseArithmetic(text);
    if (_peek.isOperator(';') || _peek.kind == TokenKind.newline) _advance();
    _skipNewlines();
    _expectWord('do');
    final body = _body({'done'});
    _requireNonEmpty(body);
    _expectWord('done');
    return ArithmeticFor(
      part(parts.first),
      part(parts[1]),
      part(parts[2]),
      body,
      line,
      _redirects(),
    );
  }

  /// Делит текст `for ((...))` по `;` вне кавычек и подстановок. Скобки внутри выражения не делят.
  static List<String> _splitArithmetic(String text) {
    final parts = <String>[];
    var from = 0;
    while (true) {
      final semicolon = ShellScan.indexOfTop(text, ';', from);
      if (semicolon < 0) {
        parts.add(ShellText.cut(text, from));
        return parts;
      }
      parts.add(ShellText.cut(text, from, semicolon));
      from = semicolon + 1;
    }
  }

  CompoundCommand _for() {
    final line = _advance().line;
    if (_peek.kind == TokenKind.arith) return _arithmeticFor(line);
    final nameToken = _peek;
    if (nameToken.kind != TokenKind.word) throw _unexpected(nameToken);
    if (!_identifier.hasMatch(nameToken.text)) {
      throw ShellSyntaxException(
        '`${nameToken.text}\': not a valid identifier',
        line: nameToken.line,
      );
    }
    _advance();
    List<ShellWord>? words;
    if (_isWord('in')) {
      _advance();
      final wordParser = ShellWordParser(depth: _depth, limits: _limits);
      words = [];
      while (_peek.kind == TokenKind.word) {
        words.add(wordParser.parse(_advance().text));
      }
    }
    if (_peek.isOperator(';') || _peek.kind == TokenKind.newline) _advance();
    _skipNewlines();
    _expectWord('do');
    final body = _body({'done'});
    _requireNonEmpty(body);
    _expectWord('done');
    return ForCommand(nameToken.text, words, body, line, _redirects());
  }

  /// `select NAME [in WORDS]; do ...; done`. Разбор совпадает с `for`, меню рисует интерпретатор.
  SelectCommand _select() {
    final line = _advance().line;
    final nameToken = _peek;
    if (nameToken.kind != TokenKind.word) throw _unexpected(nameToken);
    if (!_identifier.hasMatch(nameToken.text)) {
      throw ShellSyntaxException(
        '`${nameToken.text}\': not a valid identifier',
        line: nameToken.line,
      );
    }
    _advance();
    List<ShellWord>? words;
    if (_isWord('in')) {
      _advance();
      final wordParser = ShellWordParser(depth: _depth, limits: _limits);
      words = [];
      while (_peek.kind == TokenKind.word) {
        words.add(wordParser.parse(_advance().text));
      }
    }
    if (_peek.isOperator(';') || _peek.kind == TokenKind.newline) _advance();
    _skipNewlines();
    _expectWord('do');
    final body = _body({'done'});
    _requireNonEmpty(body);
    _expectWord('done');
    return SelectCommand(nameToken.text, words, body, line, _redirects());
  }

  CaseCommand _case() {
    final line = _advance().line;
    final subjectToken = _peek;
    if (subjectToken.kind != TokenKind.word) throw _unexpected(subjectToken);
    _advance();
    final wordParser = ShellWordParser(depth: _depth, limits: _limits);
    final subject = wordParser.parse(subjectToken.text);
    _skipNewlines();
    _expectWord('in');
    _skipNewlines();
    final clauses = <CaseClause>[];
    while (!_isWord('esac')) {
      if (_peek.isOperator('(')) _advance();
      final patterns = <ShellWord>[];
      while (true) {
        final token = _peek;
        if (token.kind != TokenKind.word) throw _unexpected(token);
        patterns.add(wordParser.parse(_advance().text));
        if (!_peek.isOperator('|')) break;
        _advance();
      }
      _expectOperator(')');
      final body = _body(const {'esac', ';;', ';&', ';;&'});
      final CaseTerminator terminator;
      if (_peek.isOperator(';;')) {
        _advance();
        terminator = CaseTerminator.stop;
      } else if (_peek.isOperator(';&')) {
        _advance();
        terminator = CaseTerminator.fallthrough;
      } else if (_peek.isOperator(';;&')) {
        _advance();
        terminator = CaseTerminator.testNext;
      } else if (_isWord('esac')) {
        // Последняя ветка может обойтись без `;;`.
        terminator = CaseTerminator.stop;
      } else {
        throw _unexpected(_peek);
      }
      clauses.add(CaseClause(patterns, body, terminator));
      _skipNewlines();
    }
    _expectWord('esac');
    return CaseCommand(subject, clauses, line, _redirects());
  }

  /// `function name [()] составная-команда`.
  FunctionDefinition _functionKeyword() {
    final keyword = _advance();
    final nameToken = _peek;
    if (nameToken.kind != TokenKind.word) throw _unexpected(nameToken);
    if (!_functionName.hasMatch(nameToken.text)) {
      throw ShellSyntaxException.unsupported(
        'function name ${nameToken.text}',
        line: nameToken.line,
      );
    }
    _advance();
    if (_peek.isOperator('(')) {
      _advance();
      _expectOperator(')');
    }
    _skipNewlines();
    return FunctionDefinition(nameToken.text, _functionBody(), keyword.line);
  }

  /// `name() составная-команда`. Две скобки проверены в [_command].
  FunctionDefinition _functionDefinition() {
    final nameToken = _advance();
    if (!_functionName.hasMatch(nameToken.text)) {
      throw ShellSyntaxException.unsupported(
        'function name ${nameToken.text}',
        line: nameToken.line,
      );
    }
    _advance();
    _advance();
    _skipNewlines();
    return FunctionDefinition(nameToken.text, _functionBody(), nameToken.line);
  }

  /// Тело функции — составная команда. Простая команда на её месте — синтаксическая ошибка, как в bash.
  CompoundCommand _functionBody() {
    final start = _peek;
    final body = _command();
    if (body is! CompoundCommand) throw _unexpected(start);
    return body;
  }

  static const _condUnary = {
    '-a',
    '-b',
    '-c',
    '-d',
    '-e',
    '-f',
    '-g',
    '-h',
    '-k',
    '-p',
    '-r',
    '-s',
    '-t',
    '-u',
    '-w',
    '-x',
    '-G',
    '-L',
    '-N',
    '-O',
    '-S',
    '-n',
    '-z',
    '-o',
    '-v',
  };

  static const _condBinary = {
    '==',
    '=',
    '!=',
    '=~',
    '-eq',
    '-ne',
    '-lt',
    '-le',
    '-gt',
    '-ge',
    '-nt',
    '-ot',
    '-ef',
  };

  /// `[[ выражение ]]`. Слова не режутся и не глобятся: это делает вычислитель, а не разбор.
  CondCommand _conditional() {
    final line = _advance().line;
    final words = ShellWordParser(depth: _depth, limits: _limits);
    _skipNewlines();
    final expr = _condOr(words);
    _skipNewlines();
    _expectWord(']]');
    return CondCommand(expr, line, _redirects());
  }

  CondNode _condOr(ShellWordParser words) {
    var left = _condAnd(words);
    while (_peek.isOperator('||')) {
      _advance();
      _skipNewlines();
      left = CondOr(left, _condAnd(words));
    }
    return left;
  }

  CondNode _condAnd(ShellWordParser words) {
    var left = _condNot(words);
    while (_peek.isOperator('&&')) {
      _advance();
      _skipNewlines();
      left = CondAnd(left, _condNot(words));
    }
    return left;
  }

  CondNode _condNot(ShellWordParser words) {
    _skipNewlines();
    if (_peek.kind == TokenKind.word &&
        _peek.text == '!' &&
        !_condBoundary(_peekAt(1))) {
      _advance();
      _skipNewlines();
      return CondNot(_condNot(words));
    }
    return _condPrimary(words);
  }

  CondNode _condPrimary(ShellWordParser words) {
    _skipNewlines();
    final token = _peek;
    if (token.isOperator('(')) {
      _advance();
      _skipNewlines();
      final inner = _condOr(words);
      _skipNewlines();
      _expectOperator(')');
      return CondGroup(inner);
    }
    if (token.kind == TokenKind.word && _condUnary.contains(token.text)) {
      final op = token.text;
      _advance();
      _skipNewlines();
      if (_condBoundary(_peek) || _isCondBinary(_peek)) {
        throw ShellSyntaxException(
          "unexpected argument `${_shown(_peek)}' to conditional unary operator",
          line: token.line,
        );
      }
      return CondPrimary(op, null, _condWord(words));
    }
    final left = _condWord(words);
    _skipNewlines();
    if (_isCondBinary(_peek)) {
      final op = _peek.text;
      _advance();
      if (op == '=~') return CondPrimary(op, left, _condRegex(words));
      _skipNewlines();
      if (_condBoundary(_peek)) throw _unexpected(_peek);
      return CondPrimary(op, left, _condWord(words));
    }
    return CondPrimary(null, left, null);
  }

  /// Правая часть `=~`: лексемы до `&&`, `||`, `]]` или `)`, которая закрывает группировку `[[ ( ... ) ]]`.
  /// Скобки самого выражения (`(b)(c)`) остаются в образце. Пробелы между лексемами сохраняются.
  ShellWord _condRegex(ShellWordParser words) {
    _skipNewlines();
    if (_condRegexStops(_peek, 0)) throw _unexpected(_peek);
    final start = _peek.offset;
    var last = _peek;
    var depth = 0;
    while (!_condRegexStops(_peek, depth)) {
      if (_peek.isOperator('(')) {
        depth++;
      } else if (_peek.isOperator(')')) {
        depth--;
      }
      last = _advance();
    }
    final end = last.offset + last.text.length;
    return words.parse(ShellText.cut(_source, start, end));
  }

  /// Конец образца `=~`. `)` останавливает его только тогда, когда это скобка группировки, а не выражения.
  bool _condRegexStops(Token token, int depth) =>
      token.kind == TokenKind.eof ||
      token.kind == TokenKind.newline ||
      token.isOperator('&&') ||
      token.isOperator('||') ||
      (token.kind == TokenKind.word && token.text == ']]') ||
      (token.isOperator(')') && depth == 0);

  /// Операнд `[[ ]]`: одно слово. Операторы условия операндом не бывают.
  ShellWord _condWord(ShellWordParser words) {
    final token = _peek;
    if (token.kind != TokenKind.word) throw _unexpected(token);
    if (token.text == ']]' || token.text == '!') throw _unexpected(token);
    _advance();
    return words.parse(token.text);
  }

  bool _isCondBinary(Token token) =>
      token.isOperator('<') ||
      token.isOperator('>') ||
      (token.kind == TokenKind.word && _condBinary.contains(token.text));

  /// Токен, на котором первичный операнд заканчивается: связка, скобка, `]]` или конец.
  bool _condBoundary(Token token) =>
      token.kind == TokenKind.eof ||
      token.kind == TokenKind.newline ||
      token.isOperator('&&') ||
      token.isOperator('||') ||
      token.isOperator(')') ||
      (token.kind == TokenKind.word && token.text == ']]');

  String _shown(Token token) => switch (token.kind) {
    TokenKind.newline => 'newline',
    TokenKind.eof => 'EOF',
    TokenKind.arith => '(',
    _ => token.text,
  };

  /// Простая команда. Ошибки разбора слов (`${x@A}`) создаются без номера строки, поэтому номер строки
  /// команды подставляется здесь, если его ещё нет.
  SimpleCommand _simpleCommand() {
    final line = _peek.line;
    try {
      return _simpleCommandBody(line);
    } on ShellSyntaxException catch (e, stack) {
      if (e.line != 1) rethrow;
      Error.throwWithStackTrace(e.withLine(line), stack);
    }
  }

  /// Присваивание в начале простой команды: `NAME=v`, `NAME+=v`, `NAME[i]=v`, `NAME[i]+=v`, `NAME=(...)`,
  /// `NAME+=(...)`. Слово поглощается. null — слово не присваивание и остаётся аргументом.
  Assignment? _assignmentAt(ShellWordParser wordParser) {
    final text = _peek.text;
    final plain = _assignment.firstMatch(text);
    if (plain != null) {
      _advance();
      final append = plain.group(2) == '+';
      final value = plain.group(3)!;
      if (value.isEmpty && _peek.isOperator('(')) {
        return Assignment(
          plain.group(1)!,
          const ShellWord([]),
          elements: _arrayLiteral(wordParser),
          append: append,
        );
      }
      return Assignment(
        plain.group(1)!,
        wordParser.parseAssignmentValue(value),
        append: append,
      );
    }
    final head = _subscripted.firstMatch(text);
    if (head == null) return null;
    final close = ShellScan.indexOfTop(text, ']', head.end);
    if (close < 0) return null;
    final append = text.startsWith('+=', close + 1);
    if (!append && !text.startsWith('=', close + 1)) return null;
    _advance();
    final value = ShellText.cut(text, close + (append ? 3 : 2));
    if (value.isEmpty && _peek.isOperator('(')) {
      throw ShellSyntaxException.unsupported(
        'array literal assigned to an element',
        line: _peek.line,
      );
    }
    return Assignment(
      head.group(1)!,
      wordParser.parseAssignmentValue(value),
      index: wordParser.parse(ShellText.cut(text, head.end, close)),
      append: append,
    );
  }

  /// Литерал `(элементы)` после `NAME=`. Переводы строк внутри скобок допустимы. Элемент — слово, при
  /// этом `[ключ]=значение` задаёт индекс или ключ ассоциативного массива.
  List<ArrayElement> _arrayLiteral(ShellWordParser wordParser) {
    _advance();
    final elements = <ArrayElement>[];
    while (true) {
      _skipNewlines();
      final token = _peek;
      if (token.isOperator(')')) {
        _advance();
        return elements;
      }
      if (token.kind != TokenKind.word) throw _unexpected(token);
      _advance();
      elements.add(_arrayElement(token.text, wordParser));
    }
  }

  /// Один элемент литерала: `[ключ]=значение` или обычное слово.
  ArrayElement _arrayElement(String text, ShellWordParser wordParser) {
    if (text.startsWith('[')) {
      final close = ShellScan.indexOfTop(text, ']', 1);
      if (close > 0 && text.startsWith('=', close + 1)) {
        return ArrayElement(
          wordParser.parse(ShellText.cut(text, close + 2)),
          key: wordParser.parse(ShellText.cut(text, 1, close)),
        );
      }
    }
    return ArrayElement(wordParser.parse(text));
  }

  SimpleCommand _simpleCommandBody(int line) {
    final words = <ShellWord>[];
    final rawWords = <String>[];
    final assignments = <Assignment>[];
    final redirects = <Redirect>[];
    final wordParser = ShellWordParser(depth: _depth, limits: _limits);
    while (true) {
      final token = _peek;
      if (token.kind == TokenKind.word) {
        if (words.isEmpty) {
          final assignment = _assignmentAt(wordParser);
          if (assignment != null) {
            assignments.add(assignment);
            continue;
          }
        }
        // `NAME=(` в позиции аргумента — литерал массива вне присваивания. Синтаксической ошибкой это не
        // считаем: конструкция корректна (`declare -a x=(1 2)`), но не поддерживается.
        if (_peekAt(1).isOperator('(') &&
            _arrayAssignmentHead.hasMatch(token.text)) {
          throw ShellSyntaxException.unsupported(
            'array assignment as a command argument',
            line: token.line,
          );
        }
        if (words.isEmpty && _rejectedCommands.contains(token.text)) {
          throw ShellSyntaxException.unsupported(token.text, line: token.line);
        }
        if (!token.text.contains("'") &&
            !token.text.contains('"') &&
            _extglob.hasMatch(token.text)) {
          throw ShellSyntaxException.unsupported(
            'extglob or globstar',
            line: token.line,
          );
        }
        _advance();
        rawWords.add(token.text);
        words.add(wordParser.parse(token.text));
      } else if (token.kind == TokenKind.ioNumber || _isRedirect(token)) {
        final redirect = _redirect(wordParser);
        _checkRedirect(redirect, token.line);
        redirects.add(redirect);
      } else if (token.kind == TokenKind.operator &&
          _unsupportedOperators.contains(token.text)) {
        throw ShellSyntaxException.unsupported(
          'operator ${token.text}',
          line: token.line,
        );
      } else {
        break;
      }
    }
    if (words.isEmpty && assignments.isEmpty && redirects.isEmpty) {
      throw _unexpected(_peek);
    }
    // Временное присваивание элемента или литерала перед командой (`x=(a) cmd`) не моделируется: окружение
    // хранит строки. Поэтому оно отвергается явно. Без команды (`x=(a)`) присваивание работает.
    if (words.isNotEmpty) {
      final compound = assignments.where(
        (a) => a.elements != null || a.index != null,
      );
      if (compound.isNotEmpty) {
        throw ShellSyntaxException.unsupported(
          'array assignment before a command',
          line: line,
        );
      }
    }
    if (rawWords.isNotEmpty && rawWords.first == 'set') {
      for (var i = 0; i < rawWords.length - 1; i++) {
        if (rawWords[i] == '-o' && rawWords[i + 1] == 'posix') {
          throw ShellSyntaxException.unsupported('set -o posix', line: line);
        }
      }
    }
    return SimpleCommand(
      assignments: assignments,
      words: words,
      redirects: redirects,
      line: line,
    );
  }

  /// Перенаправления после составной команды: `done > out`, `fi 2>&1`.
  List<Redirect> _redirects() {
    final wordParser = ShellWordParser(depth: _depth, limits: _limits);
    final redirects = <Redirect>[];
    while (_peek.kind == TokenKind.ioNumber || _isRedirect(_peek)) {
      final line = _peek.line;
      final redirect = _redirect(wordParser);
      _checkRedirect(redirect, line);
      redirects.add(redirect);
    }
    return redirects;
  }

  /// Поддерживаются дескрипторы 0, 1 и 2 с направлением по смыслу: вход — на 0, выход — на 1 или 2,
  /// дублирование — только в `1` или `2`. Остальные номера (`3>f`, `<&`-подобные) — явная ошибка.
  void _checkRedirect(Redirect redirect, int line) {
    final valid = switch (redirect) {
      HeredocRedirect(:final fd) => fd == 0,
      FileRedirect(:final fd, :final kind, :final target) => switch (kind) {
        RedirectKind.input || RedirectKind.hereString => fd == 0,
        RedirectKind.output || RedirectKind.append => fd == 1 || fd == 2,
        RedirectKind.dupOutput =>
          (fd == 1 || fd == 2) &&
              switch (target.parts) {
                [LiteralPart(text: '1' || '2')] => true,
                _ => false,
              },
      },
    };
    if (!valid) {
      throw ShellSyntaxException.unsupported(
        'redirection on file descriptor ${redirect.fd}',
        line: line,
      );
    }
  }

  static bool _isRedirect(Token token) =>
      token.kind == TokenKind.operator &&
      _redirectOperators.contains(token.text);

  Redirect _redirect(ShellWordParser wordParser) {
    int? fd;
    if (_peek.kind == TokenKind.ioNumber) {
      fd = int.parse(_advance().text);
    }
    final op = _advance();
    final text = op.text;
    if (text == '<<' || text == '<<-') {
      final spec = op.heredoc!;
      final body = spec.quoted
          ? ShellWord([LiteralPart(spec.body, quoted: true)])
          : wordParser.parseHeredoc(spec.body);
      return HeredocRedirect(
        fd ?? 0,
        body: body,
        delimiter: spec.delimiter,
        terminated: spec.terminated,
        line: spec.line,
        eofLine: spec.eofLine,
      );
    }
    final target = _peek;
    if (target.kind != TokenKind.word) throw _unexpected(target);
    _advance();
    if (text == '>&') {
      if (!RegExp(r'^[0-9]+$').hasMatch(target.text)) {
        throw ShellSyntaxException.unsupported(
          'redirection to a file with >&',
          line: op.line,
        );
      }
      return FileRedirect(
        fd ?? 1,
        RedirectKind.dupOutput,
        ShellWord([LiteralPart(target.text, quoted: true)]),
      );
    }
    if (text == '<<<') {
      return FileRedirect(
        fd ?? 0,
        RedirectKind.hereString,
        wordParser.parse(target.text),
      );
    }
    if (text == '<') {
      return FileRedirect(
        fd ?? 0,
        RedirectKind.input,
        wordParser.parse(target.text),
      );
    }
    final kind = text == '>>' ? RedirectKind.append : RedirectKind.output;
    return FileRedirect(fd ?? 1, kind, wordParser.parse(target.text));
  }

  ShellSyntaxException _unexpected(Token token) {
    if (token.kind == TokenKind.eof) {
      return ShellSyntaxException(
        'syntax error: unexpected end of file',
        line: token.line,
      );
    }
    // Токен `((...))` в неуместном месте bash показывает как одну открывающую скобку: `echo ((1))` →
    // `near unexpected token '('`.
    final shown = switch (token.kind) {
      TokenKind.newline => 'newline',
      TokenKind.arith => '(',
      _ => token.text,
    };
    return ShellSyntaxException(
      "syntax error near unexpected token `$shown'",
      line: token.line,
    );
  }
}

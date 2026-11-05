import 'package:probably_works/host/virtual/shell/shell_ast.dart';
import 'package:probably_works/host/virtual/shell/shell_errors.dart';
import 'package:probably_works/host/virtual/shell/shell_lexer.dart';
import 'package:probably_works/host/virtual/shell/shell_token.dart';
import 'package:probably_works/host/virtual/shell/shell_word_parser.dart';
import 'package:probably_works/host/virtual/virtual_limits.dart';

/// Рекурсивный разбор токенов в [ScriptNode]. Поддерживаемое подмножество задано здесь:
/// всё вне него отвергается с [ShellSyntaxException.unsupported], а не разбирается «как-нибудь».
///
/// Разбор всего скрипта выполняется до исполнения: как и bash, синтаксическая ошибка в любой строке
/// означает, что ни одна команда не запустилась.
final class ShellParser {
  ShellParser._(this._tokens, this._depth, this._limits);

  final List<Token> _tokens;
  final int _depth;
  final VirtualLimits _limits;
  int _at = 0;

  /// Текущая глубина вложенных списков составных команд. Ограничивает рекурсию разбора.
  int _nesting = 0;

  /// Ключевые слова bash, которые виртуальный shell не поддерживает. В начале команды они дают явный отказ,
  /// а не запуск команды с таким именем.
  static const _unsupportedKeywords = {'select', 'time', 'coproc', '[[', ']]'};

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
  };

  /// Операторы, которые лексер выдаёт, но которых в подмножестве нет: фон, `&>`, `<&`, `>|`, `<>`.
  static const _unsupportedOperators = {'&', '&>', '<&', '>|', '<>'};

  static const _redirectOperators = {'<', '>', '>>', '<<', '<<-', '<<<', '>&'};

  static final _assignment = RegExp(
    r'^([A-Za-z_][A-Za-z0-9_]*)=(.*)$',
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
    return ShellParser._(tokens, depth, limits)._script();
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
    if (token.isOperator('(')) {
      if (_peekAt(1).isOperator('(')) {
        // `((...))` — арифметическая команда. От подоболочки `( (...) )` её не отличить без пробелов, поэтому
        // обе формы отвергаются явно, а не выполняются как подоболочка.
        throw ShellSyntaxException.unsupported(
          'arithmetic command ((...))',
          line: token.line,
        );
      }
      return _subshell();
    }
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
        case 'case':
          return _case();
        case '{':
          return _group();
        case 'function':
          return _functionKeyword();
      }
      if (_peekAt(1).isOperator('(') && _peekAt(2).isOperator(')')) {
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

  ForCommand _for() {
    final line = _advance().line;
    if (_peek.isOperator('(')) {
      throw ShellSyntaxException.unsupported('arithmetic for loop', line: line);
    }
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

  SimpleCommand _simpleCommand() {
    final line = _peek.line;
    final words = <ShellWord>[];
    final assignments = <Assignment>[];
    final redirects = <Redirect>[];
    final wordParser = ShellWordParser(depth: _depth, limits: _limits);
    while (true) {
      final token = _peek;
      if (token.kind == TokenKind.word) {
        final match = words.isEmpty ? _assignment.firstMatch(token.text) : null;
        _advance();
        if (match != null) {
          assignments.add(
            Assignment(
              match.group(1)!,
              wordParser.parseAssignmentValue(match.group(2)!),
            ),
          );
        } else {
          words.add(wordParser.parse(token.text));
        }
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
    final shown = token.kind == TokenKind.newline ? 'newline' : token.text;
    return ShellSyntaxException(
      "syntax error near unexpected token `$shown'",
      line: token.line,
    );
  }
}

import 'package:probably_works/host/virtual/shell/shell_errors.dart';
import 'package:probably_works/host/virtual/shell/shell_scan.dart';
import 'package:probably_works/host/virtual/shell/shell_token.dart';

/// Лексер: режет скрипт на слова, операторы и переводы строк.
///
/// Слово выделяется по правилам bash: пробел, `;`, `&`, `|`, `<`, `>`, `(`, `)` завершают его, если они
/// не внутри кавычек, `$(...)`, `${...}` или после `\`. Комментарий начинается с `#` в начале токена.
/// Здесь-документы: тело читается на следующей строке после строки оператора, лексер делает это на переводе
/// строки. Операторы, которых нет в поддерживаемом подмножестве, лексер выдаёт; отвергает их парсер.
final class ShellLexer {
  ShellLexer(String source) : _src = source, _units = source.codeUnits;

  final String _src;
  final List<int> _units;
  final List<HeredocSpec> _pending = [];
  final List<Token> _tokens = [];
  int _pos = 0;
  int _line = 1;

  /// Операторы от длинных к коротким: первым совпадает самый длинный.
  static const _operators = [
    '<<<',
    '<<-',
    ';;&',
    '&&',
    '||',
    ';;',
    ';&',
    '>>',
    '<<',
    '>&',
    '<&',
    '>|',
    '<>',
    '&>',
    '|',
    '&',
    ';',
    '(',
    ')',
    '<',
    '>',
  ];

  /// Токены скрипта. Последний — [TokenKind.eof].
  List<Token> tokenize() {
    try {
      while (_pos < _units.length) {
        _skipBlanks();
        if (_pos >= _units.length) break;
        final c = _char(_pos);
        if (c == r'\' && _char(_pos + 1) == '\n') {
          _pos += 2;
          _line++;
        } else if (c == '#') {
          _skipComment();
        } else if (c == '\n') {
          _tokens.add(Token(TokenKind.newline, '\n', _line));
          _pos++;
          _line++;
          _readHeredocBodies();
        } else if (_operatorAt(_pos) case final op?) {
          _readOperator(op);
        } else {
          _readWord();
        }
      }
      _readHeredocBodies();
    } on ShellSyntaxException catch (e, stack) {
      // Ошибка без номера строки получает номер текущей строки лексера; сохраняем исходный стек.
      Error.throwWithStackTrace(e.line == 1 ? e.withLine(_line) : e, stack);
    }
    _tokens.add(Token(TokenKind.eof, '', _line));
    return _tokens;
  }

  /// Код UTF-16 в позиции или -1 за концом. Сравнения ниже делаются по символам строки.
  String _char(int index) =>
      index < _units.length ? String.fromCharCode(_units[index]) : '';

  String _slice(int start, int end) => String.fromCharCodes(_units, start, end);

  void _skipBlanks() {
    while (_pos < _units.length &&
        (_char(_pos) == ' ' || _char(_pos) == '\t')) {
      _pos++;
    }
  }

  void _skipComment() {
    while (_pos < _units.length && _char(_pos) != '\n') {
      _pos++;
    }
  }

  static bool _isBreak(String c) => switch (c) {
    ' ' ||
    '\t' ||
    '\n' ||
    ';' ||
    '&' ||
    '|' ||
    '<' ||
    '>' ||
    '(' ||
    ')' => true,
    _ => false,
  };

  String? _operatorAt(int index) {
    for (final op in _operators) {
      var matches = true;
      for (var k = 0; k < op.length; k++) {
        if (_char(index + k) != op[k]) {
          matches = false;
          break;
        }
      }
      if (matches) return op;
    }
    return null;
  }

  void _readOperator(String op) {
    _pos += op.length;
    if (op == '<<' || op == '<<-') {
      _tokens.add(
        Token(
          TokenKind.operator,
          op,
          _line,
          heredoc: _readHeredocSpec(op == '<<-'),
        ),
      );
    } else {
      _tokens.add(Token(TokenKind.operator, op, _line));
    }
  }

  /// Читает разделитель здесь-документа. Кавычки в нём означают, что тело не расширяется.
  HeredocSpec _readHeredocSpec(bool stripTabs) {
    _skipBlanks();
    final start = _pos;
    final raw = _scanWord();
    if (raw.isEmpty) {
      throw ShellSyntaxException(
        'syntax error near unexpected token `${_pos < _units.length ? _char(_pos) : 'newline'}\'',
        line: _line,
      );
    }
    final quoted = _slice(start, _pos).contains(RegExp(r'''["'\\]'''));
    final delimiter = raw.replaceAll(RegExp(r'''["'\\]'''), '');
    final spec = HeredocSpec(
      delimiter: delimiter,
      quoted: quoted,
      stripTabs: stripTabs,
      line: _line,
    );
    _pending.add(spec);
    return spec;
  }

  /// Читает тела всех ожидающих здесь-документов. Строка-разделитель совпадает целиком,
  /// для `<<-` ведущие табуляции в ней не учитываются.
  void _readHeredocBodies() {
    for (final spec in _pending) {
      final body = StringBuffer();
      var bodyLines = 0;
      while (_pos < _units.length) {
        var end = _pos;
        while (end < _units.length && _units[end] != 0x0a) {
          end++;
        }
        final rawLine = _slice(_pos, end);
        _pos = end < _units.length ? end + 1 : end;
        _line++;
        final line = spec.stripTabs
            ? rawLine.replaceFirst(RegExp(r'^\t+'), '')
            : rawLine;
        if (line == spec.delimiter) {
          spec.terminated = true;
          break;
        }
        bodyLines++;
        body
          ..write(line)
          ..write('\n');
      }
      // bash называет строку последнего содержимого, а без содержимого — строку оператора `<<`.
      spec
        ..body = body.toString()
        ..eofLine = bodyLines == 0 ? spec.line : _line - 1;
    }
    _pending.clear();
  }

  void _readWord() {
    final startLine = _line;
    final raw = _scanWord();
    final isNumber = RegExp(r'^[0-9]+$').hasMatch(raw);
    final redirectFollows = _char(_pos) == '<' || _char(_pos) == '>';
    if (isNumber && redirectFollows) {
      _tokens.add(Token(TokenKind.ioNumber, raw, startLine));
    } else {
      _tokens.add(Token(TokenKind.word, raw, startLine));
    }
  }

  /// Сырой текст слова от текущей позиции до разделителя. Кавычки, подстановки и `\` проходятся целиком,
  /// поэтому пробел внутри них не завершает слово. Переводы строк внутри кавычек учитываются в номере строки.
  String _scanWord() {
    final start = _pos;
    while (_pos < _units.length) {
      final c = _char(_pos);
      if (_isBreak(c)) break;
      if (c == r'\') {
        _pos = _pos + 2 > _units.length ? _units.length : _pos + 2;
      } else if (c == "'") {
        _pos = ShellScan.singleQuoteEnd(_src, _pos);
      } else if (c == '"') {
        _pos = ShellScan.doubleQuoteEnd(_src, _pos);
      } else if (c == r'$' && _char(_pos + 1) == '(') {
        _pos = ShellScan.parenEnd(_src, _pos + 1);
      } else if (c == r'$' && _char(_pos + 1) == '{') {
        _pos = ShellScan.braceEnd(_src, _pos + 1);
      } else if (c == '`') {
        _pos = ShellScan.backquoteEnd(_src, _pos);
      } else {
        _pos++;
      }
    }
    final raw = _slice(start, _pos);
    for (var k = 0; k < raw.length; k++) {
      if (raw[k] == '\n') _line++;
    }
    return raw;
  }
}

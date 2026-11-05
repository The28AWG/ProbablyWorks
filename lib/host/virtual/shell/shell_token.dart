/// Вид токена. Слова хранятся сырым текстом: их части разбирает [ShellWordParser] уже после лексера.
enum TokenKind { word, ioNumber, operator, newline, eof }

/// Здесь-документ, которому лексер читает тело со следующей строки после текущей.
///
/// Объект изменяемый: лексер создаёт его у оператора `<<`, а заполняет на переводе строки. Поэтому
/// к моменту разбора команды тело уже известно.
final class HeredocSpec {
  HeredocSpec({
    required this.delimiter,
    required this.quoted,
    required this.stripTabs,
    required this.line,
  });

  /// Строка-разделитель без кавычек.
  final String delimiter;

  /// Есть ли кавычки в исходном разделителе. Тогда тело не расширяется (`<<'EOF'`).
  final bool quoted;

  /// `<<-`: ведущие табуляции убираются из тела и из строки-разделителя.
  final bool stripTabs;

  /// Строка оператора, нужна для предупреждения о незакрытом документе.
  final int line;

  /// Тело с переводами строк, либо пусто, если разделитель не найден.
  String body = '';

  /// Найдена ли строка-разделитель. Нет — bash берёт тело до конца скрипта и предупреждает.
  bool terminated = false;

  /// Строка, на которой лексер дошёл до конца скрипта, если разделитель не найден. bash пишет её
  /// в предупреждении, а не строку оператора.
  int eofLine = 0;
}

/// Токен лексера. Для [TokenKind.word] текст — исходная запись слова, для оператора — сам оператор.
final class Token {
  const Token(this.kind, this.text, this.line, {this.heredoc});

  final TokenKind kind;
  final String text;
  final int line;

  /// Задан только у операторов `<<` и `<<-`.
  final HeredocSpec? heredoc;

  bool isOperator(String op) => kind == TokenKind.operator && text == op;
}

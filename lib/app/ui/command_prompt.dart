/// Строка команды в терминале: промпт `$` и подсвеченная команда.
///
/// Команда в PTY не эхоится (shell получает её аргументом), поэтому строку рисует приложение.
/// Результат — ANSI-последовательности с truecolor для xterm. Цвета фиксированы, как и
/// подсветка кода в блоках: поверхность кода всегда тёмная.
String commandPromptLine(String command) {
  final text = command
      .replaceAll('\t', '  ')
      .replaceAll(_controlChar, '')
      .trim();
  if (text.isEmpty) return '';
  final prompt = _paint('\$', _promptColor, bold: true);
  final body = _highlight(text).replaceAll('\n', '\r\n');
  return '$prompt $body\r\n';
}

const _promptColor = 0x9CA3AF;
const _programColor = 0x7DD3FC;
const _flagColor = 0x93C5FD;
const _stringColor = 0x86EFAC;
const _variableColor = 0xFBBF24;
const _operatorColor = 0xC4A7FF;
const _commentColor = 0x6B7280;

final _controlChar = RegExp(r'[\x00-\x09\x0B-\x1F\x7F]');

/// Лексемы shell. Порядок важен: строки, комментарии и переменные раньше слов, операторы раньше слов.
/// Последняя альтернатива `[\s\S]` ловит любой символ, поэтому лексемы покрывают весь текст без пропусков.
final _token = RegExp(
  r'''"(?:\\[\s\S]|[^"\\])*"?|'[^']*'?|#[^\n]*|\$\{[^}]*\}?|\$\w+|\d*>>?&?\d*|\d*<|&&|\|\||[|;&()]|\s+|\\|[^\s'"|;&<>()]+|[\s\S]''',
);

final _assignment = RegExp(r'^[A-Za-z_]\w*=');

const _separators = {'|', '||', '&&', ';', '&', '(', ')'};

String _highlight(String command) {
  final out = StringBuffer();
  // В начале команды и после разделителей (`|`, `&&`, `;`, перевод строки) стоит имя программы.
  var atProgram = true;
  for (final match in _token.allMatches(command)) {
    final token = match.group(0)!;
    final first = token[0];
    if (first == '"' || first == "'") {
      out.write(_paint(token, _stringColor));
      atProgram = false;
    } else if (first == '#') {
      out.write(_paint(token, _commentColor, italic: true));
    } else if (first == r'$') {
      out.write(_paint(token, _variableColor));
      atProgram = false;
    } else if (token.contains('<') || token.contains('>')) {
      out.write(_paint(token, _operatorColor));
      atProgram = false;
    } else if (_separators.contains(token)) {
      out.write(_paint(token, _operatorColor));
      atProgram = true;
    } else if (token.trim().isEmpty) {
      if (token.contains('\n')) atProgram = true;
      out.write(token);
    } else if (token == r'\') {
      // Перенос строки обратным слэшем: команда продолжается, позиция не меняется.
      out.write(token);
    } else if (atProgram && !_assignment.hasMatch(token)) {
      out.write(_paint(token, _programColor, bold: true));
      atProgram = false;
    } else if (token.startsWith('-')) {
      out.write(_paint(token, _flagColor));
    } else {
      out.write(token);
    }
  }
  return out.toString();
}

String _paint(String text, int rgb, {bool bold = false, bool italic = false}) {
  final sgr = [
    if (bold) 1,
    if (italic) 3,
    38,
    2,
    (rgb >> 16) & 0xFF,
    (rgb >> 8) & 0xFF,
    rgb & 0xFF,
  ].join(';');
  return '\x1b[${sgr}m$text\x1b[0m';
}

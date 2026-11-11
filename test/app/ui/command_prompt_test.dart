import 'package:app_ui/app_ui.dart';
import 'package:flutter_test/flutter_test.dart';

final _escape = RegExp(r'\x1B\[[0-9;]*m');

/// Текст строки без цветовых последовательностей.
String _plain(String line) => line.replaceAll(_escape, '');

void main() {
  test('empty command has no prompt line', () {
    expect(commandPromptLine(''), isEmpty);
    expect(commandPromptLine('   \n '), isEmpty);
  });

  test('prompt is "\$ " followed by the command and a line break', () {
    expect(_plain(commandPromptLine('ls -la')), '\$ ls -la\r\n');
  });

  test('highlighting keeps the command text unchanged', () {
    const commands = [
      'git commit -m "fix: a | b" && echo \$HOME',
      "cat 'my file.txt' | grep -v '#' > out.txt 2>&1",
      'FOO=1 BAR=2 make build; echo done',
      'find . -name "*.dart" \\\n  -type f',
      '# comment only',
      'for i in 1 2; do echo \${i}; done',
      'echo "привет 👋" | wc -c # 🚀',
    ];
    for (final command in commands) {
      expect(
        _plain(commandPromptLine(command)),
        '\$ ${command.replaceAll('\n', '\r\n')}\r\n',
        reason: command,
      );
    }
  });

  test('program name is bold and flags have their own colour', () {
    final line = commandPromptLine('ls -la');
    expect(line, contains('\x1b[1;38;2;125;211;252mls\x1b[0m'));
    expect(line, contains('\x1b[38;2;147;197;253m-la\x1b[0m'));
  });

  test('program after a pipe is highlighted, not the argument', () {
    final line = commandPromptLine('cat a | grep b');
    expect(line, contains('\x1b[1;38;2;125;211;252mgrep\x1b[0m'));
    expect(line, isNot(contains('\x1b[1;38;2;125;211;252mb\x1b[0m')));
  });

  test('quoted strings and variables are coloured', () {
    final line = commandPromptLine('echo "hi" \$HOME');
    expect(line, contains('\x1b[38;2;134;239;172m"hi"\x1b[0m'));
    expect(line, contains('\x1b[38;2;251;191;36m\$HOME\x1b[0m'));
  });

  test('control characters from the command are removed', () {
    // ESC, BEL и CR удаляются; оставшиеся printable-символы остаются как текст.
    expect(
      _plain(commandPromptLine('echo \x1b[31mred\x07\r')),
      '\$ echo [31mred\r\n',
    );
  });

  test('multi-line command keeps every line', () {
    expect(_plain(commandPromptLine('a \\\n  b')), '\$ a \\\r\n  b\r\n');
  });
}

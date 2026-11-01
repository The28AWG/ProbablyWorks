import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/util/ansi_text.dart';

void main() {
  test('colour codes are removed', () {
    expect(plainTerminalText('\x1b[31mred\x1b[0m done'), 'red done');
  });

  test('OSC sequences such as window titles are removed', () {
    expect(plainTerminalText('\x1b]0;title\x07hi'), 'hi');
  });

  test('CRLF line endings become plain newlines', () {
    expect(plainTerminalText('one\r\ntwo\r\n'), 'one\ntwo\n');
  });

  test('a line redrawn with carriage return keeps its last visible state', () {
    expect(plainTerminalText('start\r50%\r100%\n'), '100%\n');
  });

  test('plain text is returned unchanged', () {
    expect(plainTerminalText('just text'), 'just text');
  });
}

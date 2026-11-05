import 'package:test/test.dart';
import 'package:virtual_host/src/shell/shell_text.dart';

void main() {
  group('ShellText: байты как в LC_ALL=C', () {
    test('длина считается в байтах UTF-8', () {
      expect(ShellText.byteLength('hello'), 5);
      expect(ShellText.byteLength('héllo'), 6);
      expect(ShellText.byteLength('привет'), 12);
      expect(ShellText.byteLength('日本'), 6);
    });

    test('срез по байтам попадает внутрь символа: результат — U+FFFD', () {
      // `é` занимает байты 1–2 строки `héllo`: срез [0, 2) заканчивается посреди символа.
      expect(ShellText.byteSlice('héllo', 0, 2), 'h\uFFFD');
      expect(ShellText.byteSlice('héllo', 1, 3), 'é');
    });

    test('`toByteChars` и `fromByteChars` обратимы для корректного UTF-8', () {
      const text = 'Привет, мир';
      expect(ShellText.fromByteChars(ShellText.toByteChars(text)), text);
    });

    test('верхний и нижний регистр меняют только ASCII', () {
      expect(ShellText.upperAscii('abcé'), 'ABCé');
      expect(ShellText.lowerAscii('ABCЁ'), 'abcЁ');
      expect(ShellText.toggleAscii('aBcЁ'), 'AbCЁ');
    });

    test('первый символ меняется как руна, остальные не трогаются', () {
      expect(ShellText.upperFirstAscii('abc'), 'Abc');
      expect(ShellText.upperFirstAscii('привет'), 'привет');
      expect(ShellText.lowerFirstAscii('ABC'), 'aBC');
      expect(ShellText.upperFirstAscii(''), '');
    });
  });

  group('ShellText.quote (@Q)', () {
    test('пустая строка — два апострофа', () {
      expect(ShellText.quote(''), "''");
    });

    test('печатный ASCII берётся в апострофы, апостроф экранируется', () {
      expect(ShellText.quote('a b'), "'a b'");
      expect(ShellText.quote("it's"), r"'it'\''s'");
    });

    test(
      'управляющие символы и не-ASCII — в \$\'...\' с восьмеричными кодами',
      () {
        expect(ShellText.quote('a\tb'), r"$'a\tb'");
        expect(ShellText.quote('\x7f'), r"$'\177'");
        expect(ShellText.quote('é'), r"$'\303\251'");
        expect(ShellText.quote("a'\\"), r"'a'\''\'");
      },
    );
  });

  group('ShellText.expandEscapes (@E)', () {
    test('простые escape-последовательности', () {
      expect(ShellText.expandEscapes(r'a\tb\nc'), 'a\tb\nc');
      expect(ShellText.expandEscapes(r'\\'), '\\');
    });

    test('восьмеричные, шестнадцатеричные и Unicode-коды', () {
      expect(ShellText.expandEscapes(r'\101\x42\u0043'), 'ABC');
      expect(ShellText.expandEscapes(r'\u00e9'), 'é');
    });

    test('неполные и неизвестные последовательности остаются как есть', () {
      expect(ShellText.expandEscapes(r'\q\x\u'), r'\q\x\u');
      expect(ShellText.expandEscapes(r'\U00110000'), r'\U00110000');
      expect(ShellText.expandEscapes(r'\uD800'), r'\uD800');
    });
  });
}

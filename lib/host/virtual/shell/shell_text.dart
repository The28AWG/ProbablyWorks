import 'dart:convert';
import 'dart:typed_data';

/// Строковые операции оболочки. Все они повторяют `LC_ALL=C`: bash под C-локалью считает длину, срезы и
/// образцы в байтах, а регистр меняет только у ASCII-букв. Строки Dart хранятся как UTF-16, поэтому
/// сначала строка переводится в байты (см. [toByteChars]), операция выполняется над ними, а результат
/// возвращается обратно в UTF-8.
///
/// Известное расхождение: срез или образец могут разрезать многобайтовый символ. bash вывел бы сырой байт,
/// здесь такой байт заменяется U+FFFD (см. [fromByteChars]), потому что результат должен быть строкой Dart.
abstract final class ShellText {
  const ShellText._();

  /// Байтовое представление строки: каждый символ результата — один байт UTF-8 (код 0–255). На нём
  /// работают длина, срезы и образцы; `?` в образце покрывает один такой байт, как в C-локали.
  static String toByteChars(String text) =>
      String.fromCharCodes(utf8.encode(text));

  /// Обратное к [toByteChars]. Неполная последовательность (срез попал внутрь символа) превращается в
  /// U+FFFD, а не в исключение: оболочка не должна падать из-за среза.
  static String fromByteChars(String bytes) =>
      utf8.decode(bytes.codeUnits, allowMalformed: true);

  /// Длина строки в байтах UTF-8, как `${#x}` под C-локалью.
  static int byteLength(String text) => utf8.encode(text).length;

  /// Срез по байтам: от [start] (включительно) до [end] (не включая). Границы должны лежать внутри строки;
  /// проверку и зажим делает вызывающий.
  static String byteSlice(String text, int start, int end) =>
      fromByteChars(cut(toByteChars(text), start, end));

  /// Срез по единицам UTF-16 без `String.substring` (правило DCM `avoid-substring`). Границы, которые
  /// передают сюда парсер и расширитель, всегда стоят у ASCII-разделителей (`}`, `:`, `/`, `[`), поэтому
  /// суррогатная пара не рвётся. Для байтовых строк (`toByteChars`) срез по байтам может разорвать
  /// многобайтовый символ; это задокументированная особенность, см. [byteSlice].
  static String cut(String text, int start, [int? end]) =>
      String.fromCharCodes(text.codeUnits, start, end);

  /// Все ASCII-буквы в заглавные. Не-ASCII символы (кириллица, эмодзи) не меняются, как в C-локали.
  static String upperAscii(String text) => _mapAscii(text, _upperCode);

  /// Все ASCII-буквы в строчные. Не-ASCII символы не меняются.
  static String lowerAscii(String text) => _mapAscii(text, _lowerCode);

  /// ASCII-буквы меняют регистр на противоположный (`${x~~}`), остальное не трогается.
  static String toggleAscii(String text) => _mapAscii(text, _toggleCode);

  /// Первый символ в заглавный, если это ASCII-буква (`${x@u}`).
  static String upperFirstAscii(String text) => _mapFirst(text, _upperCode);

  /// Первый символ в строчный, если это ASCII-буква (`${x@l}`).
  static String lowerFirstAscii(String text) => _mapFirst(text, _lowerCode);

  /// Форма `${x@Q}`: текст, который bash читает обратно как одно слово. Печатные ASCII-строки берутся в
  /// `'...'`, остальные (управляющие символы, не-ASCII байты) — в `$'...'` с восьмеричными escape-кодами,
  /// как у bash.
  static String quote(String text) {
    if (text.isEmpty) return "''";
    final bytes = utf8.encode(text);
    var printable = true;
    for (final b in bytes) {
      if (b < 0x20 || b >= 0x7f) printable = false;
    }
    if (printable) return "'${text.replaceAll("'", r"'\''")}'";
    final out = StringBuffer(r"$'");
    for (final b in bytes) {
      out.write(switch (b) {
        0x5c => r'\\',
        0x27 => r"\'",
        0x0a => r'\n',
        0x09 => r'\t',
        0x0d => r'\r',
        0x07 => r'\a',
        0x08 => r'\b',
        0x0c => r'\f',
        0x0b => r'\v',
        0x1b => r'\E',
        _ when b < 0x20 || b >= 0x7f =>
          '\\${b.toRadixString(8).padLeft(3, '0')}',
        _ => String.fromCharCode(b),
      });
    }
    out.write("'");
    return out.toString();
  }

  /// Форма `${x@E}`: раскрывает escape-последовательности как `$'...'` и `echo -e`: `\n`, `\t`, `\xHH`,
  /// `\NNN` (восьмеричные), `\uHHHH`, `\UHHHHHHHH`. Неизвестная последовательность остаётся как есть.
  static String expandEscapes(String text) {
    final bytes = utf8.encode(text);
    final out = BytesBuilder();
    var i = 0;
    while (i < bytes.length) {
      final b = bytes[i];
      if (b != 0x5c || i + 1 >= bytes.length) {
        out.addByte(b);
        i++;
        continue;
      }
      final escape = bytes[i + 1];
      i += 2;
      final simple = _simpleEscape(escape);
      if (simple != null) {
        out.addByte(simple);
        continue;
      }
      if (_isOctal(escape)) {
        var value = escape - 0x30;
        for (var k = 0; k < 2 && i < bytes.length && _isOctal(bytes[i]); k++) {
          value = value * 8 + bytes[i] - 0x30;
          i++;
        }
        out.addByte(value & 0xff);
        continue;
      }
      if (escape == 0x78) {
        // `\xHH`: до двух шестнадцатеричных цифр.
        final hex = _readHex(bytes, i, 2);
        if (hex == null) {
          out.add([0x5c, escape]);
        } else {
          out.addByte(hex.$1);
          i = hex.$2;
        }
        continue;
      }
      if (escape == 0x75 || escape == 0x55) {
        // `\uHHHH` и `\UHHHHHHHH`: символ Unicode, кодируется в UTF-8. Значения вне диапазона
        // Unicode и суррогаты не являются символами: такие последовательности остаются как есть.
        final digits = escape == 0x75 ? 4 : 8;
        final hex = _readHex(bytes, i, digits);
        if (hex == null || hex.$1 > 0x10ffff || _isSurrogate(hex.$1)) {
          out.add([0x5c, escape]);
        } else {
          out.add(utf8.encode(String.fromCharCode(hex.$1)));
          i = hex.$2;
        }
        continue;
      }
      out
        ..addByte(0x5c)
        ..addByte(escape);
    }
    return utf8.decode(out.takeBytes(), allowMalformed: true);
  }

  static int _upperCode(int c) => c >= 0x61 && c <= 0x7a ? c - 0x20 : c;

  static int _lowerCode(int c) => c >= 0x41 && c <= 0x5a ? c + 0x20 : c;

  static int _toggleCode(int c) =>
      _upperCode(c) == c ? _lowerCode(c) : _upperCode(c);

  /// Меняет каждый код UTF-16 строки. ASCII-буквы в UTF-8 всегда отдельные единицы, поэтому замена
  /// не портит многобайтовые символы.
  static String _mapAscii(String text, int Function(int) map) =>
      String.fromCharCodes([for (final c in text.codeUnits) map(c)]);

  /// Меняет только первый символ (руну), остальные оставляет.
  static String _mapFirst(String text, int Function(int) map) {
    if (text.isEmpty) return text;
    final runes = text.runes;
    return String.fromCharCodes([map(runes.first), ...runes.skip(1)]);
  }

  static int? _simpleEscape(int escape) => switch (escape) {
    0x61 => 0x07, // \a
    0x62 => 0x08, // \b
    0x65 || 0x45 => 0x1b, // \e, \E
    0x66 => 0x0c, // \f
    0x6e => 0x0a, // \n
    0x72 => 0x0d, // \r
    0x74 => 0x09, // \t
    0x76 => 0x0b, // \v
    0x5c => 0x5c, // \\
    0x27 => 0x27, // \'
    0x22 => 0x22, // \"
    0x3f => 0x3f, // \?
    _ => null,
  };

  static bool _isOctal(int b) => b >= 0x30 && b <= 0x37;

  static bool _isSurrogate(int c) => c >= 0xd800 && c <= 0xdfff;

  /// Читает до [maxDigits] шестнадцатеричных цифр с позиции [from]. Возвращает значение и позицию за
  /// последней цифрой, либо null, если цифр нет.
  static (int, int)? _readHex(List<int> bytes, int from, int maxDigits) {
    var value = 0;
    var count = 0;
    var i = from;
    while (count < maxDigits && i < bytes.length) {
      final digit = int.tryParse(String.fromCharCode(bytes[i]), radix: 16);
      if (digit == null) break;
      value = value * 16 + digit;
      count++;
      i++;
    }
    return count == 0 ? null : (value, i);
  }
}

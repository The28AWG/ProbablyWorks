/// Разбор `@`-токенов в строке поиска.
///
/// Общий код палитры команд и выбора модели: токен начинается со `@` в начале
/// строки или после пробела; значение может быть в кавычках
/// (`@provider:"llama.cpp"`), а `\"` внутри кавычек не закрывает их. Токен после
/// `@` внутри слова (`foo@bar`) фильтром не считается.
///
/// Позиции токена — смещения в UTF-16, как у [TextSelection]: по ним строка
/// правится через `replaceRange`, а каретка ставится в поле ввода.
library;

/// Разобранный `@`-токен: границы в строке, имя и значение.
class AtToken {
  const AtToken({
    required this.raw,
    required this.start,
    required this.end,
    required this.name,
    required this.value,
    required this.hasValue,
  });

  /// Исходный текст токена целиком, включая `@` и значение.
  final String raw;

  /// Смещение `@` в строке.
  final int start;

  /// Смещение символа после токена.
  final int end;

  /// Имя фильтра без `@` и значения, в нижнем регистре.
  final String name;

  /// Значение после `:` без кавычек. Пустая строка, если значения нет.
  final String value;

  /// Было ли в токене двоеточие. Отличает `@free` от `@free:`.
  final bool hasValue;

  @override
  String toString() => 'AtToken($raw, name: $name, value: $value)';
}

/// Утилиты сканирования и разбора `@`-токенов.
abstract final class AtQuery {
  const AtQuery._();

  /// Пробельный символ: разделяет токены и не входит в них.
  static bool isSpace(String char) => char.trim().isEmpty;

  /// Срез строки по смещениям UTF-16.
  ///
  /// `substring` запрещён правилом `avoid-substring`: там, где смещения берутся
  /// из каретки, нужны именно кодовые единицы, а не графемы.
  static String textOf(String raw, int start, int end) =>
      String.fromCharCodes(raw.codeUnits, start, end);

  /// Начинается ли в [index] новый `@`-токен.
  static bool isTokenStart(String raw, int index) =>
      index >= 0 &&
      index < raw.length &&
      raw[index] == '@' &&
      (index == 0 || isSpace(raw[index - 1]));

  /// Конец токена, который начинается с `@` в [start]. Кавычки защищают пробелы.
  static int tokenEnd(String raw, int start) {
    var quoted = false;
    var escaped = false;
    for (var i = start + 1; i < raw.length; i++) {
      final char = raw[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (char == r'\') {
        escaped = true;
        continue;
      }
      if (char == '"') {
        quoted = !quoted;
        continue;
      }
      if (!quoted && isSpace(char)) return i;
    }
    return raw.length;
  }

  /// Все токены строки в порядке появления. Всё остальное — свободный текст.
  static List<AtToken> tokens(String raw) {
    final result = <AtToken>[];
    var index = 0;
    while (index < raw.length) {
      if (!isTokenStart(raw, index)) {
        index++;
        continue;
      }
      final end = tokenEnd(raw, index);
      result.add(parse(raw, index, end));
      index = end;
    }
    return result;
  }

  /// Разбор токена по известным границам [start] (индекс `@`) и [end].
  static AtToken parse(String raw, int start, int end) {
    final token = textOf(raw, start, end);
    final body = textOf(token, 1, token.length);
    final split = body.indexOf(':');
    final name = (split < 0 ? body : textOf(body, 0, split)).toLowerCase();
    return AtToken(
      raw: token,
      start: start,
      end: end,
      name: name,
      value: split < 0
          ? ''
          : unquote(textOf(body, split + 1, body.length).trim()),
      hasValue: split >= 0,
    );
  }

  /// Снимает кавычки значения. Неполные кавычки остаются как есть: значение
  /// ещё вводится, и автодополнение показывает его без первой кавычки.
  static String unquote(String value) {
    if (value.length < 2 || !value.startsWith('"') || !value.endsWith('"')) {
      return value;
    }
    return textOf(value, 1, value.length - 1).replaceAll(r'\"', '"');
  }
}

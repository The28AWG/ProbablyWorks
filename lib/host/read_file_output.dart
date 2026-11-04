import 'package:probably_works/host/shell_adapter.dart';

/// Разбор вывода инструмента read_file для показа в чате.
///
/// Формат задаёт [ShellAdapter.readFile]: POSIX (awk) и Windows (PowerShell) выводят одинаковый текст.
/// Парсер строгий: если вывод не совпал с форматом, [parseReadFileOutput] возвращает `null`, и шаг
/// показывает сырой вывод как раньше. Так поломка формата на Host не скрывает результат.
///
/// Строка файла распознаётся только по префиксу в начале строки, а номера обязаны идти подряд.
/// Поэтому строка содержимого вида `12: x` не спутается с префиксом, а пропуск номера считается ошибкой.
ReadFileOutput? parseReadFileOutput(String text) {
  try {
    return _parse(text);
  } on FormatException {
    // Число вне диапазона int: формат не распознан, показываем сырой вывод.
    return null;
  }
}

/// Результат разбора вывода read_file.
sealed class ReadFileOutput {
  const ReadFileOutput();
}

/// Текст файла: строки с номерами и подвал с подсказкой продолжения.
final class ReadFileText extends ReadFileOutput {
  const ReadFileText({
    required this.totalLines,
    required this.totalBytes,
    required this.lines,
    this.footer,
  });

  /// Всего строк в файле по заголовку.
  final int totalLines;

  /// Размер файла в байтах по заголовку.
  final int totalBytes;

  /// Строки, которые вернул вызов. Номера идут подряд; первая может быть продолжением строки.
  final List<ReadFileLine> lines;

  /// Подвал. `null`, если вывод его не содержит.
  final ReadFileFooter? footer;
}

/// Строка файла с номером. [byteOffset] больше нуля означает, что строка продолжается с этого байта.
final class ReadFileLine {
  const ReadFileLine({
    required this.number,
    required this.text,
    this.byteOffset = 0,
  });

  /// Номер строки в файле, с 1.
  final int number;

  /// Байтовое смещение внутри строки; 0 — строка выведена целиком.
  final int byteOffset;

  /// Текст строки без префикса с номером. Управляющие последовательности не очищены.
  final String text;
}

/// Подвал вывода read_file. Говорит, что делать дальше: конец файла или куда продолжить чтение.
sealed class ReadFileFooter {
  const ReadFileFooter();
}

/// Файл выведен до конца.
final class ReadFileEndOfFile extends ReadFileFooter {
  const ReadFileEndOfFile();
}

/// Вывод остановлен лимитом; продолжение со строки [offset].
final class ReadFileMore extends ReadFileFooter {
  const ReadFileMore({required this.offset});

  /// Номер строки, с которой продолжить чтение.
  final int offset;
}

/// Последняя строка разрезана по лимиту; продолжение с байта [byteOffset] строки [offset].
final class ReadFileCut extends ReadFileFooter {
  const ReadFileCut({
    required this.line,
    required this.byte,
    required this.lineBytes,
    required this.offset,
    required this.byteOffset,
  });

  /// Номер разрезанной строки.
  final int line;

  /// Байт, на котором строка разрезана.
  final int byte;

  /// Полная длина строки в байтах.
  final int lineBytes;

  /// Строка, с которой продолжить (совпадает с [line]).
  final int offset;

  /// Байт внутри строки, с которого продолжить.
  final int byteOffset;
}

/// Вызов начат за концом файла: строк нет. Для пустого файла [totalLines] равен нулю.
final class ReadFileBeyondEnd extends ReadFileOutput {
  const ReadFileBeyondEnd({
    required this.offset,
    required this.totalLines,
    required this.totalBytes,
  });

  /// Запрошенная строка.
  final int offset;

  /// Всего строк в файле.
  final int totalLines;

  /// Размер файла в байтах.
  final int totalBytes;
}

/// Ожидаемая ошибка чтения. Файл есть, но его нельзя показать как текст. Это штатный исход, не сбой.
final class ReadFileError extends ReadFileOutput {
  const ReadFileError(this.kind);

  /// Причина отказа.
  final ReadFileErrorKind kind;
}

/// Причина, по которой read_file не выводит текст.
enum ReadFileErrorKind {
  /// Не обычный файл или нет прав на чтение.
  notReadable,

  /// Файл содержит NUL, то есть бинарный.
  binary,
}

final _header = RegExp(r'^\[file: (\d+) lines, (\d+) bytes\]$');
final _beyond = RegExp(
  r'^\[offset (\d+) is beyond the end of the file \((\d+) lines\)\]$',
);

/// `N: текст` или `N (from byte B): текст`. Флаг dotAll нужен, чтобы `.` покрывал `\r` в содержимом.
final _line = RegExp(r'^(\d+)(?: \(from byte (\d+)\))?: (.*)$', dotAll: true);
final _more = RegExp(r'^\[more: continue with offset=(\d+)\]$');
final _cut = RegExp(
  r'^\[line (\d+) is cut at byte (\d+) of (\d+) bytes: '
  r'continue with offset=(\d+) byte_offset=(\d+)\]$',
);

ReadFileOutput? _parse(String text) {
  final trimmed = text.trim();
  if (trimmed == ShellAdapter.readFileNotReadableMessage) {
    return const ReadFileError(ReadFileErrorKind.notReadable);
  }
  if (trimmed == ShellAdapter.readFileBinaryMessage) {
    return const ReadFileError(ReadFileErrorKind.binary);
  }

  // Последний перевод строки не даёт пустой строки, поэтому его убираем.
  final lines = text.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  if (lines.isEmpty) return null;

  final header = _header.firstMatch(lines.first);
  if (header == null) return null;
  final totalLines = int.parse(header[1]!);
  final totalBytes = int.parse(header[2]!);

  if (lines.length > 1) {
    final beyond = _beyond.firstMatch(lines[1]);
    if (beyond != null) {
      // Сообщение за концом файла — единственная строка после заголовка.
      if (lines.length != 2) return null;
      return ReadFileBeyondEnd(
        offset: int.parse(beyond[1]!),
        totalLines: int.parse(beyond[2]!),
        totalBytes: totalBytes,
      );
    }
  }

  final body = <ReadFileLine>[];
  ReadFileFooter? footer;
  for (var i = 1; i < lines.length; i++) {
    final raw = lines[i];
    if (raw.startsWith('[')) {
      // Подвал всегда последний и встречается один раз.
      if (i != lines.length - 1) return null;
      footer = _footer(raw);
      if (footer == null) return null;
      continue;
    }
    final match = _line.firstMatch(raw);
    if (match == null) return null;
    final number = int.parse(match[1]!);
    final byteOffset = match[2] == null ? 0 : int.parse(match[2]!);
    if (body.isNotEmpty) {
      // Продолжение строки бывает только у первой строки вызова, остальные идут подряд.
      if (byteOffset != 0 || number != body.last.number + 1) return null;
    }
    body.add(
      ReadFileLine(number: number, byteOffset: byteOffset, text: match[3]!),
    );
  }

  return ReadFileText(
    totalLines: totalLines,
    totalBytes: totalBytes,
    lines: body,
    footer: footer,
  );
}

ReadFileFooter? _footer(String line) {
  if (line == '[end of file]') return const ReadFileEndOfFile();
  final more = _more.firstMatch(line);
  if (more != null) return ReadFileMore(offset: int.parse(more[1]!));
  final cut = _cut.firstMatch(line);
  if (cut != null) {
    return ReadFileCut(
      line: int.parse(cut[1]!),
      byte: int.parse(cut[2]!),
      lineBytes: int.parse(cut[3]!),
      offset: int.parse(cut[4]!),
      byteOffset: int.parse(cut[5]!),
    );
  }
  return null;
}

import 'dart:convert';

import 'package:pw_agent/agent/domain/chat_models.dart';

/// Текст упоминания файла или каталога workspace.
///
/// В поле ввода пользователь видит только последний сегмент пути (`@app.dart`,
/// `@"файл с пробелами.txt"`, `@features/`), а полный путь живёт в
/// [MentionRef.path]. Здесь собраны обе формы, чтобы вставка в поле и сборка
/// контекста для модели не расходились.
abstract final class MentionText {
  const MentionText._();

  /// Последний сегмент пути. Путь в [MentionRef] уже нормализован и не имеет
  /// хвостового разделителя.
  static String nameOf(String path) {
    final parts = path.split('/').where((part) => part.isNotEmpty).toList();
    return parts.isEmpty ? path : parts.last;
  }

  /// Токен, который вставляется в поле ввода. Для каталога добавляется `/`,
  /// чтобы он отличался от одноимённого файла.
  static String displayToken(String path, MentionKind kind) {
    final name = nameOf(path);
    final body = kind == MentionKind.directory ? '$name/' : name;
    return '@${_quoteIfNeeded(body)}';
  }

  /// Токен для контекста модели: полный путь относительно workspace.
  static String contextToken(String path, MentionKind kind) {
    final body = kind == MentionKind.directory ? '$path/' : path;
    return '@${_quoteIfNeeded(body)}';
  }

  /// Полный путь, который увидит модель. Упоминания с испорченным диапазоном
  /// или небезопасным путём не применяются: исходный текст остаётся как есть.
  ///
  /// Диапазоны трактуются как смещения UTF-16, как у [TextSelection].
  static String resolve(String text, List<MentionRef> mentions) {
    if (mentions.isEmpty) return text;
    final ordered = [...mentions]..sort((a, b) => a.start.compareTo(b.start));
    final buffer = StringBuffer();
    var cursor = 0;
    var changed = false;
    for (final mention in ordered) {
      if (!_isValidRange(text, mention) || mention.start < cursor) continue;
      if (!isSafePath(mention.path)) continue;
      buffer
        ..write(_range(text, cursor, mention.start))
        ..write(contextToken(mention.path, mention.kind));
      cursor = mention.end;
      changed = true;
    }
    if (!changed) return text;
    buffer.write(_range(text, cursor, text.length));
    return buffer.toString();
  }

  /// Сдвигает диапазоны на отрезанный при `trim` префикс. Упоминания, которые
  /// вышли за границы нового текста, отбрасываются.
  static List<MentionRef> shiftForTrimmed(
    String original,
    String trimmed,
    List<MentionRef> mentions,
  ) {
    if (mentions.isEmpty) return const [];
    final leading = trimmed.isEmpty ? 0 : original.indexOf(trimmed);
    if (leading < 0) return const [];
    return [
      for (final mention in mentions)
        if (mention.start >= leading && mention.end <= leading + trimmed.length)
          mention.copyWith(
            start: mention.start - leading,
            end: mention.end - leading,
          ),
    ];
  }

  /// Путь пригоден для упоминания: относительный, без `..`, `~` и диска.
  ///
  /// Проверка лексическая: существование файла и выход за пределы workspace
  /// проверяет Host, а диапазон упоминания не должен выглядеть как абсолютный
  /// путь ещё до вызова инструмента.
  static bool isSafePath(String path) {
    final value = path.trim();
    if (value.isEmpty || value.startsWith('/') || value.startsWith('~')) {
      return false;
    }
    if (value.contains(r'\')) return false;
    if (RegExp(r'^[A-Za-z]:').hasMatch(value)) return false;
    return !value.split('/').any((part) => part == '..');
  }

  static bool _isValidRange(String text, MentionRef mention) =>
      mention.start >= 0 &&
      mention.end > mention.start &&
      mention.end <= text.length &&
      text[mention.start] == '@';

  /// Срез по смещениям UTF-16. `substring` запрещён правилом `avoid-substring`:
  /// каретка и диапазоны живут в кодовых единицах, а не в графемах.
  static String _range(String text, int start, int end) =>
      String.fromCharCodes(text.codeUnits, start, end);

  static String _quoteIfNeeded(String value) {
    final needsQuotes =
        value.isEmpty ||
        value.contains(RegExp(r'\s')) ||
        value.contains('"') ||
        value.contains(r'\') ||
        value.contains('@');
    if (!needsQuotes) return value;
    return '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  }

  /// JSON-представление пути для подсказок и отладочных сообщений. Имена
  /// файлов могут содержать кавычки и переводы строк, поэтому в текст модели
  /// они попадают в кавычках JSON.
  static String quotedJson(String value) => jsonEncode(value);
}

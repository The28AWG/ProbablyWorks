import 'package:flutter/widgets.dart';
import 'package:probably_works/core/util/at_query.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/core/util/char_substring.dart';

/// `@`-токен под кареткой.
///
/// Список файлов реагирует на сам текст, а не на наличие [MentionRef]: так
/// вставленный из буфера `@app.dart` тоже можно превратить в упоминание.
class MentionQuery {
  const MentionQuery({
    required this.start,
    required this.end,
    required this.value,
  });

  /// Смещение `@` в тексте (UTF-16).
  final int start;

  /// Смещение после токена (UTF-16).
  final int end;

  /// Значение без `@` и кавычек; по нему фильтруется список.
  final String value;

  /// Ищет токен, в диапазон которого попадает каретка. Выделение не схлопнуто —
  /// это не ввод, а перетаскивание: список не открываем.
  static MentionQuery? at(String text, TextSelection selection) {
    if (!selection.isCollapsed) return null;
    final caret = selection.extentOffset;
    for (final token in AtQuery.tokens(text)) {
      if (caret < token.start || caret > token.end) continue;
      final body = charFrom(token.raw, 1);
      final value = AtQuery.unquote(
        token.raw.startsWith('@') ? body : token.raw,
      );
      return MentionQuery(start: token.start, end: token.end, value: value);
    }
    return null;
  }

  /// Упоминание, которое пересекается с токеном. Нужно, чтобы показать
  /// текущий путь и обновить его, а не добавить второй.
  static MentionRef? mentionIn(List<MentionRef> mentions, MentionQuery query) {
    for (final mention in mentions) {
      if (mention.start < query.end && mention.end > query.start) {
        return mention;
      }
    }
    return null;
  }
}

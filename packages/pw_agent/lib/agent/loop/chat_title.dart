import 'package:pw_agent/core/util/char_substring.dart';

/// Заголовок чата: запасной вариант из первого сообщения и очистка ответа модели.
abstract final class ChatTitle {
  const ChatTitle._();

  static const maxChars = 60;
  static const maxWords = 10;

  /// Запас по токенам: короткий заголовок, но место для служебного текста модели.
  static const maxTokens = 256;

  /// Системный промпт запроса заголовка. По нему же узнаётся такой запрос (тесты).
  static const systemPrompt =
      'Write a short chat title (at most 6 words) for the user request. '
      'Reply with the title only, no quotes, no explanations.';

  static final _think = RegExp(
    r'<think>[\s\S]*?(</think>|$)',
    caseSensitive: false,
  );
  static final _label = RegExp(
    r'^(title|заголовок)\s*:\s*',
    caseSensitive: false,
  );
  static final _wrap = RegExp(r'''^[\s"'`*#_«»“”„.!?]+|[\s"'`*#_«»“”„.!?]+$''');
  static final _meta = RegExp(
    r"\b(the user|user wants|user's|chat title)\b|пользовател",
    caseSensitive: false,
  );

  /// Запасной заголовок: первое сообщение, обрезанное до [maxChars].
  static String fallback(String text) {
    final single = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return single.length <= maxChars
        ? single
        : '${charPrefix(single, maxChars)}…';
  }

  /// Заголовок из ответа модели или null, если ответ непригоден: пусто, рассуждения,
  /// пересказ инструкции, слишком длинный текст. Для null вызывающий оставляет fallback.
  static String? sanitize(String raw) {
    final text = raw.replaceAll(_think, '');
    final line = text
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    final title = line
        .replaceAll(_wrap, '')
        .replaceFirst(_label, '')
        .replaceAll(_wrap, '')
        .trim();
    if (title.isEmpty) return null;
    if (title.split(RegExp(r'\s+')).length > maxWords) return null;
    if (_meta.hasMatch(title)) return null;
    return title.length > maxChars ? fallback(title) : title;
  }
}

import 'package:pw_agent/core/util/char_substring.dart';

/// Обрезка длинного текста: голова и хвост сохраняются, середина заменяется маркером.
abstract final class TextClip {
  const TextClip._();

  /// Возвращает [text] не длиннее примерно [maxChars] символов.
  static String headTail(String text, {required int maxChars}) {
    if (text.length <= maxChars) return text;
    final head = (maxChars * 0.6).floor();
    final tail = maxChars - head;
    final omitted = text.length - maxChars;
    return '${charPrefix(text, head)}\n…[truncated $omitted chars]…\n'
        '${charSuffix(text, tail)}';
  }
}

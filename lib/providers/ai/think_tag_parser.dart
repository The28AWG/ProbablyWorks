import 'package:characters/characters.dart';
import 'package:probably_works/providers/ai/llm_port.dart';

/// Выделяет рассуждения, которые некоторые модели пишут прямо в `content` между `<think>` и `</think>`.
///
/// Работает по кускам потока: тег, разрезанный между двумя кусками, не утекает в текст ответа.
class ThinkTagParser {
  static const _open = '<think>';
  static const _close = '</think>';

  var _inside = false;

  /// Хвост куска, который может оказаться началом тега; ждёт следующего куска.
  var _pending = '';

  /// События для очередного куска в исходном порядке.
  List<LlmEvent> add(String chunk) {
    final out = <LlmEvent>[];
    var rest = _pending + chunk;
    _pending = '';
    while (true) {
      final tag = _inside ? _close : _open;
      final index = rest.indexOf(tag);
      if (index >= 0) {
        _emit(out, _prefix(rest, index));
        rest = _suffix(rest, index + tag.length);
        _inside = !_inside;
        continue;
      }
      final keep = _partialTagLength(rest, tag);
      final splitAt = rest.length - keep;
      _emit(out, _prefix(rest, splitAt));
      _pending = _suffix(rest, splitAt);
      return out;
    }
  }

  /// Конец потока: хвост, который так и не стал тегом, уходит в текущий режим.
  List<LlmEvent> flush() {
    final out = <LlmEvent>[];
    _emit(out, _pending);
    _pending = '';
    return out;
  }

  void _emit(List<LlmEvent> out, String text) {
    if (text.isEmpty) return;
    out.add(_inside ? LlmReasoningDelta(text) : LlmTextDelta(text));
  }

  static String _prefix(String text, int endCodeUnits) {
    if (endCodeUnits <= 0) return '';
    if (endCodeUnits >= text.length) return text;
    var units = 0;
    final out = StringBuffer();
    for (final char in text.characters) {
      final next = units + char.length;
      if (next > endCodeUnits) break;
      out.write(char);
      units = next;
    }
    return out.toString();
  }

  static String _suffix(String text, int startCodeUnits) {
    if (startCodeUnits >= text.length) return '';
    var units = 0;
    final out = StringBuffer();
    for (final char in text.characters) {
      if (units >= startCodeUnits) out.write(char);
      units += char.length;
    }
    return out.toString();
  }

  /// Длина самого длинного суффикса [text], который совпадает с началом [tag].
  static int _partialTagLength(String text, String tag) {
    for (var len = tag.characters.length - 1; len > 0; len--) {
      final prefix = tag.characters.take(len).string;
      if (text.endsWith(prefix)) return prefix.length;
    }
    return 0;
  }
}

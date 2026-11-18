import 'package:flutter/widgets.dart';
import 'package:probably_works/features/chat/presentation/widgets/mention_query.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/workspace_entry.dart';
import 'package:pw_agent/core/util/mention_text.dart';

/// Контроллер поля ввода, который хранит текст и диапазоны [MentionRef].
///
/// Пользователь видит только basename (`@app.dart`), а полный путь живёт в
/// метаданных. При правке текста:
/// - изменения до/после токена сдвигают диапазон;
/// - изменение внутри токена удаляет упоминание;
/// - дописанная в конец буква/точка/слеш тоже считается изменением имени.
///
/// Так путь не угадывается по тексту и не «переезжает» на другой файл.
class MentionTextController extends TextEditingController {
  MentionTextController({super.text, List<MentionRef> mentions = const []})
    : _mentions = _valid(mentions, text ?? '') {
    _lastText = value.text;
    addListener(_track);
  }

  List<MentionRef> _mentions;
  late String _lastText;
  var _suppress = false;

  /// Растёт при [resetDraft]. Автодополнение по этому сигналу не открывает
  /// список само: загрузка черновика не должна выглядеть как набор `@`.
  var resetRevision = 0;

  List<MentionRef> get mentions => List.unmodifiable(_mentions);

  /// Вызывается, когда изменились только метаданные (без изменения текста):
  /// повторный выбор того же basename или очистка упоминания.
  ValueChanged<List<MentionRef>>? onMentionsChanged;

  /// Программно заменить текст и диапазоны (смена чата, черновик, очередь).
  void resetDraft(String text, List<MentionRef> mentions) {
    final safe = _valid(mentions, text);
    resetRevision++;
    _suppress = true;
    value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _lastText = text;
    _mentions = safe;
    _suppress = false;
  }

  /// Применить выбранный файл к токену. Если под диапазоном уже есть
  /// упоминание, оно заменяется; если нет — добавляется новое.
  void applySelection(MentionQuery token, WorkspaceEntry entry) {
    final oldText = text;
    final display = MentionText.displayToken(
      entry.path,
      entry.isDirectory ? MentionKind.directory : MentionKind.file,
    );
    final current = _range(oldText, token.start, token.end);
    final overlap = _mentions
        .where((m) => m.start < token.end && m.end > token.start)
        .toList();

    if (overlap.length == 1 && current == display) {
      final old = overlap.single;
      _replace(
        old,
        old.copyWith(
          kind: entry.isDirectory ? MentionKind.directory : MentionKind.file,
          path: entry.path,
        ),
      );
      return;
    }

    final atEnd = token.end == oldText.length;
    final trailing = atEnd ? ' ' : '';
    final nextText = oldText.replaceRange(
      token.start,
      token.end,
      '$display$trailing',
    );
    final delta = nextText.length - oldText.length;
    final next = <MentionRef>[
      for (final mention in _mentions)
        if (!overlap.contains(mention))
          if (mention.start >= token.end)
            mention.copyWith(
              start: mention.start + delta,
              end: mention.end + delta,
            )
          else
            mention,
      MentionRef(
        kind: entry.isDirectory ? MentionKind.directory : MentionKind.file,
        path: entry.path,
        start: token.start,
        end: token.start + display.length,
      ),
    ];
    _suppress = true;
    value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(
        offset: token.start + display.length + trailing.length,
      ),
    );
    _lastText = nextText;
    _mentions = _valid(next, nextText);
    _suppress = false;
    _notifyMentions();
  }

  /// Убирает упоминание по диапазону (например, из контекстного меню).
  void removeMention(MentionRef mention) {
    if (!_mentions.contains(mention)) return;
    _mentions = [
      for (final item in _mentions)
        if (item != mention) item,
    ];
    _notifyMentions();
  }

  void _track() {
    if (_suppress) return;
    final newText = text;
    if (newText == _lastText) return;
    final oldText = _lastText;
    final prefix = _commonPrefix(oldText, newText);
    final suffix = _commonSuffix(oldText, newText, prefix);
    final oldEnd = oldText.length - suffix;
    final inserted = _range(newText, prefix, newText.length - suffix);
    final delta = newText.length - oldText.length;
    final next = <MentionRef>[];
    for (final mention in _mentions) {
      final atEnd = mention.end == prefix;
      final atStart = mention.start == oldEnd;
      final overlaps = mention.start < oldEnd && mention.end > prefix;
      if (overlaps) continue;
      if (atEnd &&
          delta > 0 &&
          _isContinuation(inserted) &&
          !_isQuoted(oldText, mention)) {
        continue;
      }
      if (atStart && delta > 0 && _isContinuation(inserted)) continue;
      if (mention.end <= prefix) {
        next.add(mention);
      } else if (mention.start >= oldEnd) {
        next.add(
          mention.copyWith(
            start: mention.start + delta,
            end: mention.end + delta,
          ),
        );
      } else {
        next.add(mention);
      }
    }
    _lastText = newText;
    _mentions = _valid(next, newText);
    // Сдвиг диапазонов при наборе текста не требует отдельного события:
    // ChatBody всё равно увидит изменение текста и прочитает mentions.
  }

  void _replace(MentionRef old, MentionRef next) {
    final list = [
      for (final item in _mentions)
        if (item == old) next else item,
    ];
    _mentions = _valid(list, text);
    _notifyMentions();
  }

  void _notifyMentions() => onMentionsChanged?.call(mentions);

  static bool _isQuoted(String text, MentionRef mention) =>
      mention.end > mention.start && text[mention.end - 1] == '"';

  /// Символ продолжает имя файла, а не завершает предложение.
  static bool _isContinuation(String value) {
    if (value.isEmpty) return false;
    for (final rune in value.runes) {
      final char = String.fromCharCode(rune);
      final continuation = RegExp(
        r'[\p{L}\p{N}_./\\~$#%+@:-]',
        unicode: true,
      ).hasMatch(char);
      if (!continuation) return false;
    }
    return true;
  }

  static int _commonPrefix(String a, String b) {
    var index = 0;
    while (index < a.length &&
        index < b.length &&
        a.codeUnitAt(index) == b.codeUnitAt(index)) {
      index++;
    }
    return index;
  }

  static int _commonSuffix(String a, String b, int prefix) {
    var count = 0;
    while (a.length - count - 1 >= prefix &&
        b.length - count - 1 >= prefix &&
        a.codeUnitAt(a.length - count - 1) ==
            b.codeUnitAt(b.length - count - 1)) {
      count++;
    }
    return count;
  }

  static List<MentionRef> _valid(List<MentionRef> mentions, String text) {
    final sorted = [...mentions]..sort((a, b) => a.start.compareTo(b.start));
    final result = <MentionRef>[];
    var cursor = -1;
    for (final mention in sorted) {
      if (mention.start < 0 ||
          mention.end <= mention.start ||
          mention.end > text.length ||
          mention.start <= cursor ||
          !MentionText.isSafePath(mention.path) ||
          text[mention.start] != '@') {
        continue;
      }
      result.add(mention);
      cursor = mention.end - 1;
    }
    return result;
  }

  static String _range(String text, int start, int end) =>
      String.fromCharCodes(text.codeUnits, start, end);
}

import 'package:probably_works/core/util/char_substring.dart';

/// Текст из недоверенных источников (вывод команд, файлы, AGENTS.md, skills, вложения).
/// Оборачивается в маркер, чтобы модель считала его данными, а не инструкциями.
abstract final class Untrusted {
  const Untrusted._();

  static final _tagPattern = RegExp('</?untrusted', caseSensitive: false);

  static String wrap(String source, String text) {
    // Закрывающий тег внутри данных не должен выходить за границы блока.
    final safe = text.replaceAllMapped(
      _tagPattern,
      (m) => '[${charFrom(m[0]!, 1)}',
    );
    return '<untrusted source="${source.replaceAll('"', "'")}">\n$safe\n</untrusted>';
  }
}

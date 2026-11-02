import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/providers/ai/llm_port.dart';
import 'package:probably_works/providers/ai/think_tag_parser.dart';

/// Прогоняет куски через парсер и возвращает итоговые пары (вид, текст) по порядку.
List<(String, String)> _run(List<String> chunks) {
  final parser = ThinkTagParser();
  final out = <LlmEvent>[];
  for (final chunk in chunks) {
    out.addAll(parser.add(chunk));
  }
  out.addAll(parser.flush());
  return [
    for (final e in out)
      switch (e) {
        LlmReasoningDelta(:final text) => ('reasoning', text),
        LlmTextDelta(:final text) => ('text', text),
        _ => ('other', ''),
      },
  ];
}

void main() {
  test('plain text passes through unchanged', () {
    expect(_run(['Привет, ', 'мир']), [('text', 'Привет, '), ('text', 'мир')]);
  });

  test('a think block is split out as reasoning, the rest stays text', () {
    expect(_run(['<think>План</think>Ответ']), [
      ('reasoning', 'План'),
      ('text', 'Ответ'),
    ]);
  });

  test('tags split across chunks do not leak into the text', () {
    expect(_run(['До <thi', 'nk>мысль</th', 'ink> после']), [
      ('text', 'До '),
      ('reasoning', 'мысль'),
      ('text', ' после'),
    ]);
  });

  test('a partial tag that never completes is flushed as text', () {
    expect(_run(['Счёт <', 'b>']), [('text', 'Счёт '), ('text', '<b>')]);
  });

  test('unfinished reasoning at the end is flushed as reasoning', () {
    expect(_run(['<think>ещё думаю']), [('reasoning', 'ещё думаю')]);
  });
}

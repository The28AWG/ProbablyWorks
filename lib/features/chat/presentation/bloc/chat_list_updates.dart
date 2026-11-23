import 'package:pw_agent/agent/domain/chat_models.dart';

/// Точечные обновления списков состояния чата без перечитывания БД.
///
/// Функции чистые: не зависят от состояния [ChatBloc], поэтому их можно
/// проверить без хаба. Порядок элементов должен совпадать с тем, что даёт
/// перезагрузка чата, иначе лента после события и после перезагрузки
/// расходится.

/// Добавляет сообщение в список. Уже известный `id` не дублируется и не
/// заменяется: события о записи приходят один раз. Порядок — по seq, потому что
/// сообщение при возобновлении шага может прийти позже уже записанных.
List<ChatMessage> withMessage(List<ChatMessage> messages, ChatMessage message) {
  if (messages.any((m) => m.id == message.id)) return messages;
  if (messages.isEmpty || message.seq > messages.last.seq) {
    return [...messages, message];
  }
  return [...messages, message]..sort((a, b) => a.seq.compareTo(b.seq));
}

/// Обновляет один запуск в списке, не читая все запуски чата.
///
/// Список сортируется по `startedAt`, как и перезагрузка: событие о запуске
/// может прийти позже соседнего, и без сортировки лента шагов показывала бы
/// другой порядок.
List<ToolRun> withRun(List<ToolRun> runs, ToolRun run) {
  final next = List<ToolRun>.of(runs);
  final index = next.indexWhere((r) => r.id == run.id);
  if (index < 0) {
    next.add(run);
  } else {
    next[index] = run;
  }
  next.sort((a, b) => a.startedAt.compareTo(b.startedAt));
  return next;
}

/// Живой вывод остаётся только у активных запусков. [changed] — запуск, который
/// только что обновился: его активность берётся из нового состояния, остальных —
/// из прежнего списка [runs].
Map<String, String> liveWithRuns(
  Map<String, String> live,
  List<ToolRun> runs,
  ToolRun changed,
) {
  final active = {
    for (final run in runs)
      if (run.isActive) run.id,
  };
  if (changed.isActive) {
    active.add(changed.id);
  } else {
    active.remove(changed.id);
  }
  return {
    for (final entry in live.entries)
      if (active.contains(entry.key)) entry.key: entry.value,
  };
}

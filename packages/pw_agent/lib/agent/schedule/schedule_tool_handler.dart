import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/schedule/scheduled_task.dart';
import 'package:pw_agent/agent/schedule/scheduled_task_repository.dart';
import 'package:pw_agent/agent/tools/tool_args.dart';
import 'package:pw_agent/agent/tools/tool_catalog.dart';
import 'package:pw_agent/agent/tools/tool_types.dart';
import 'package:pw_agent/core/util/char_substring.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';

/// Инструменты расписания: создание, список и отмена отложенных задач чата.
///
/// Сам запуск задачу не выполняет: её подхватит планировщик (демон или
/// платформенный запускатель). Поэтому обработчику не нужен [AgentHub] и не
/// возникает циклическая зависимость из исполнителя инструментов.
class ScheduleToolHandler {
  ScheduleToolHandler(this._tasks);

  final ScheduledTaskRepository _tasks;

  /// Выполняет инструмент расписания. Ошибки аргументов остаются исключениями
  /// и обрабатываются `ToolExecutor`.
  Future<ToolResult> call(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
  ) async {
    // Субагент работает в скрытом чате: напоминание сработало бы там, где
    // пользователь его не увидит, а отменить его он не сможет. О задаче
    // субагент сообщает родителю в отчёте.
    if (ctx.chat.kind != ChatKind.main) {
      return const ToolResult(
        'scheduled tasks are available only in a user chat; '
        'mention the reminder in your report instead',
        isError: true,
      );
    }
    switch (call.name) {
      case ToolNames.scheduleTask:
        return _schedule(ctx, args);
      case ToolNames.listScheduledTasks:
        return _list(ctx);
      case ToolNames.cancelScheduledTask:
        return _cancel(ctx, args);
    }
    return ToolResult('unknown schedule tool: ${call.name}', isError: true);
  }

  /// Заголовок шага журнала для инструментов, которые меняют очередь задач.
  ///
  /// Создание и отмена должны быть видны в чате: иначе пользователю остаётся
  /// только верить тексту ответа модели. Чтение списка шага не создаёт — это
  /// такая же справка, как поиск по истории. null — шаг показывать не нужно.
  String? summaryFor(LlmToolCall call, Map<String, dynamic> args) =>
      switch (call.name) {
        ToolNames.scheduleTask => _scheduleSummary(args),
        ToolNames.cancelScheduledTask => _cancelSummary(args),
        _ => null,
      };

  /// `schedule in 10m · remind me about the deploy`, `schedule 2026-11-20 18:00 · …`.
  ///
  /// Время стоит перед текстом задачи: на узкой карточке заголовок обрезается
  /// справа, и главное — когда сработает — должно остаться видимым.
  String _scheduleSummary(Map<String, dynamic> args) {
    final when = _whenLabel(args);
    final head = when.isEmpty ? 'schedule' : 'schedule $when';
    final prompt = args['prompt'];
    if (prompt is String && prompt.trim().isEmpty) return head;
    if (prompt is! String) return head;
    return '$head · ${previewToolText(prompt, max: 80)}';
  }

  /// `cancel task 29208bfb`: полный id есть в теле шага.
  String _cancelSummary(Map<String, dynamic> args) {
    final id = args['id'];
    return id is String && id.isNotEmpty
        ? 'cancel task ${charPrefix(id, 8)}'
        : 'cancel task';
  }

  /// Время запуска для заголовка. Аргументы уже проверены вызовом, но разбор
  /// здесь намеренно мягкий: заголовок не должен падать из-за формата.
  String _whenLabel(Map<String, dynamic> args) {
    final raw = args['due_at'];
    if (raw is String) {
      final parsed = DateTime.tryParse(raw.trim());
      if (parsed != null) return _localLabel(parsed.toLocal());
    }
    final delay = args['delay_seconds'];
    if (delay is num) return 'in ${_durationLabel(delay.toInt())}';
    return '';
  }

  /// `2026-11-20 18:00` в местном времени.
  String _localLabel(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }

  /// Компактная задержка: `45s`, `10m`, `1m 30s`, `2h`, `3d`.
  String _durationLabel(int seconds) {
    const units = [(86400, 'd'), (3600, 'h'), (60, 'm'), (1, 's')];
    final parts = <String>[];
    var rest = seconds;
    for (final (size, suffix) in units) {
      final value = rest ~/ size;
      if (value == 0) continue;
      parts.add('$value$suffix');
      rest -= value * size;
      if (parts.length == 2) break;
    }
    return parts.join(' ');
  }

  Future<ToolResult> _schedule(
    ToolContext ctx,
    Map<String, dynamic> args,
  ) async {
    final prompt = toolStringArg(args, 'prompt');
    final dueAt = _dueAt(args);
    final task = await _tasks.create(
      chatId: ctx.chat.id,
      prompt: prompt,
      dueAt: dueAt,
    );
    // Время без долей секунды: эта строка видна пользователю в теле шага.
    return ToolResult(
      'scheduled task ${task.id} at ${_localLabel(task.dueAt.toLocal())}',
    );
  }

  Future<ToolResult> _list(ToolContext ctx) async {
    final tasks = await _tasks.forChat(ctx.chat.id);
    if (tasks.isEmpty) return const ToolResult('no scheduled tasks');
    return ToolResult([for (final task in tasks) _line(task)].join('\n'));
  }

  String _line(ScheduledTask task) {
    final due = task.dueAt.toLocal().toIso8601String();
    final preview = previewToolText(task.prompt, max: 120);
    return '${task.id} | ${task.status.name} | $due | $preview';
  }

  Future<ToolResult> _cancel(ToolContext ctx, Map<String, dynamic> args) async {
    final id = toolStringArg(args, 'id');
    final task = await _tasks.byId(id);
    // Отменять можно только задачи этого чата: чужой id неотличим от несуществующего.
    if (task == null || task.chatId != ctx.chat.id) {
      return const ToolResult(
        'scheduled task not found in this chat',
        isError: true,
      );
    }
    if (task.status != ScheduledTaskStatus.pending) {
      return ToolResult(
        'task ${task.id} is ${task.status.name}',
        isError: true,
      );
    }
    await _tasks.cancel(id);
    return ToolResult('cancelled ${task.id}');
  }

  /// Время запуска: абсолютное `due_at` или относительная задержка.
  /// Хотя бы одно поле обязательно, иначе запуск станет мгновенным.
  DateTime _dueAt(Map<String, dynamic> args) {
    final raw = args['due_at'];
    if (raw is String && raw.trim().isNotEmpty) {
      final parsed = DateTime.tryParse(raw.trim());
      if (parsed == null) {
        throw ArgumentError.value(raw, 'due_at', 'ISO-8601 expected');
      }
      return parsed.toUtc();
    }
    final delay = args['delay_seconds'];
    if (delay is num) {
      final seconds = delay.toInt();
      if (seconds < 1) {
        throw ArgumentError.value(delay, 'delay_seconds', 'must be at least 1');
      }
      return DateTime.now().toUtc().add(Duration(seconds: seconds));
    }
    throw ArgumentError('either due_at or delay_seconds is required');
  }
}

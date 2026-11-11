import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/project.dart';
import 'package:pw_agent/agent/exec/command_executor.dart';
import 'package:pw_agent/agent/policy/policy_engine.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/host/host_runtime.dart';

/// Контекст одного запуска инструмента: чат, Host с рантаймом и политика.
class ToolContext {
  const ToolContext({
    required this.chat,
    required this.messageId,
    required this.host,
    required this.runtime,
    required this.limits,
    required this.policy,
    required this.onBackgroundDone,
    this.project,
    this.turnUserMessageId,
  });

  final Chat chat;
  final String messageId;

  /// Пользовательское сообщение, открывшее ход (для журнала изменений).
  final String? turnUserMessageId;
  final Host host;
  final HostRuntime runtime;
  final AppLimits limits;
  final PolicyEngine policy;

  /// Проект чата: нужен для доверия skills и общей памяти. Null только у чата без проекта.
  final Project? project;

  /// Вызывается, когда фоновая команда завершилась (после записи ToolRun).
  final void Function(ToolRun run, ExecOutcome outcome) onBackgroundDone;
}

/// Результат выполнения инструмента.
class ToolResult {
  const ToolResult(
    this.text, {
    this.isError = false,
    this.finish = false,
    this.whenSettled,
  });

  /// Текст для модели (role tool).
  final String text;
  final bool isError;

  /// `finish` завершает ход агента.
  final bool finish;

  /// Когда побочный эффект станет виден следующим вызовам. Пусто — эффект
  /// уже виден в момент возврата. Фоновая команда отдаёт текст «запущено»
  /// сразу, а это будущее завершается вместе с процессом.
  final Future<void>? whenSettled;
}

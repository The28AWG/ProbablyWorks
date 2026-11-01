import 'package:injectable/injectable.dart';
import 'package:probably_works/core/util/async_semaphore.dart';
import 'package:probably_works/host/host_runtime.dart';

/// Один запущенный процесс команды, известный агенту.
class ActiveExec {
  ActiveExec({
    required this.toolCallId,
    required this.chatId,
    required this.hostId,
    required this.runtime,
    required this.command,
    required this.background,
    required this.startedAt,
  });

  final String toolCallId;
  final String chatId;
  final String hostId;
  final HostRuntime runtime;
  final String command;
  final bool background;
  final DateTime startedAt;

  /// Заполняется после ExecStarted (pid группы процесса на Host).
  int? pid;

  /// Остановка запрошена пользователем или политикой (нужен статус interrupted, а не failed).
  bool stopRequested = false;
}

/// Реестр запущенных команд и лимит параллельности на Host.
/// Остановка — это kill-команда на Host (см. ProcessControl), без отдельного API в рантайме.
@singleton
class ActiveExecRegistry {
  final Map<String, ActiveExec> _execs = {};
  final Map<String, AsyncSemaphore> _semaphores = {};

  /// Ожидание слота на Host. Возвращает функцию освобождения слота.
  Future<void Function()> acquireSlot(String hostId, int maxParallel) async {
    final semaphore = _semaphores.putIfAbsent(
      hostId,
      () => AsyncSemaphore(maxParallel),
    );
    await semaphore.acquire();
    return semaphore.release;
  }

  void register(ActiveExec exec) => _execs[exec.toolCallId] = exec;

  void unregister(String toolCallId) => _execs.remove(toolCallId);

  ActiveExec? find(String toolCallId) => _execs[toolCallId];

  List<ActiveExec> forChat(String chatId) => [
    for (final exec in _execs.values)
      if (exec.chatId == chatId) exec,
  ];

  int get activeCount => _execs.length;

  /// Мягкая остановка (TERM), при [force] — немедленная (KILL).
  Future<void> stop(ActiveExec exec, {required bool force}) async {
    exec.stopRequested = true;
    final pid = exec.pid;
    if (pid == null) return;
    await exec.runtime.killProcess(pid, force: force);
  }

  /// Останавливает все процессы чата (Stop). Очередь промптов от этого не меняется.
  Future<void> stopChat(String chatId, {bool force = false}) async {
    for (final exec in forChat(chatId)) {
      await stop(exec, force: force);
    }
  }
}

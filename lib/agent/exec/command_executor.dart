import 'dart:async';
import 'dart:typed_data';

import 'package:injectable/injectable.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/exec/active_exec_registry.dart';
import 'package:probably_works/agent/exec/exec_log_store.dart';
import 'package:probably_works/agent/exec/live_output_bus.dart';
import 'package:probably_works/core/config/app_limits.dart';
import 'package:probably_works/core/error/app_failure.dart';
import 'package:probably_works/core/util/redactor.dart';
import 'package:probably_works/core/util/utf8_chunk_decoder.dart';
import 'package:probably_works/host/host_op.dart';
import 'package:probably_works/host/host_runtime.dart';
import 'package:probably_works/host/host_terminal.dart';

/// Итог запуска команды. Текст уже ограничен лимитом БД (голова+хвост).
class ExecOutcome {
  const ExecOutcome({
    required this.status,
    this.exitCode,
    this.pid,
    this.outputText = '',
    this.outputTruncated = false,
    this.message,
    this.logPath,
  });

  final ToolRunStatus status;
  final int? exitCode;
  final int? pid;
  final String outputText;
  final bool outputTruncated;
  final String? message;

  /// Путь к логу; после компакции файл удалён и поле пустое.
  final String? logPath;
}

/// Ручка запуска: [started] завершится, когда процесс получил pid (или сразу с null при сбое спавна),
/// [finished] — когда команда окончательно завершилась.
class ExecHandle {
  const ExecHandle({
    required this.toolCallId,
    required this.logPath,
    required this.started,
    required this.finished,
  });

  final String toolCallId;
  final String logPath;
  final Future<int?> started;
  final Future<ExecOutcome> finished;
}

/// Исполняет команду через HostRuntime: лог-файл, живой вывод, таймауты, компакция в БД.
/// С [CommandExecutor.start] `inTerminal` команда запускается в PTY-терминале Host.
/// Не пишет в БД сам — результат возвращается вызывающему (ToolExecutor).
@lazySingleton
class CommandExecutor {
  CommandExecutor(this._logs, this._registry, this._bus);

  final ExecLogStore _logs;
  final ActiveExecRegistry _registry;
  final LiveOutputBus _bus;

  Future<ExecHandle> start({
    required String chatId,
    required String hostId,
    required String toolCallId,
    required HostRuntime runtime,
    required String command,
    String? displayCommand,
    required AppLimits limits,
    required bool background,
    String? cwd,
    bool inTerminal = false,
    Uint8List? stdin,
    Duration? timeout,
    HostOp? op,
  }) async {
    final release = await _registry.acquireSlot(
      hostId,
      limits.maxParallelExecPerHost,
    );
    final exec = ActiveExec(
      toolCallId: toolCallId,
      chatId: chatId,
      hostId: hostId,
      runtime: runtime,
      command: displayCommand ?? command,
      background: background,
      startedAt: DateTime.now(),
    );
    _registry.register(exec);
    final logPath = await _logs.open(chatId, toolCallId);
    final Stream<ExecEvent> events;
    if (op != null) {
      events = runtime.perform(op, cwd: cwd, stdin: stdin);
    } else if (inTerminal && runtime.hasTerminal) {
      // Без терминала (виртуальный Host) команда идёт обычным run: терминала у неё нет.
      events = await _terminalEvents(exec, runtime, command, cwd);
    } else {
      events = runtime.run(command, cwd: cwd, stdin: stdin);
    }

    final started = Completer<int?>();
    final finished = Completer<ExecOutcome>();
    final outDecoder = Utf8ChunkDecoder();
    final errDecoder = Utf8ChunkDecoder();
    var finalized = false;

    final limit =
        timeout ??
        (background
            ? limits.backgroundMaxRuntime
            : limits.foregroundExecTimeout);
    Timer? watchdog;
    var timedOut = false;

    Future<void> finalize({ExecDone? done, Object? error}) async {
      if (finalized) return;
      finalized = true;
      watchdog?.cancel();
      _emit(toolCallId, chatId, outDecoder.close() + errDecoder.close());
      await _logs.closeSink(toolCallId);
      final compacted = await _logs.compactToDb(
        logPath,
        maxBytes: limits.logOutputDbBytes,
      );
      _registry.unregister(toolCallId);
      release();
      if (!started.isCompleted) started.complete(null);
      finished.complete(
        _outcome(
          done: done,
          error: error,
          timedOut: timedOut,
          stopRequested: exec.stopRequested,
          pid: exec.pid,
          compacted: compacted,
        ),
      );
    }

    events.listen(
      (event) {
        switch (event) {
          case ExecStarted e:
            exec.pid = e.pid;
            if (exec.stopRequested) {
              unawaited(_registry.stop(exec, force: true));
            }
            if (!started.isCompleted) started.complete(e.pid);
          case ExecStdout e:
            _emit(toolCallId, chatId, outDecoder.add(e.bytes));
          case ExecStderr e:
            _emit(toolCallId, chatId, errDecoder.add(e.bytes));
          case ExecDone e:
            unawaited(finalize(done: e));
        }
      },
      onError: (Object error) => unawaited(finalize(error: error)),
      onDone: () => unawaited(finalize()),
    );

    watchdog = Timer(limit, () {
      timedOut = true;
      unawaited(_registry.stop(exec, force: false));
      Timer(limits.killGrace, () {
        if (!finalized) unawaited(_registry.stop(exec, force: true));
      });
    });

    return ExecHandle(
      toolCallId: toolCallId,
      logPath: logPath,
      started: started.future,
      finished: finished.future,
    );
  }

  /// Останавливает запуск по id. false — запуск уже завершён или неизвестен.
  /// Остановка идёт через реестр, поэтому результат придёт обычным `ExecOutcome`.
  Future<bool> stopRun(String runId, {bool force = false}) async {
    final exec = _registry.find(runId);
    if (exec == null) return false;
    await _registry.stop(exec, force: force);
    return true;
  }

  /// Открывает PTY и отдаёт его события. Ошибка открытия становится итогом запуска, а не исключением.
  Future<Stream<ExecEvent>> _terminalEvents(
    ActiveExec exec,
    HostRuntime runtime,
    String command,
    String? cwd,
  ) async {
    try {
      final terminal = await runtime.openTerminal(command, cwd: cwd);
      exec.terminal = terminal;
      // Остановка могла быть запрошена, пока PTY открывался.
      if (exec.stopRequested) unawaited(_registry.stop(exec, force: true));
      return execEventsOf(terminal);
    } on HostFailure catch (error) {
      return Stream.value(ExecDone(spawnFailed: true, message: error.message));
    }
  }

  void _emit(String toolCallId, String chatId, String text) {
    if (text.isEmpty) return;
    // В лог и в живой вывод уходит одна и та же маскированная версия. Иначе
    // секрет, напечатанный командой, был бы скрыт в БД, но виден на экране.
    final safe = Redactor.redact(text);
    _logs.append(toolCallId, safe);
    _bus.publish(toolCallId, chatId, safe);
  }

  ExecOutcome _outcome({
    required ExecDone? done,
    required Object? error,
    required bool timedOut,
    required bool stopRequested,
    required int? pid,
    required ({String text, bool truncated}) compacted,
  }) {
    final ToolRunStatus status;
    String? message;
    if (error != null) {
      status = ToolRunStatus.failed;
      message = error.toString();
    } else if (done == null) {
      status = ToolRunStatus.failed;
      message = 'stream closed without ExecDone';
    } else if (done.spawnFailed) {
      status = ToolRunStatus.spawnFailed;
      message = done.message;
    } else if (done.connectionLost) {
      status = ToolRunStatus.connectionLost;
      message = done.message;
    } else if (timedOut) {
      status = ToolRunStatus.timedOut;
    } else if (stopRequested) {
      status = ToolRunStatus.interrupted;
    } else if (done.exitCode == 0) {
      status = ToolRunStatus.done;
    } else {
      status = ToolRunStatus.failed;
      message = done.message;
    }
    return ExecOutcome(
      status: status,
      exitCode: done?.exitCode,
      pid: pid,
      outputText: compacted.text,
      outputTruncated: compacted.truncated,
      message: message,
    );
  }
}

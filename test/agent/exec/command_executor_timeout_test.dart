import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/exec/active_exec_registry.dart';
import 'package:pw_agent/agent/exec/command_executor.dart';
import 'package:pw_agent/agent/exec/exec_log_store.dart';
import 'package:pw_agent/agent/exec/live_output_bus.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/host/host_op.dart';
import 'package:pw_agent/host/host_runtime.dart';
import 'package:pw_agent/host/host_terminal.dart';

/// Host без процесса и PTY, как виртуальный: поток команды висит, пока его
/// не отменит подписка.
/// Host, который сразу сообщает код выхода: проверяет границу между
/// завершённым вызовом и ошибкой результата.
final class _ExitRuntime implements HostRuntime {
  const _ExitRuntime(this.exitCode);

  final int exitCode;

  @override
  HostOs get os => HostOs.posix;

  @override
  bool get hasTerminal => false;

  @override
  Stream<ExecEvent> perform(HostOp op, {String? cwd, Uint8List? stdin}) =>
      const Stream<ExecEvent>.empty();

  @override
  Stream<ExecEvent> run(String command, {String? cwd, Uint8List? stdin}) =>
      Stream.value(ExecDone(exitCode: exitCode));

  @override
  Future<HostTerminal> openTerminal(
    String command, {
    String? cwd,
    int columns = defaultTerminalColumns,
    int rows = defaultTerminalRows,
  }) => Future.error(const HostFailure('no terminal'));
}

final class _HangingRuntime implements HostRuntime {
  var canceled = false;

  @override
  HostOs get os => HostOs.posix;

  @override
  bool get hasTerminal => false;

  @override
  Stream<ExecEvent> perform(HostOp op, {String? cwd, Uint8List? stdin}) =>
      const Stream<ExecEvent>.empty();

  @override
  Stream<ExecEvent> run(String command, {String? cwd, Uint8List? stdin}) {
    final controller = StreamController<ExecEvent>(
      onCancel: () {
        canceled = true;
      },
    );
    return controller.stream;
  }

  @override
  Future<HostTerminal> openTerminal(
    String command, {
    String? cwd,
    int columns = defaultTerminalColumns,
    int rows = defaultTerminalRows,
  }) => Future.error(const HostFailure('no terminal'));
}

void main() {
  late Directory root;
  late CommandExecutor commands;

  setUp(() {
    root = Directory.systemTemp.createTempSync('pw_exec_timeout_');
    commands = CommandExecutor(
      ExecLogStore(root),
      ActiveExecRegistry(),
      LiveOutputBus(),
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<ExecHandle> start(HostRuntime runtime, {Duration? timeout}) =>
      commands.start(
        chatId: 'chat',
        hostId: 'virtual',
        toolCallId: 'run',
        runtime: runtime,
        command: 'while true; do :; done',
        limits: AppLimits.defaults,
        background: false,
        timeout: timeout,
      );

  test('a zero exit code completes the call without a result error', () async {
    final handle = await start(const _ExitRuntime(0));

    final outcome = await handle.finished.timeout(const Duration(seconds: 2));

    expect(outcome.status, ToolRunStatus.done);
    expect(outcome.resultError, isFalse);
    expect(outcome.exitCode, 0);
  });

  test('a non-zero exit code is a result error, not a call failure', () async {
    final handle = await start(const _ExitRuntime(3));

    final outcome = await handle.finished.timeout(const Duration(seconds: 2));

    expect(outcome.status, ToolRunStatus.done);
    expect(outcome.resultError, isTrue);
    expect(outcome.exitCode, 3);
  });

  test('timeout cancels a Host without pid and PTY', () async {
    final runtime = _HangingRuntime();
    final handle = await start(
      runtime,
      timeout: const Duration(milliseconds: 30),
    );

    final outcome = await handle.finished.timeout(const Duration(seconds: 2));

    expect(outcome.status, ToolRunStatus.timedOut);
    expect(runtime.canceled, isTrue);
  });

  test('stopRun cancels a Host without pid and PTY', () async {
    final runtime = _HangingRuntime();
    final handle = await start(runtime);

    expect(await commands.stopRun('run', force: true), isTrue);
    final outcome = await handle.finished.timeout(const Duration(seconds: 2));

    expect(outcome.status, ToolRunStatus.interrupted);
    expect(runtime.canceled, isTrue);
  });
}

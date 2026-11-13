import 'dart:io';
import 'dart:typed_data';

import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/host/host_environment.dart';
import 'package:pw_agent/host/host_terminal.dart';
import 'package:pw_agent/host/portable_pty_launcher.dart';
import 'package:pw_agent/host/pty_launcher.dart';
import 'package:pw_agent/host/wrapped_exec_runtime.dart';

/// Исполнение на локальной машине: `Process.start` через оболочку ОС.
final class LocalHostRuntime extends WrappedExecRuntime {
  LocalHostRuntime({
    required HostOs os,
    String? shell,
    this.environment = const {},
    this.pty = const PortablePtyLauncher(),
  }) : super(os, shell: shell);

  /// Создание PTY для команд терминала (см. [openTerminal]).
  final PtyLauncher pty;

  /// Карта хоста. Накладывается на окружение машины и в обычном процессе, и в PTY.
  final Map<String, String> environment;

  /// На Windows локальный PTY не поддерживается: `portable_pty` использует
  /// ConPTY, но не отдаёт master fd, а блокирующее чтение нельзя опрашивать
  /// таймером. Команды идут обычным `Process` без TTY — это ограничение
  /// лучше, чем зависший или упавший терминал.
  @override
  bool get hasTerminal => os != HostOs.windows;

  @override
  Future<PtyChannel> spawnPty(
    String wrappedScript, {
    required int columns,
    required int rows,
  }) {
    if (os == HostOs.windows) {
      return Future<PtyChannel>.error(
        const HostFailure(
          'Local terminal is not available on Windows: '
          'commands run without a TTY',
          kind: HostFailureKind.spawnFailed,
        ),
      );
    }
    return pty.start(
      control.shellExecutable,
      control.shellArgs(wrappedScript),
      environment: localSessionEnvironment(
        machine: Platform.environment,
        host: environment,
        terminal: true,
      ),
      columns: columns,
      rows: rows,
    );
  }

  @override
  Future<ExecChannel> spawn(String wrappedScript) async {
    try {
      final process = await Process.start(
        control.shellExecutable,
        control.shellArgs(wrappedScript),
        mode: ProcessStartMode.normal,
        environment: localSessionEnvironment(
          machine: Platform.environment,
          host: environment,
        ),
      );
      return _ProcessChannel(process);
    } on ProcessException catch (error, stack) {
      Error.throwWithStackTrace(
        HostFailure(error.message, kind: HostFailureKind.spawnFailed),
        stack,
      );
    }
  }
}

class _ProcessChannel implements ExecChannel {
  _ProcessChannel(this._process);

  final Process _process;

  @override
  Stream<Uint8List> get stdout => _process.stdout.map(Uint8List.fromList);

  @override
  Stream<Uint8List> get stderr => _process.stderr.map(Uint8List.fromList);

  @override
  int? get knownPid => _process.pid;

  @override
  Future<void> finishStdin(Uint8List? data) async {
    try {
      if (data != null) _process.stdin.add(data);
      await _process.stdin.close();
    } on Object {
      // Процесс уже завершился: сбой виден по коду выхода.
    }
  }

  @override
  Future<int?> get exitCode => _process.exitCode;
}

/// Удобная фабрика для текущей ОС (тесты передают явный [HostOs]).

import 'dart:io';
import 'dart:typed_data';

import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/error/app_failure.dart';
import 'package:probably_works/host/flutter_pty_launcher.dart';
import 'package:probably_works/host/host_runtime.dart';
import 'package:probably_works/host/host_terminal.dart';
import 'package:probably_works/host/pty_launcher.dart';
import 'package:probably_works/host/wrapped_exec_runtime.dart';

/// Исполнение на локальной машине: `Process.start` через оболочку ОС.
final class LocalHostRuntime extends WrappedExecRuntime {
  LocalHostRuntime({
    required HostOs os,
    String? shell,
    this.pty = const FlutterPtyLauncher(),
  }) : super(os, shell: shell);

  /// Создание PTY для команд терминала (см. [openTerminal]).
  final PtyLauncher pty;

  @override
  Future<ExecChannel> spawn(String wrappedScript) async {
    try {
      final process = await Process.start(
        control.shellExecutable,
        control.shellArgs(wrappedScript),
        mode: ProcessStartMode.normal,
      );
      return _ProcessChannel(process);
    } on ProcessException catch (error, stack) {
      Error.throwWithStackTrace(
        HostFailure(error.message, kind: HostFailureKind.spawnFailed),
        stack,
      );
    }
  }

  @override
  Future<PtyChannel> spawnPty(
    String wrappedScript, {
    required int columns,
    required int rows,
  }) => pty.start(
    control.shellExecutable,
    control.shellArgs(wrappedScript),
    environment: {...Platform.environment, 'TERM': 'xterm-256color'},
    columns: columns,
    rows: rows,
  );
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
  void closeStdin() {
    _process.stdin.close().catchError((Object _) {
      return;
    });
  }

  @override
  Future<int?> get exitCode => _process.exitCode;
}

/// Удобная фабрика для текущей ОС (тесты передают явный [HostOs]).
HostRuntime localRuntimeForCurrentPlatform() {
  final os = Platform.isMacOS
      ? HostOs.macos
      : Platform.isWindows
      ? HostOs.windows
      : HostOs.posix;
  return LocalHostRuntime(os: os);
}

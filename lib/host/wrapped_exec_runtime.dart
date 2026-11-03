import 'dart:async';
import 'dart:typed_data';

import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/util/pid_marker_parser.dart';
import 'package:probably_works/host/host_runtime.dart';
import 'package:probably_works/host/host_terminal.dart';
import 'package:probably_works/host/process_control.dart';
import 'package:probably_works/host/shell_adapter.dart';

/// Канал одного запуска: локальный Process или SSH-сессия.
abstract interface class ExecChannel {
  Stream<Uint8List> get stdout;
  Stream<Uint8List> get stderr;

  /// Известен сразу только для локального процесса; для SSH берётся из маркера.
  int? get knownPid;

  /// Отправляет [data] (если есть) на stdin процесса и закрывает ввод (EOF).
  /// Ошибка записи не бросается: если процесс уже завершился, код выхода сообщит о сбое.
  Future<void> finishStdin(Uint8List? data);

  /// Завершение канала. Может бросить при обрыве соединения.
  Future<int?> get exitCode;
}

/// Общая логика `run`: обёртка команды, маркер pid, стрим событий.
/// Local и SSH отличаются только тем, как создать [ExecChannel].
abstract base class WrappedExecRuntime implements HostRuntime {
  WrappedExecRuntime(this.os, {String? shell})
    : control = ProcessControl(os, shell: shell);

  @override
  final HostOs os;

  final ProcessControl control;

  /// Создаёт канал для уже обёрнутой команды. Бросает [HostFailure] при сбое.
  Future<ExecChannel> spawn(String wrappedScript);

  /// Создаёт PTY для уже обёрнутой команды нужного размера. Бросает [HostFailure] при сбое.
  Future<PtyChannel> spawnPty(
    String wrappedScript, {
    required int columns,
    required int rows,
  });

  @override
  Stream<ExecEvent> run(String command, {String? cwd, Uint8List? stdin}) {
    final controller = StreamController<ExecEvent>();
    unawaited(_drive(controller, command, cwd, stdin));
    return controller.stream;
  }

  @override
  Future<HostTerminal> openTerminal(
    String command, {
    String? cwd,
    int columns = defaultTerminalColumns,
    int rows = defaultTerminalRows,
  }) async {
    final script = cwd == null
        ? command
        : '${ShellAdapter(os).cd(cwd)} && $command';
    final channel = await spawnPty(
      control.wrapTerminal(script),
      columns: columns,
      rows: rows,
    );
    return PtyHostTerminal(channel, markers: control.hasPidMarker);
  }

  Future<void> _drive(
    StreamController<ExecEvent> out,
    String command,
    String? cwd,
    Uint8List? stdin,
  ) async {
    final script = cwd == null
        ? command
        : '${ShellAdapter(os).cd(cwd)} && $command';
    final ExecChannel channel;
    try {
      channel = await spawn(control.wrap(script));
    } on Object catch (error) {
      out.add(ExecDone(spawnFailed: true, message: error.toString()));
      await out.close();
      return;
    }

    final parser = control.hasPidMarker ? PidMarkerParser() : null;
    var started = false;
    var connectionLost = false;

    void emitStarted(int pid) {
      if (started) return;
      started = true;
      out.add(ExecStarted(pid));
    }

    // Маркер приоритетнее: Process.pid может быть внешней оболочкой, а группа
    // команды (та, что нужна для kill) создаётся внутри setsid и видна только в маркере.
    final known = parser == null ? channel.knownPid : null;
    if (known != null) emitStarted(known);

    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();
    final stdoutSub = channel.stdout.listen(
      (chunk) {
        final bytes = parser == null ? chunk : parser.add(chunk);
        if (parser?.pid != null) emitStarted(parser!.pid!);
        if (bytes.isNotEmpty) out.add(ExecStdout(bytes));
      },
      onError: (Object _) {
        connectionLost = true;
        if (!stdoutDone.isCompleted) stdoutDone.complete();
      },
      onDone: () {
        if (!stdoutDone.isCompleted) stdoutDone.complete();
      },
    );
    final stderrSub = channel.stderr.listen(
      (chunk) => out.add(ExecStderr(chunk)),
      onError: (Object _) {
        connectionLost = true;
        if (!stderrDone.isCompleted) stderrDone.complete();
      },
      onDone: () {
        if (!stderrDone.isCompleted) stderrDone.complete();
      },
    );

    // stdin пишется только после подписок на stdout и stderr: иначе процесс, пишущий много
    // в вывод, заблокируется на записи, а мы — на отправке ввода.
    unawaited(channel.finishStdin(stdin));

    int? exitCode;
    try {
      exitCode = await channel.exitCode;
    } on Object {
      connectionLost = true;
    }
    await Future.wait([stdoutDone.future, stderrDone.future]);
    await stdoutSub.cancel();
    await stderrSub.cancel();

    final tail = parser?.flush() ?? Uint8List(0);
    if (tail.isNotEmpty) out.add(ExecStdout(tail));
    out.add(ExecDone(exitCode: exitCode, connectionLost: connectionLost));
    await out.close();
  }
}

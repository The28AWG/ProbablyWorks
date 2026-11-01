import 'dart:async';

import 'package:probably_works/core/error/app_failure.dart';
import 'package:probably_works/core/util/utf8_chunk_decoder.dart';
import 'package:probably_works/host/host_runtime.dart';

class CapturedRun {
  const CapturedRun({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.connectionLost = false,
  });

  final int? exitCode;
  final String stdout;
  final String stderr;
  final bool connectionLost;

  bool get ok => exitCode == 0;
}

/// Запуск короткой служебной команды (чтение файлов, mtime, skills) с полным захватом вывода.
/// Не для длинных задач: они идут через CommandExecutor с логом и таймаутами.
Future<CapturedRun> captureRun(
  HostRuntime runtime,
  String command, {
  String? cwd,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final out = StringBuffer();
  final err = StringBuffer();
  final outDecoder = Utf8ChunkDecoder();
  final errDecoder = Utf8ChunkDecoder();
  int? exitCode;
  var lost = false;
  final completer = Completer<void>();
  final sub = runtime
      .run(command, cwd: cwd)
      .listen(
        (event) {
          switch (event) {
            case ExecStarted():
              break;
            case ExecStdout e:
              out.write(outDecoder.add(e.bytes));
            case ExecStderr e:
              err.write(errDecoder.add(e.bytes));
            case ExecDone e:
              exitCode = e.exitCode;
              lost = e.connectionLost;
              out.write(outDecoder.close());
              err.write(errDecoder.close());
              if (!completer.isCompleted) completer.complete();
          }
        },
        onError: (Object error) {
          if (!completer.isCompleted) {
            completer.completeError(
              HostFailure(
                error.toString(),
                kind: HostFailureKind.connectionLost,
              ),
            );
          }
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
      );
  try {
    await completer.future.timeout(timeout);
  } on TimeoutException {
    await sub.cancel();
    return CapturedRun(
      exitCode: null,
      stdout: out.toString(),
      stderr: 'timed out',
      connectionLost: false,
    );
  } finally {
    await sub.cancel();
  }
  return CapturedRun(
    exitCode: exitCode,
    stdout: out.toString(),
    stderr: err.toString(),
    connectionLost: lost,
  );
}

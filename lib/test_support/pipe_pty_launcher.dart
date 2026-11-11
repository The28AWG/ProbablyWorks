import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:pw_agent/host/host_terminal.dart';
import 'package:pw_agent/host/pty_launcher.dart';

/// Замена PTY для тестов агента: команда запускается обычным процессом, stdout и stderr объединяются.
/// Нужна, потому что нативная библиотека PTY не загружается в `flutter test` вместе с агентом.
/// Настоящий TTY проверяют тесты в test/host/local_pty_runtime_test.dart.
class PipePtyLauncher implements PtyLauncher {
  const PipePtyLauncher();

  @override
  Future<PtyChannel> start(
    String executable,
    List<String> arguments, {
    required Map<String, String> environment,
    required int columns,
    required int rows,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      environment: environment,
    );
    return _PipeChannel(process);
  }
}

class _PipeChannel implements PtyChannel {
  _PipeChannel(this._process) {
    var open = 2;
    void pipe(Stream<List<int>> source) {
      source
          .map(Uint8List.fromList)
          .listen(
            _output.add,
            onDone: () {
              if (--open == 0) unawaited(_output.close());
            },
          );
    }

    pipe(_process.stdout);
    pipe(_process.stderr);
  }

  final Process _process;
  final _output = StreamController<Uint8List>();

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  int? get knownPid => null;

  @override
  void write(Uint8List data) => _process.stdin.add(data);

  @override
  void resize(int columns, int rows) {
    assert(columns >= 0 && rows >= 0);
  }

  @override
  Future<int?> get exitCode => _process.exitCode;
}

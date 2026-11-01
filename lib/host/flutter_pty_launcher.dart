import 'dart:typed_data';

import 'package:flutter_pty/flutter_pty.dart';
import 'package:injectable/injectable.dart';
import 'package:probably_works/core/error/app_failure.dart';
import 'package:probably_works/host/host_terminal.dart';
import 'package:probably_works/host/pty_launcher.dart';

/// PTY через нативный плагин flutter_pty: настоящий TTY на Linux, macOS (posix) и Windows (ConPTY).
@LazySingleton(as: PtyLauncher)
final class FlutterPtyLauncher implements PtyLauncher {
  const FlutterPtyLauncher();

  @override
  Future<PtyChannel> start(
    String executable,
    List<String> arguments, {
    required Map<String, String> environment,
    required int columns,
    required int rows,
  }) async {
    try {
      final pty = Pty.start(
        executable,
        arguments: arguments,
        environment: environment,
        columns: columns,
        rows: rows,
      );
      return _FlutterPtyChannel(pty);
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(
        HostFailure(error.toString(), kind: HostFailureKind.spawnFailed),
        stack,
      );
    }
  }
}

class _FlutterPtyChannel implements PtyChannel {
  _FlutterPtyChannel(this._pty);

  final Pty _pty;

  @override
  Stream<Uint8List> get output => _pty.output;

  @override
  int? get knownPid => _pty.pid;

  @override
  void write(Uint8List data) => _pty.write(data);

  @override
  void resize(int columns, int rows) => _pty.resize(rows, columns);

  @override
  Future<int?> get exitCode => _pty.exitCode;
}

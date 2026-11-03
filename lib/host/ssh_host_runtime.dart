import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/error/app_failure.dart';
import 'package:probably_works/host/host_terminal.dart';
import 'package:probably_works/host/ssh_connection_pool.dart';
import 'package:probably_works/host/wrapped_exec_runtime.dart';

/// Исполнение на удалённом Host через SSH: каждая команда — отдельный session channel
/// поверх общего SSHClient из пула.
final class SshHostRuntime extends WrappedExecRuntime {
  SshHostRuntime({required this.host, required this._pool})
    : super(host.os, shell: host.shellOverride);

  final Host host;
  final SshConnectionPool _pool;

  @override
  Future<ExecChannel> spawn(String wrappedScript) async {
    final client = await _client();
    _pool.acquire(host.id);
    try {
      final session = await client.execute(wrappedScript);
      return _SshChannel(session, () => _pool.release(host.id));
    } on Object catch (error, stack) {
      _pool.release(host.id);
      Error.throwWithStackTrace(
        HostFailure(
          'SSH exec failed: $error',
          kind: HostFailureKind.connectionLost,
        ),
        stack,
      );
    }
  }

  @override
  Future<PtyChannel> spawnPty(
    String wrappedScript, {
    required int columns,
    required int rows,
  }) async {
    final client = await _client();
    _pool.acquire(host.id);
    try {
      final session = await client.execute(
        wrappedScript,
        pty: SSHPtyConfig(width: columns, height: rows),
      );
      return _SshPtyChannel(session, () => _pool.release(host.id));
    } on Object catch (error, stack) {
      _pool.release(host.id);
      Error.throwWithStackTrace(
        HostFailure(
          'SSH terminal failed: $error',
          kind: HostFailureKind.connectionLost,
        ),
        stack,
      );
    }
  }

  Future<SSHClient> _client() async {
    try {
      return await _pool.client(host);
    } on HostFailure {
      rethrow;
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(
        HostFailure(
          'SSH connection failed: $error',
          kind: HostFailureKind.connectionLost,
        ),
        stack,
      );
    }
  }
}

class _SshChannel implements ExecChannel {
  _SshChannel(this._session, this._onFinished);

  final SSHSession _session;
  final void Function() _onFinished;

  @override
  Stream<Uint8List> get stdout => _session.stdout;

  @override
  Stream<Uint8List> get stderr => _session.stderr;

  @override
  int? get knownPid => null;

  @override
  Future<void> finishStdin(Uint8List? data) async {
    try {
      if (data != null) _session.stdin.add(data);
      await _session.stdin.close();
    } on Object {
      // Сессия уже закрыта: сбой виден по коду выхода.
    }
  }

  @override
  Future<int?> get exitCode async {
    try {
      await _session.done;
      return _session.exitCode;
    } finally {
      _onFinished();
    }
  }
}

/// PTY-сессия: stdout и stderr объединяются в один поток, как в настоящем терминале.
class _SshPtyChannel implements PtyChannel {
  _SshPtyChannel(this._session, this._onFinished) {
    var open = 2;
    void pipe(Stream<Uint8List> source) {
      source.listen(
        _output.add,
        onDone: () {
          if (--open == 0) unawaited(_output.close());
        },
      );
    }

    pipe(_session.stdout);
    pipe(_session.stderr);
  }

  final SSHSession _session;
  final void Function() _onFinished;
  final _output = StreamController<Uint8List>();

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  int? get knownPid => null;

  @override
  void write(Uint8List data) => _session.stdin.add(data);

  @override
  void resize(int columns, int rows) => _session.resizeTerminal(columns, rows);

  @override
  Future<int?> get exitCode async {
    try {
      await _session.done;
      return _session.exitCode;
    } finally {
      _onFinished();
    }
  }
}

import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/error/app_failure.dart';
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
    final SSHClient client;
    try {
      client = await _pool.client(host);
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
  void closeStdin() {
    _session.stdin.close();
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

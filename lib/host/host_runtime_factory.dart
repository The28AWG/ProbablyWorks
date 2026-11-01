import 'package:injectable/injectable.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/host/host_runtime.dart';
import 'package:probably_works/host/local_host_runtime.dart';
import 'package:probably_works/host/pty_launcher.dart';
import 'package:probably_works/host/ssh_connection_pool.dart';
import 'package:probably_works/host/ssh_host_runtime.dart';

/// Создаёт рантайм под конкретный Host. Один Host — одна логическая точка исполнения.
@lazySingleton
class HostRuntimeFactory {
  HostRuntimeFactory(this._pool, this._pty);

  final SshConnectionPool _pool;
  final PtyLauncher _pty;

  HostRuntime forHost(Host host) {
    if (host.isLocal) {
      return LocalHostRuntime(
        os: host.os,
        shell: host.shellOverride,
        pty: _pty,
      );
    }
    return SshHostRuntime(host: host, pool: _pool);
  }
}

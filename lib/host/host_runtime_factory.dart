import 'package:injectable/injectable.dart';
import 'package:probably_works/core/data/virtual_host_provisioner.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/host/host_runtime.dart';
import 'package:probably_works/host/local_host_runtime.dart';
import 'package:probably_works/host/pty_launcher.dart';
import 'package:probably_works/host/ssh_connection_pool.dart';
import 'package:probably_works/host/ssh_host_runtime.dart';
import 'package:probably_works/host/virtual/shell/applets/standard_applets.dart';
import 'package:probably_works/host/virtual/virtual_host_profile.dart';
import 'package:probably_works/host/virtual/virtual_host_runtime.dart';

/// Создаёт рантайм под конкретный Host. Один Host — одна логическая точка исполнения.
/// Выбор по [HostKind] здесь единственный: остальной код работает с [HostRuntime] и не знает о типе хоста.
@lazySingleton
class HostRuntimeFactory {
  HostRuntimeFactory(this._pool, this._pty, this._virtual);

  final SshConnectionPool _pool;
  final PtyLauncher _pty;
  final VirtualHostProvisioner _virtual;

  HostRuntime forHost(Host host) => switch (host.kind) {
    HostKind.local => LocalHostRuntime(
      os: host.os,
      shell: host.shellOverride,
      pty: _pty,
    ),
    HostKind.ssh => SshHostRuntime(host: host, pool: _pool),
    HostKind.virtual => VirtualHostRuntime(
      fs: _virtual.fsOf(host.id),
      profile: virtualProfileFor(host),
      applets: standardApplets,
    ),
  };
}

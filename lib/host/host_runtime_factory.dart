import 'package:injectable/injectable.dart';
import 'package:probably_works/core/data/virtual_host_provisioner.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/host/host_runtime.dart';
import 'package:probably_works/host/local_host_runtime.dart';
import 'package:probably_works/host/pty_launcher.dart';
import 'package:probably_works/host/ssh_connection_pool.dart';
import 'package:probably_works/host/ssh_host_runtime.dart';
import 'package:probably_works/host/virtual/virtual_host_profile.dart';
import 'package:probably_works/host/virtual/virtual_host_runtime.dart';
import 'package:virtual_git/virtual_git.dart';
import 'package:virtual_host/virtual_host.dart';

/// Создаёт рантайм под конкретный Host. Один Host — одна логическая точка исполнения.
/// Выбор по [HostKind] здесь единственный: остальной код работает с [HostRuntime] и не знает о типе хоста.
@lazySingleton
class HostRuntimeFactory {
  HostRuntimeFactory(this._pool, this._pty, this._virtual);

  final SshConnectionPool _pool;
  final PtyLauncher _pty;
  final VirtualHostProvisioner _virtual;

  /// Стандартные апплеты плюс git. Имя `git` входит и в снимок `/bin`,
  /// иначе `which git` видит команду, а `test -x /bin/git` — нет.
  HostRuntime _virtualRuntime(Host host) {
    final profile = virtualProfileFor(host);
    final applets = AppletRegistry([
      for (final name in standardApplets.names) standardApplets.lookup(name)!,
      const GitApplet(),
    ]);
    return VirtualHostRuntime(
      fs: _virtual.fsOf(
        host.id,
        snapshot: OsSnapshot(profile: profile, names: applets.names),
      ),
      profile: profile,
      applets: applets,
    );
  }

  HostRuntime forHost(Host host) => switch (host.kind) {
    HostKind.local => LocalHostRuntime(
      os: host.os,
      shell: host.shellOverride,
      pty: _pty,
    ),
    HostKind.ssh => SshHostRuntime(host: host, pool: _pool),
    HostKind.virtual => _virtualRuntime(host),
  };
}

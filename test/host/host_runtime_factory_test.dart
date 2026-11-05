import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/data/host_repository.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/data/virtual_host_provisioner.dart';
import 'package:probably_works/core/db/app_database.dart';
import 'package:probably_works/core/db/db_connection.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/security/secret_store.dart';
import 'package:probably_works/host/host_runtime_factory.dart';
import 'package:probably_works/host/local_host_runtime.dart';
import 'package:probably_works/host/ssh_connection_pool.dart';
import 'package:probably_works/host/ssh_host_runtime.dart';
import 'package:probably_works/host/virtual/virtual_host_runtime.dart';
import 'package:probably_works/test_support/pipe_pty_launcher.dart';

Host _host(String id, HostKind kind) => Host(
  id: id,
  name: id,
  kind: kind,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

void main() {
  late AppDatabase db;
  late HostRuntimeFactory factory;

  setUp(() async {
    db = openInMemoryDatabase();
    final settings = SettingsRepository(db);
    await settings.preload();
    final secrets = MemorySecretStore();
    factory = HostRuntimeFactory(
      SshConnectionPool(
        HostRepository(db, secrets),
        secrets,
        settings,
        HostKeyConfirmations(),
      ),
      const PipePtyLauncher(),
      VirtualHostProvisioner(db),
    );
  });

  tearDown(() async {
    await db.close();
  });

  test('виртуальный Host получает VirtualHostRuntime без терминала', () {
    final runtime = factory.forHost(_host('sandbox', HostKind.virtual));

    expect(runtime, isA<VirtualHostRuntime>());
    expect(runtime.hasTerminal, isFalse);
  });

  test('SSH-хост получает SSH-рантайм с терминалом', () {
    final runtime = factory.forHost(_host('server', HostKind.ssh));

    expect(runtime, isA<SshHostRuntime>());
    expect(runtime.hasTerminal, isTrue);
  });

  test('локальный хост получает локальный рантайм с терминалом', () {
    final runtime = factory.forHost(_host('local', HostKind.local));

    expect(runtime, isA<LocalHostRuntime>());
    expect(runtime.hasTerminal, isTrue);
  });
}

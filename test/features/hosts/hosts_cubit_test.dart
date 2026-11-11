import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/features/hosts/presentation/bloc/hosts_cubit.dart';
import 'package:probably_works/test_support/pipe_pty_launcher.dart';
import 'package:pw_agent/agent/api/local_hosts_api.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/data/virtual_host_provisioner.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/host/host_diagnostics.dart';
import 'package:pw_agent/host/host_runtime_factory.dart';
import 'package:pw_agent/host/ssh_connection_pool.dart';
import 'package:virtual_host/virtual_host.dart';

Host _host(String id, HostKind kind) => Host(
  id: id,
  name: id,
  kind: kind,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

void main() {
  late AppDatabase db;
  late HostRepository hosts;
  late VirtualHostProvisioner provisioner;
  late HostsCubit cubit;

  setUp(() async {
    db = openInMemoryDatabase();
    final secrets = MemorySecretStore();
    hosts = HostRepository(db, secrets);
    final settings = SettingsRepository(db);
    await settings.preload();
    provisioner = VirtualHostProvisioner(db);
    final runtimes = HostRuntimeFactory(
      SshConnectionPool(hosts, secrets, settings, HostKeyConfirmations()),
      const PipePtyLauncher(),
      provisioner,
    );
    cubit = HostsCubit(
      LocalHostsApi(
        hosts,
        secrets,
        HostDiagnostics(hosts, secrets, settings, runtimes),
        provisioner,
      ),
    );
  });

  tearDown(() async {
    await cubit.close();
    await db.close();
  });

  test(
    'сохранение виртуального Host заполняет его домашний каталог и /tmp',
    () async {
      await cubit.save(_host('sandbox', HostKind.virtual));

      final fs = provisioner.fsOf('sandbox');
      expect((await fs.stat('/home/agent'))?.kind, VfsNodeKind.dir);
      expect((await fs.stat('/tmp'))?.kind, VfsNodeKind.dir);
    },
  );

  test('сохранение SSH-хоста ФС не создаёт', () async {
    await cubit.save(_host('server', HostKind.ssh));

    final fs = provisioner.fsOf('server');
    expect(await fs.stat('/home/agent'), isNull);
  });

  test(
    'повторное сохранение виртуального Host не теряет созданные файлы',
    () async {
      final host = _host('sandbox', HostKind.virtual);
      await cubit.save(host);
      final runtime = provisioner.fsOf(host.id);
      await runtime.writeBytes(
        '/home/agent/keep.txt',
        Uint8List.fromList([1, 2, 3]),
      );

      await cubit.save(host.copyWith(notes: 'новая заметка'));

      expect(await runtime.stat('/home/agent/keep.txt'), isNotNull);
    },
  );

  test('удаление виртуального Host удаляет его ФС вместе с записью', () async {
    await cubit.save(_host('sandbox', HostKind.virtual));

    await cubit.delete('sandbox');

    expect(await provisioner.fsOf('sandbox').stat('/home/agent'), isNull);
    expect(await hosts.byId('sandbox'), isNull);
  });
}

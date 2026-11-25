import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/features/hosts/presentation/bloc/hosts_cubit.dart';
import 'package:probably_works/test_support/pipe_pty_launcher.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/local_hosts_api.dart';
import 'package:pw_agent/agent/state/domain_change_bus.dart';
import 'package:pw_agent/agent/state/shared_state.dart';
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
  late DomainChangeBus changes;
  late LocalHostsApi api;
  late HostsCubit cubit;

  setUp(() async {
    db = openInMemoryDatabase();
    changes = DomainChangeBus();
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
    api = LocalHostsApi(
      hosts,
      secrets,
      HostDiagnostics(hosts, secrets, settings, runtimes),
      provisioner,
      changes,
    );
    cubit = HostsCubit(api);
  });

  tearDown(() async {
    await cubit.close();
    await changes.close();
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

      // Форма всегда строится из свежего снимка списка: ревизия защищает от
      // сохранения поверх изменений другого окна.
      final saved = (await hosts.byId(host.id))!;
      await cubit.save(saved.copyWith(notes: 'новая заметка'));

      expect(await runtime.stat('/home/agent/keep.txt'), isNotNull);
    },
  );

  test('сохранение и удаление публикуют общий ресурс хостов', () async {
    final events = <SharedResource>[];
    final sub = changes.changes.listen(events.add);
    addTearDown(sub.cancel);

    await cubit.save(_host('sandbox', HostKind.virtual));
    await cubit.delete('sandbox');
    await Future<void>.delayed(Duration.zero);

    expect(events, [SharedResource.hosts, SharedResource.hosts]);
  });

  test('сохранение без ревизии не проверяет её', () async {
    await api.saveHost(_host('server', HostKind.ssh));
    final first = (await hosts.byId('server'))!;
    expect(first.revision, 1);

    // Служебная запись и старый клиент не присылают ревизию: сохранение
    // проходит, а ревизия просто растёт.
    await api.saveHost(_host('server', HostKind.ssh).copyWith(notes: 'x'));

    expect((await hosts.byId('server'))!.revision, 2);
  });

  test('сохранение со старой ревизией отклоняется', () async {
    await cubit.save(_host('server', HostKind.ssh));
    final stale = (await hosts.byId('server'))!;
    await cubit.save(stale.copyWith(notes: 'первое окно'));
    final fresh = (await hosts.byId('server'))!;
    expect(fresh.revision, stale.revision + 1);

    await expectLater(
      cubit.save(stale.copyWith(notes: 'второе окно')),
      throwsA(
        isA<AgentApiException>().having(
          (error) => error.code,
          'code',
          'host_conflict',
        ),
      ),
    );
    expect((await hosts.byId('server'))!.notes, 'первое окно');
  });

  test('удаление виртуального Host удаляет его ФС вместе с записью', () async {
    await cubit.save(_host('sandbox', HostKind.virtual));

    await cubit.delete('sandbox');

    expect(await provisioner.fsOf('sandbox').stat('/home/agent'), isNull);
    expect(await hosts.byId('sandbox'), isNull);
  });
}

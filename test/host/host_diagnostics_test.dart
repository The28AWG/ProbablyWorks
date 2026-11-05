import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/data/host_repository.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/data/virtual_host_provisioner.dart';
import 'package:probably_works/core/db/app_database.dart';
import 'package:probably_works/core/db/db_connection.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/error/app_failure.dart';
import 'package:probably_works/core/security/secret_store.dart';
import 'package:probably_works/host/host_diagnostics.dart';
import 'package:probably_works/host/host_runtime_factory.dart';
import 'package:probably_works/host/ssh_connection_pool.dart';
import 'package:probably_works/test_support/pipe_pty_launcher.dart';

void main() {
  late AppDatabase db;
  late HostRepository hosts;
  late MemorySecretStore secrets;
  late HostDiagnostics diagnostics;

  setUp(() async {
    // flutter_test по умолчанию эмулирует Android, где ключи не читаются по пути.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    db = openInMemoryDatabase();
    hosts = HostRepository(db);
    final settings = SettingsRepository(db);
    await settings.preload();
    secrets = MemorySecretStore();
    final runtimes = HostRuntimeFactory(
      SshConnectionPool(hosts, secrets, settings, HostKeyConfirmations()),
      const PipePtyLauncher(),
      VirtualHostProvisioner(db),
    );
    diagnostics = HostDiagnostics(hosts, secrets, settings, runtimes);
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await db.close();
  });

  Host sshHost({
    String id = 'h1',
    String address = '127.0.0.1',
    int port = 1,
    SshAuthType authType = SshAuthType.key,
    String? keyPath,
  }) => Host(
    id: id,
    name: 'remote',
    kind: HostKind.ssh,
    createdAt: DateTime(2026, 11, 4),
    updatedAt: DateTime(2026, 11, 4),
    address: address,
    port: port,
    username: 'deploy',
    authType: authType,
    keyPath: keyPath,
  );

  test('every failure kind has a human readable description', () {
    for (final kind in HostFailureKind.values) {
      expect(describeHostFailure(kind), isNotEmpty, reason: kind.name);
    }
  });

  test('test() on a closed port stores the error in the host', () async {
    final host = sshHost();
    await hosts.save(host);

    final result = await diagnostics.test(host);

    expect(result.ok, isFalse);
    expect(result.error, isNotEmpty);
    final saved = (await hosts.byId(host.id))!;
    expect(saved.lastCheckError, result.error);
    expect(saved.lastCheckAt, isNotNull);
  });

  test(
    'diagnose() reports an empty address as a reachability failure',
    () async {
      final host = sshHost(address: '');
      await hosts.save(host);

      final steps = await diagnostics.diagnose(host);

      final reachability = steps.singleWhere((s) => s.name == 'reachability');
      expect(reachability.status, DiagnosticStatus.fail);
      expect(steps.last.name, 'connection');
      expect(steps.last.status, DiagnosticStatus.fail);
    },
  );

  test(
    'diagnose() reports a missing password as a credentials failure',
    () async {
      final host = sshHost(authType: SshAuthType.password);
      await hosts.save(host);

      final steps = await diagnostics.diagnose(host);

      final credentials = steps.singleWhere((s) => s.name == 'credentials');
      expect(credentials.status, DiagnosticStatus.fail);
      expect(credentials.message, contains('no password stored'));
    },
  );

  test(
    'diagnose() reports a key host without any key as a credentials failure',
    () async {
      final host = sshHost();
      await hosts.save(host);

      final steps = await diagnostics.diagnose(host);

      final credentials = steps.singleWhere((s) => s.name == 'credentials');
      expect(credentials.status, DiagnosticStatus.fail);
      expect(credentials.message, contains('no private key'));
    },
  );

  test('diagnose() reports a missing key file with its path', () async {
    final host = sshHost(keyPath: '/definitely/not/here/id_ed25519');
    await hosts.save(host);

    final steps = await diagnostics.diagnose(host);

    final credentials = steps.singleWhere((s) => s.name == 'credentials');
    expect(credentials.status, DiagnosticStatus.fail);
    expect(credentials.message, contains('/definitely/not/here/id_ed25519'));
  });

  test('diagnose() пропускает сеть виртуального Host, но проверяет его через host_info', () async {
    final host = Host(
      id: 'sandbox',
      name: 'Sandbox',
      kind: HostKind.virtual,
      createdAt: DateTime(2026, 11, 4),
      updatedAt: DateTime(2026, 11, 4),
    );
    await hosts.save(host);

    final steps = await diagnostics.diagnose(host);

    expect(
      steps.singleWhere((s) => s.name == 'reachability').status,
      DiagnosticStatus.skip,
    );
    expect(
      steps.singleWhere((s) => s.name == 'credentials').status,
      DiagnosticStatus.skip,
    );
    expect(
      steps.singleWhere((s) => s.name == 'host key').status,
      DiagnosticStatus.skip,
    );
    final saved = await hosts.byId('sandbox');
    expect(saved?.lastCheckAt, isNotNull);
    expect(saved?.lastCheckError, isNull);
  });
}

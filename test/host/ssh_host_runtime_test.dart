import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/data/host_repository.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/db/app_database.dart';
import 'package:probably_works/core/db/db_connection.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/security/secret_store.dart';
import 'package:probably_works/host/host_capture.dart';
import 'package:probably_works/host/host_runtime.dart';
import 'package:probably_works/host/host_terminal.dart';
import 'package:probably_works/host/ssh_connection_pool.dart';
import 'package:probably_works/host/ssh_host_runtime.dart';

/// Интеграционные тесты SSH-рантайма на реальном sshd.
///
/// Запуск (контейнер linuxserver/openssh-server, USER_NAME=pwtest, USER_PASSWORD=pwtest123):
///   PW_SSH_PORT=2222 flutter test test/host/ssh_host_runtime_test.dart
/// Без PW_SSH_PORT тесты пропускаются.
final _port = int.tryParse(Platform.environment['PW_SSH_PORT'] ?? '');
final _skip = _port == null
    ? 'set PW_SSH_PORT to run SSH integration tests'
    : null;

const _user = 'pwtest';
const _password = 'pwtest123';

void main() {
  late AppDatabase db;
  late HostRepository hosts;
  late SecretStore secrets;
  late HostKeyConfirmations confirmations;
  late SshConnectionPool pool;
  late Host host;

  setUp(() async {
    db = openInMemoryDatabase();
    hosts = HostRepository(db);
    secrets = MemorySecretStore();
    confirmations = HostKeyConfirmations();
    pool = SshConnectionPool(
      hosts,
      secrets,
      SettingsRepository(db),
      confirmations,
    );
    host = Host(
      id: 'ssh-test',
      name: 'ssh test',
      kind: HostKind.ssh,
      address: '127.0.0.1',
      port: _port ?? 22,
      username: _user,
      authType: SshAuthType.password,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    await hosts.save(host);
    await secrets.write(hostPasswordKey(host.id), _password);
  });

  tearDown(() async {
    await pool.close(host.id);
    await db.close();
  });

  Future<ExecDone> firstDone(HostRuntime runtime, String command) async {
    final event = await runtime
        .run(command)
        .firstWhere((event) => event is ExecDone);
    return event as ExecDone;
  }

  /// Автоматически отвечает на запросы подтверждения отпечатка.
  StreamSubscription<HostKeyRequest> autoAnswer({required bool trusted}) =>
      confirmations.requests.listen((request) {
        confirmations.resolve(request.id, trusted: trusted);
      });

  test(
    'runs a command over SSH and captures stdout and exit code',
    skip: _skip,
    () async {
      final sub = autoAnswer(trusted: true);
      addTearDown(sub.cancel);

      final runtime = SshHostRuntime(host: host, pool: pool);
      final result = await captureRun(runtime, 'echo hello-ssh && whoami');

      expect(result.ok, isTrue);
      expect(result.stdout, contains('hello-ssh'));
      expect(result.stdout, contains(_user));
      expect(result.exitCode, 0);
    },
  );

  test(
    'first connection stores the host key fingerprint and does not ask again',
    skip: _skip,
    () async {
      var asked = 0;
      final sub = confirmations.requests.listen((request) {
        asked++;
        confirmations.resolve(request.id, trusted: true);
      });
      addTearDown(sub.cancel);

      final runtime = SshHostRuntime(host: host, pool: pool);
      expect((await captureRun(runtime, 'true')).ok, isTrue);
      expect(asked, 1);

      final stored = await hosts.byId(host.id);
      expect(stored?.hostKeyFingerprint, isNotNull);

      await pool.close(host.id);
      expect(
        (await captureRun(
          SshHostRuntime(host: stored!, pool: pool),
          'true',
        )).ok,
        isTrue,
      );
      expect(asked, 1, reason: 'known fingerprint must not trigger a prompt');
    },
  );

  test(
    'rejected first-use host key blocks the connection',
    skip: _skip,
    () async {
      final sub = autoAnswer(trusted: false);
      addTearDown(sub.cancel);

      final done = await firstDone(
        SshHostRuntime(host: host, pool: pool),
        'true',
      );
      expect(done.spawnFailed, isTrue);
      expect(done.message, contains('Host key rejected by user'));
      expect((await hosts.byId(host.id))?.hostKeyFingerprint, isNull);
    },
  );

  test(
    'changed host key is blocked unless the user trusts it explicitly',
    skip: _skip,
    () async {
      final changed = host.copyWith(
        hostKeyFingerprint: 'SHA256:not-the-real-key',
      );
      await hosts.save(changed);

      final sub = autoAnswer(trusted: false);
      addTearDown(sub.cancel);

      final done = await firstDone(
        SshHostRuntime(host: changed, pool: pool),
        'true',
      );
      expect(done.spawnFailed, isTrue);
      expect(done.message, contains('Host key changed'));
      expect(
        (await hosts.byId(host.id))?.hostKeyFingerprint,
        'SHA256:not-the-real-key',
      );
    },
  );

  test('wrong password fails with authFailed', skip: _skip, () async {
    final sub = autoAnswer(trusted: true);
    addTearDown(sub.cancel);
    await secrets.write(hostPasswordKey(host.id), 'wrong-password');

    final done = await firstDone(
      SshHostRuntime(host: host, pool: pool),
      'true',
    );
    expect(done.spawnFailed, isTrue);
    expect(done.message, contains('Authentication failed'));
  });

  test(
    'ExecStarted pid is reported and killing it on the remote host ends the run',
    skip: _skip,
    () async {
      final sub = autoAnswer(trusted: true);
      addTearDown(sub.cancel);

      final runtime = SshHostRuntime(host: host, pool: pool);
      final pid = Completer<int>();
      final done = Completer<ExecDone>();
      final events = runtime.run('sleep 60');
      final listening = events.listen((event) {
        switch (event) {
          case ExecStarted e:
            if (!pid.isCompleted) pid.complete(e.pid);
          case ExecDone e:
            if (!done.isCompleted) done.complete(e);
          case ExecStdout() || ExecStderr():
            break;
        }
      });
      addTearDown(listening.cancel);

      final remotePid = await pid.future.timeout(const Duration(seconds: 15));
      expect(remotePid, greaterThan(1));

      await runtime.killProcess(remotePid, force: true);

      final finished = await done.future.timeout(const Duration(seconds: 15));
      expect(finished.exitCode, isNot(0));
      expect(finished.connectionLost, isFalse);
    },
  );

  test('stdout is streamed as UTF-8 bytes', skip: _skip, () async {
    final sub = autoAnswer(trusted: true);
    addTearDown(sub.cancel);

    final runtime = SshHostRuntime(host: host, pool: pool);
    final result = await captureRun(runtime, 'printf "привет"');
    expect(utf8.decode(utf8.encode(result.stdout)), contains('привет'));
  });

  test(
    'command runs in an SSH terminal with the requested size',
    skip: _skip,
    () async {
      final sub = autoAnswer(trusted: true);
      addTearDown(sub.cancel);

      final runtime = SshHostRuntime(host: host, pool: pool);
      final terminal = await runtime.openTerminal(
        '[ -t 0 ] && stty size',
        columns: 100,
        rows: 40,
      );
      final output = await _drainTerminal(terminal);
      expect(output, contains('40 100'));
      expect(await terminal.exitCode, 0);
    },
  );

  test(
    'resize of an SSH terminal reaches the running command',
    skip: _skip,
    () async {
      final sub = autoAnswer(trusted: true);
      addTearDown(sub.cancel);

      final runtime = SshHostRuntime(host: host, pool: pool);
      final terminal = await runtime.openTerminal(
        'sleep 1; stty size',
        columns: 100,
        rows: 40,
      );
      terminal.resize(90, 33);
      final output = await _drainTerminal(terminal);
      expect(output, contains('33 90'));
    },
  );

  test(
    'input typed into an SSH terminal reaches the command',
    skip: _skip,
    () async {
      final sub = autoAnswer(trusted: true);
      addTearDown(sub.cancel);

      final runtime = SshHostRuntime(host: host, pool: pool);
      final terminal = await runtime.openTerminal(
        r'read line; echo "got:$line"',
      );
      terminal.write(Uint8List.fromList(utf8.encode('hello\r')));
      final output = await _drainTerminal(terminal);
      expect(output, contains('got:hello'));
    },
  );

  test(
    'pid of an SSH terminal command is known and kill stops it',
    skip: _skip,
    () async {
      final sub = autoAnswer(trusted: true);
      addTearDown(sub.cancel);

      final runtime = SshHostRuntime(host: host, pool: pool);
      final terminal = await runtime.openTerminal('sleep 30');
      final pid = await terminal.pid.timeout(const Duration(seconds: 15));
      expect(pid, greaterThan(1));
      await runtime.killProcess(pid!, force: true);
      await _drainTerminal(terminal).timeout(const Duration(seconds: 15));
      expect(await terminal.exitCode, isNot(0));
    },
  );
}

/// Читает весь вывод терминала до его завершения.
Future<String> _drainTerminal(HostTerminal terminal) async {
  final out = BytesBuilder();
  await for (final chunk in terminal.attach()) {
    out.add(chunk);
  }
  return utf8.decode(out.takeBytes(), allowMalformed: true);
}

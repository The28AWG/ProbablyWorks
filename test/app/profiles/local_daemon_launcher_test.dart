import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/app/profiles/local_daemon_discovery.dart';
import 'package:probably_works/app/profiles/local_daemon_launcher.dart';
import 'package:pw_agent/core/config/app_paths.dart';
import 'package:pw_agent/core/config/local_daemon_info.dart';

void main() {
  late Directory temp;
  late HttpServer server;
  late AppPaths paths;
  const token = 'daemon-token';

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('pw_daemon_launcher');
    paths = AppPaths.forSupport(temp);
    server = (await HttpServer.bind(InternetAddress.loopbackIPv4, 0))
      ..listen((request) {
        if (request.uri.path == '/api/v1/health') {
          request.response
            ..statusCode = HttpStatus.ok
            ..write('{}')
            ..close();
          return;
        }
        final auth = request.headers.value(HttpHeaders.authorizationHeader);
        request.response
          ..statusCode = auth == 'Bearer $token'
              ? HttpStatus.ok
              : HttpStatus.unauthorized
          ..write('{}')
          ..close();
      });
  });

  tearDown(() async {
    await server.close(force: true);
    temp.deleteSync(recursive: true);
  });

  void writeDaemon({String value = token}) {
    paths.daemonInfo.writeAsStringSync(
      LocalDaemonInfo(
        pid: pid,
        port: server.port,
        token: value,
        startedAt: DateTime.utc(2026, 11, 12),
      ).encode(),
    );
  }

  LocalDaemonDiscovery discovery() {
    final instance = LocalDaemonDiscovery(paths);
    addTearDown(instance.dispose);
    return instance;
  }

  test('uses an already running daemon without starting a process', () async {
    writeDaemon();
    final launcher = _FakeLauncher((_) async => true);
    final starter = LocalDaemonStarter(
      discovery(),
      launcher: launcher,
      environment: const {},
    );

    final info = await starter.ensureRunning(paths);

    expect(info?.port, server.port);
    expect(launcher.calls, 0);
  });

  test('does not start a daemon when autostart is disabled', () async {
    final launcher = _FakeLauncher((p) async {
      writeDaemon();
      return true;
    });
    final starter = LocalDaemonStarter(
      discovery(),
      launcher: launcher,
      environment: const {'PROBABLY_WORKS_NO_DAEMON': '1'},
    );

    expect(await starter.ensureRunning(paths), isNull);
    expect(paths.daemonInfo.existsSync(), isFalse);
    expect(launcher.calls, 0);
  });

  test('starts a daemon and waits for its discovery file', () async {
    final launcher = _FakeLauncher((p) async {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      writeDaemon();
      return true;
    });
    final starter = LocalDaemonStarter(
      discovery(),
      launcher: launcher,
      environment: const {},
    );

    final info = await starter.ensureRunning(paths);

    expect(info?.token, token);
    expect(launcher.calls, 1);
  });

  test('returns null when the daemon does not publish in time', () async {
    final launcher = _FakeLauncher((_) async => true);
    final starter = LocalDaemonStarter(
      discovery(),
      launcher: launcher,
      timeout: const Duration(milliseconds: 250),
      environment: const {},
    );

    expect(await starter.ensureRunning(paths), isNull);
    expect(launcher.calls, 1);
  });

  test('waits for a late daemon without launching another process', () async {
    final launcher = _FakeLauncher((_) async => true);
    final timer = Timer(const Duration(milliseconds: 120), writeDaemon);
    addTearDown(timer.cancel);
    final starter = LocalDaemonStarter(
      discovery(),
      launcher: launcher,
      environment: const {},
    );

    final info = await starter.waitForStartup(
      timeout: const Duration(seconds: 2),
    );

    expect(info?.port, server.port);
    expect(launcher.calls, 0);
  });

  test('chooses launcher by build mode and environment', () {
    expect(
      createDaemonLauncher(release: false, environment: const {}),
      isA<DevelopmentDaemonLauncher>(),
    );
    expect(
      createDaemonLauncher(release: true, environment: const {}),
      isA<PackagedDaemonLauncher>(),
    );
    expect(
      createDaemonLauncher(
        environment: const {'PROBABLY_WORKS_NO_DAEMON': '1'},
      ),
      isA<DisabledDaemonLauncher>(),
    );
    expect(localDaemonDisabled(const {}), isFalse);
    expect(
      localDaemonDisabled(const {'PROBABLY_WORKS_NO_DAEMON': '1'}),
      isTrue,
    );
  });
}

final class _FakeLauncher implements DaemonLauncher {
  _FakeLauncher(this._start);

  final Future<bool> Function(AppPaths paths) _start;
  int calls = 0;

  @override
  Future<bool> start(AppPaths paths) {
    calls++;
    return _start(paths);
  }
}

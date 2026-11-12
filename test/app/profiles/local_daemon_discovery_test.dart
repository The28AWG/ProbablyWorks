import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/app/profiles/local_daemon_discovery.dart';
import 'package:pw_agent/core/config/app_paths.dart';
import 'package:pw_agent/core/config/local_daemon_info.dart';

void main() {
  late Directory temp;
  late HttpServer server;
  late String base;
  const token = 'daemon-token';

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('pw_daemon_discovery');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((request) {
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

  test('returns a valid daemon and verifies its token', () async {
    final paths = AppPaths.forSupport(temp);
    paths.daemonInfo.writeAsStringSync(
      LocalDaemonInfo(
        pid: 42,
        port: server.port,
        token: token,
        startedAt: DateTime.utc(2026, 11, 12),
      ).encode(),
    );

    final discovery = LocalDaemonDiscovery(paths);
    addTearDown(discovery.dispose);
    final info = await discovery.find();

    expect(info?.port, server.port);
    expect(discovery.baseUriFor(info!), Uri.parse(base));
  });

  test('ignores a daemon with an invalid token', () async {
    final paths = AppPaths.forSupport(temp);
    paths.daemonInfo.writeAsStringSync(
      LocalDaemonInfo(
        pid: 42,
        port: server.port,
        token: 'wrong-token',
        startedAt: DateTime.utc(2026, 11, 12),
      ).encode(),
    );

    final discovery = LocalDaemonDiscovery(paths);
    addTearDown(discovery.dispose);

    expect(await discovery.find(), isNull);
  });

  test('ignores a stale protocol and a missing file', () async {
    final paths = AppPaths.forSupport(temp);
    final missing = LocalDaemonDiscovery(paths);
    addTearDown(missing.dispose);
    expect(await missing.find(), isNull);

    paths.daemonInfo.writeAsStringSync(
      LocalDaemonInfo(
        protocol: 999,
        pid: 42,
        port: server.port,
        token: token,
        startedAt: DateTime.utc(2026, 11, 12),
      ).encode(),
    );
    final discovery = LocalDaemonDiscovery(paths);
    addTearDown(discovery.dispose);
    expect(await discovery.find(), isNull);
  });

  test('ignores an unreadable discovery file', () async {
    final paths = AppPaths.forSupport(temp);
    paths.daemonInfo.createSync(recursive: true);

    final discovery = LocalDaemonDiscovery(paths);
    addTearDown(discovery.dispose);

    expect(await discovery.find(), isNull);
  });
}

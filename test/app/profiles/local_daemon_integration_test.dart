import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:probably_works/app/profiles/local_daemon_discovery.dart';
import 'package:pw_agent/core/config/app_paths.dart';
import 'package:pw_agent/core/config/local_daemon_info.dart';
import 'package:pw_agent/core/security/system_secret_store.dart';

/// Сколько ждём запуск демона.
///
/// Первый `dart run` компилирует весь граф пакетов, и на холодном раннере CI
/// это занимает больше минуты.
const _startupTimeout = Duration(minutes: 2);

/// Лимит самого теста.
///
/// Стандартные 30 секунд `package:test` меньше холодного старта демона в CI,
/// поэтому лимит покрывает [_startupTimeout], HTTP-проверки и остановку.
const _testTimeout = Duration(minutes: 4);

/// Запускает настоящий демон и проверяет discovery, API и остановку.
///
/// Тест выключен по умолчанию: он поднимает отдельный процесс и нужен в CI
/// или при ручной проверке. Включается через `PW_DAEMON_TEST=1`.
@Timeout(_testTimeout)
void main() {
  test('starts a real daemon, discovers it and stops cleanly', () async {
    final temp = Directory.systemTemp.createTempSync('pw_daemon_integration');
    final paths = AppPaths.forSupport(temp);
    final dart = _dartExecutable();
    final process = await Process.start(
      dart,
      [
        'run',
        'packages/pw_server/bin/pw_server.dart',
        '--data-dir',
        temp.path,
        '--port',
        '0',
      ],
      workingDirectory: Directory.current.path,
      // Тест проверяет файловый fallback независимо от keyring на машине.
      environment: {...Platform.environment, noKeyringEnvironment: '1'},
    );
    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();
    final subscriptions = [
      process.stdout.transform(utf8.decoder).listen(stdoutBuffer.write),
      process.stderr.transform(utf8.decoder).listen(stderrBuffer.write),
    ];
    var stopped = false;
    var exited = false;
    int? exitCode;
    // Код выхода нужен в сообщении об ошибке: иначе падение демона при старте
    // выглядит как обычное «не дождались daemon.json».
    Future<void> watchExit() async {
      exitCode = await process.exitCode;
      exited = true;
    }

    unawaited(watchExit());

    Future<void> stop() async {
      if (stopped) return;
      stopped = true;
      process.kill(ProcessSignal.sigterm);
      try {
        await process.exitCode.timeout(const Duration(seconds: 10));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
      }
      await Future.wait(subscriptions.map((sub) => sub.cancel()));
    }

    addTearDown(() async {
      if (!stopped) {
        process.kill(ProcessSignal.sigterm);
        await process.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            process.kill(ProcessSignal.sigkill);
            return -1;
          },
        );
      }
      await Future.wait(subscriptions.map((sub) => sub.cancel()));
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    try {
      final info = await _waitForDaemon(temp, () => exited);
      expect(
        info,
        isNotNull,
        reason: [
          if (exitCode != null) 'демон завершился с кодом $exitCode',
          _logs(stdoutBuffer, stderrBuffer),
        ].join('\n'),
      );
      final daemonInfo = info!;
      expect(daemonInfo.pid, process.pid);
      expect(daemonInfo.port, greaterThan(0));
      expect(paths.daemonInfo.existsSync(), isTrue);
      expect(
        paths.daemonInfo.statSync().mode & 0x1ff,
        0x180,
        reason: 'daemon.json должен быть доступен только владельцу (0600)',
      );
      expect(paths.database.existsSync(), isTrue);

      final discovery = LocalDaemonDiscovery(paths);
      addTearDown(discovery.dispose);
      final discovered = await discovery.find();
      expect(discovered?.port, daemonInfo.port);

      final base = Uri.parse('http://127.0.0.1:${daemonInfo.port}');
      final health = await http.get(base.resolve('/api/v1/health'));
      expect(health.statusCode, HttpStatus.ok, reason: health.body);

      final settings = await http.get(
        base.resolve('/api/v1/settings'),
        headers: {'Authorization': 'Bearer ${daemonInfo.token}'},
      );
      expect(settings.statusCode, HttpStatus.ok, reason: settings.body);
    } finally {
      await stop();
    }

    expect(paths.daemonInfo.existsSync(), isFalse);
    if (temp.existsSync()) temp.deleteSync(recursive: true);
    expect(temp.existsSync(), isFalse);
  }, skip: _skipReason);
}

String? get _skipReason {
  if (Platform.isWindows) {
    return 'Интеграционный тест демона использует SIGTERM и пропускается на Windows';
  }
  if (Platform.environment['PW_DAEMON_TEST'] != '1') {
    return 'Установите PW_DAEMON_TEST=1, чтобы запускать реальный демон';
  }
  return null;
}

/// Ждёт `daemon.json`, но не доверяет только файлу: discovery проверяет health.
///
/// [hasExited] позволяет выйти раньше, если процесс завершился: полный
/// [_startupTimeout] в этом случае бессмыслен, а логи уже собраны.
Future<LocalDaemonInfo?> _waitForDaemon(
  Directory temp,
  bool Function() hasExited,
) async {
  final deadline = DateTime.now().add(_startupTimeout);
  final paths = AppPaths.forSupport(temp);
  while (DateTime.now().isBefore(deadline) && !hasExited()) {
    final raw = paths.daemonInfo.existsSync()
        ? paths.daemonInfo.readAsStringSync()
        : null;
    final info = raw == null ? null : LocalDaemonInfo.decode(raw);
    if (info != null) {
      final discovery = LocalDaemonDiscovery(paths);
      try {
        final found = await discovery.find();
        if (found != null) return found;
      } finally {
        discovery.dispose();
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return null;
}

String _logs(StringBuffer stdout, StringBuffer stderr) {
  final out = stdout.toString().trim();
  final err = stderr.toString().trim();
  return [
    if (out.isNotEmpty) 'stdout:\n$out',
    if (err.isNotEmpty) 'stderr:\n$err',
  ].join('\n');
}

String _dartExecutable() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return 'dart';
  final executable = p.join(root, 'bin', 'dart');
  return File(executable).existsSync() ? executable : 'dart';
}

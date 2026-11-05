import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:injectable/injectable.dart';
import 'package:probably_works/core/data/host_repository.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/error/app_failure.dart';
import 'package:probably_works/core/platform/app_platform.dart';
import 'package:probably_works/core/security/secret_store.dart';
import 'package:probably_works/core/util/home_path.dart';
import 'package:probably_works/host/host_capture.dart';
import 'package:probably_works/host/host_op.dart';
import 'package:probably_works/host/host_runtime_factory.dart';

/// Результат проверки подключения. Сохраняется в Host (см. HostRepository.recordCheck).
class HostCheckResult {
  const HostCheckResult({this.latencyMs, this.error, this.kind});

  final int? latencyMs;
  final String? error;
  final HostFailureKind? kind;

  bool get ok => error == null;
}

enum DiagnosticStatus { ok, fail, skip }

/// Один шаг диагностики: что проверили, итог и пояснение. Значения секретов сюда не попадают.
class DiagnosticStep {
  const DiagnosticStep(this.name, this.status, this.message);

  final String name;
  final DiagnosticStatus status;
  final String message;
}

/// Понятный текст причины ошибки подключения (для UI и для модели).
String describeHostFailure(HostFailureKind kind) => switch (kind) {
  HostFailureKind.spawnFailed => 'cannot start the connection',
  HostFailureKind.connectionLost => 'connection lost or host unreachable',
  HostFailureKind.authFailed => 'authentication failed: check the username and the password or key on the Hosts page',
  HostFailureKind.hostKeyMismatch => 'host key changed since the last connection (possible man-in-the-middle): the user must check the host on the Hosts page',
  HostFailureKind.hostKeyRejected => 'host key was rejected',
};

/// Проверка подключения и пошаговая диагностика хоста. Общая для UI (HostsCubit) и инструментов агента.
@lazySingleton
class HostDiagnostics {
  HostDiagnostics(this._hosts, this._secrets, this._settings, this._runtimes);

  final HostRepository _hosts;
  final SecretStore _secrets;
  final SettingsRepository _settings;
  final HostRuntimeFactory _runtimes;

  /// Быстрая проверка: host_info через runtime. Результат сохраняется в Host.
  Future<HostCheckResult> test(Host host) async {
    final clock = Stopwatch()..start();
    var result = const HostCheckResult(error: 'not checked');
    try {
      final run = await captureOp(
        _runtimes.forHost(host),
        const HostInfoOp(),
        timeout: const Duration(seconds: 30),
      );
      clock.stop();
      result = run.ok
          ? HostCheckResult(latencyMs: clock.elapsedMilliseconds)
          : HostCheckResult(
              error: run.stderr.trim().isEmpty
                  ? 'exit ${run.exitCode}'
                  : run.stderr.trim(),
            );
    } on HostFailure catch (failure) {
      clock.stop();
      result = HostCheckResult(
        error: '${describeHostFailure(failure.kind)} (${failure.message})',
        kind: failure.kind,
      );
    } on Object catch (caught) {
      clock.stop();
      result = HostCheckResult(error: '$caught');
    }
    await _hosts.recordCheck(
      host.id,
      at: DateTime.now(),
      latencyMs: result.latencyMs,
      error: result.error,
    );
    return result;
  }

  /// Диагностика по шагам: адрес, учётные данные, ключ сервера и само подключение.
  /// Ключ сервера никогда не принимается автоматически: при смене или первом подключении решает пользователь в UI.
  Future<List<DiagnosticStep>> diagnose(Host host) async {
    final steps = <DiagnosticStep>[
      // Сеть проверяем только у SSH: локальный и виртуальный Host не ходят по сети.
      host.kind == HostKind.ssh
          ? await _reachability(host)
          : DiagnosticStep(
              'reachability',
              DiagnosticStatus.skip,
              '${host.kind.name} host: no network check',
            ),
      await _credentials(host),
      _hostKeyStep(host),
    ];
    final check = await test(host);
    steps.add(
      check.ok
          ? DiagnosticStep(
              'connection',
              DiagnosticStatus.ok,
              'host_info ok, ${check.latencyMs} ms',
            )
          : DiagnosticStep('connection', DiagnosticStatus.fail, check.error!),
    );
    return steps;
  }

  Future<DiagnosticStep> _reachability(Host host) async {
    final address = host.address;
    if (address == null || address.isEmpty) {
      return const DiagnosticStep(
        'reachability',
        DiagnosticStatus.fail,
        'address is empty',
      );
    }
    final timeout = (await _settings.limits()).sshConnectTimeout;
    try {
      final socket = await Socket.connect(address, host.port, timeout: timeout);
      socket.destroy();
      return DiagnosticStep(
        'reachability',
        DiagnosticStatus.ok,
        '$address:${host.port} accepts TCP connections',
      );
    } on SocketException catch (error) {
      return DiagnosticStep(
        'reachability',
        DiagnosticStatus.fail,
        'cannot connect to $address:${host.port}: ${error.message}',
      );
    } on TimeoutException {
      return DiagnosticStep(
        'reachability',
        DiagnosticStatus.fail,
        '$address:${host.port} did not answer within ${timeout.inSeconds} s',
      );
    }
  }

  Future<DiagnosticStep> _credentials(Host host) async {
    if (host.kind != HostKind.ssh) {
      return DiagnosticStep(
        'credentials',
        DiagnosticStatus.skip,
        '${host.kind.name} host: no credentials',
      );
    }
    if (host.authType == SshAuthType.password) {
      final password = await _secrets.read(hostPasswordKey(host.id));
      return password == null
          ? const DiagnosticStep(
              'credentials',
              DiagnosticStatus.fail,
              'no password stored: enter it on the Hosts page',
            )
          : const DiagnosticStep(
              'credentials',
              DiagnosticStatus.ok,
              'password is stored',
            );
    }
    final stored = await _secrets.read(hostPrivateKeyKey(host.id));
    if (stored != null) return _checkKey(host, stored, 'stored key');
    final keyPath = host.keyPath;
    if (keyPath == null || keyPath.isEmpty) {
      return const DiagnosticStep(
        'credentials',
        DiagnosticStatus.fail,
        'no private key: set a key path or store the key on the Hosts page',
      );
    }
    if (!AppPlatform.current.canOpenExternalKeys) {
      return const DiagnosticStep(
        'credentials',
        DiagnosticStatus.fail,
        'key file cannot be read on this platform: store the key on the Hosts page',
      );
    }
    try {
      final file = File(expandHomePath(keyPath));
      if (!file.existsSync()) {
        return DiagnosticStep(
          'credentials',
          DiagnosticStatus.fail,
          'key file not found: $keyPath',
        );
      }
      return await _checkKey(
        host,
        file.readAsStringSync(),
        'key file $keyPath',
      );
    } on FileSystemException catch (error) {
      return DiagnosticStep(
        'credentials',
        DiagnosticStatus.fail,
        'cannot read key file: ${error.message}',
      );
    }
  }

  /// Проверяет, что ключ загружается с сохранённой passphrase (если она есть). Сам ключ не возвращается.
  Future<DiagnosticStep> _checkKey(Host host, String pem, String source) async {
    final passphrase = await _secrets.read(hostPassphraseKey(host.id));
    try {
      SSHKeyPair.fromPem(pem, passphrase);
      return DiagnosticStep(
        'credentials',
        DiagnosticStatus.ok,
        '$source loads${passphrase == null ? '' : ' with the stored passphrase'}',
      );
    } on Object {
      return DiagnosticStep(
        'credentials',
        DiagnosticStatus.fail,
        passphrase == null
            ? '$source cannot be loaded: it may be encrypted, enter its passphrase on the Hosts page'
            : '$source cannot be loaded with the stored passphrase',
      );
    }
  }

  DiagnosticStep _hostKeyStep(Host host) {
    if (host.kind != HostKind.ssh) {
      return DiagnosticStep(
        'host key',
        DiagnosticStatus.skip,
        '${host.kind.name} host: no host key',
      );
    }
    return host.hostKeyFingerprint == null
        ? const DiagnosticStep(
            'host key',
            DiagnosticStatus.skip,
            'not confirmed yet: the first connection asks the user',
          )
        : const DiagnosticStep(
            'host key',
            DiagnosticStatus.ok,
            'confirmed earlier; a change is detected on connection',
          );
  }
}

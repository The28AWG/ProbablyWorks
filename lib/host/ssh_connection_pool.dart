import 'dart:async';
import 'dart:convert';
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

/// Запрос подтверждения отпечатка ключа хоста: UI показывает диалог и отвечает через [HostKeyConfirmations].
class HostKeyRequest {
  const HostKeyRequest({
    required this.id,
    required this.host,
    required this.fingerprint,
    required this.isChanged,
  });

  final String id;
  final Host host;
  final String fingerprint;

  /// true — ключ изменился относительно сохранённого (блок, пока пользователь не доверит явно).
  final bool isChanged;
}

/// Очередь подтверждений host key. Первое подключение и смена ключа требуют ответа пользователя.
@lazySingleton
class HostKeyConfirmations {
  final _requests = StreamController<HostKeyRequest>.broadcast();
  final Map<String, Completer<bool>> _pending = {};
  int _counter = 0;

  Stream<HostKeyRequest> get requests => _requests.stream;

  Future<bool> ask(Host host, String fingerprint, {required bool isChanged}) {
    final id = 'hk-${++_counter}';
    final completer = Completer<bool>();
    _pending[id] = completer;
    _requests.add(
      HostKeyRequest(
        id: id,
        host: host,
        fingerprint: fingerprint,
        isChanged: isChanged,
      ),
    );
    return completer.future;
  }

  void resolve(String id, {required bool trusted}) =>
      _pending.remove(id)?.complete(trusted);
}

/// Пул SSH-соединений: один SSHClient на Host, закрывается после простоя.
@lazySingleton
class SshConnectionPool {
  SshConnectionPool(
    this._hosts,
    this._secrets,
    this._settings,
    this._confirmations,
  );

  final HostRepository _hosts;
  final SecretStore _secrets;
  final SettingsRepository _settings;
  final HostKeyConfirmations _confirmations;

  final Map<String, Future<SSHClient>> _clients = {};
  final Map<String, int> _activeRuns = {};
  final Map<String, Timer> _idleTimers = {};

  Future<SSHClient> client(Host host) async {
    final existing = _clients[host.id];
    if (existing != null) {
      final connected = await existing;
      return connected.isClosed ? _reconnect(host) : connected;
    }
    return _reconnect(host);
  }

  Future<SSHClient> _reconnect(Host host) {
    final future = _connect(host);
    _clients[host.id] = future;
    unawaited(() async {
      try {
        await future;
      } on Object {
        _clients.remove(host.id);
      }
    }());
    return future;
  }

  void acquire(String hostId) {
    _idleTimers.remove(hostId)?.cancel();
    _activeRuns[hostId] = (_activeRuns[hostId] ?? 0) + 1;
  }

  /// После последнего exec на Host соединение закрывается через простой [idle].
  void release(String hostId, {Duration idle = const Duration(minutes: 5)}) {
    final left = (_activeRuns[hostId] ?? 1) - 1;
    _activeRuns[hostId] = left;
    if (left > 0) return;
    _idleTimers[hostId]?.cancel();
    _idleTimers[hostId] = Timer(idle, () => close(hostId));
  }

  Future<void> close(String hostId) async {
    _idleTimers.remove(hostId)?.cancel();
    final future = _clients.remove(hostId);
    if (future == null) return;
    try {
      (await future).close();
    } on Object {
      // Уже не подключён — ничего не делаем.
    }
  }

  Future<SSHClient> _connect(Host host) async {
    final address = host.address;
    if (address == null || address.isEmpty) {
      throw const HostFailure(
        'SSH host address is empty',
        kind: HostFailureKind.spawnFailed,
      );
    }
    final limits = await _settings.limits();
    final timeout = Duration(
      seconds: host.connectTimeoutSeconds ?? limits.sshConnectTimeout.inSeconds,
    );
    final socket = await SSHSocket.connect(
      address,
      host.port,
      timeout: timeout,
    );
    final password = await _secrets.read(hostPasswordKey(host.id));
    final identities = await _loadIdentities(host);

    // dartssh2 обрывает подключение при ошибке verify и теряет причину, поэтому запоминаем её здесь.
    HostFailure? hostKeyError;
    final client = SSHClient(
      socket,
      username: host.username ?? '',
      keepAliveInterval: limits.sshKeepAlive,
      identities: identities,
      onPasswordRequest: password == null ? null : () => password,
      // Многие серверы (PAM) принимают пароль только через keyboard-interactive.
      // Пароль отдаём лишь на запросы без эха; запросы с эхом (например, код 2FA) не заполняем.
      onUserInfoRequest: password == null
          ? null
          : (request) => request.prompts.any((p) => p.echo)
                ? null
                : List.filled(request.prompts.length, password),
      onVerifyHostKey: (type, fingerprint) async {
        try {
          return await _verify(host, utf8.decode(fingerprint));
        } on HostFailure catch (error) {
          hostKeyError = error;
          rethrow;
        }
      },
    );
    try {
      await client.authenticated;
    } on Object catch (error, stack) {
      client.close();
      if (hostKeyError != null) {
        Error.throwWithStackTrace(hostKeyError!, stack);
      }
      if (error is HostFailure) {
        Error.throwWithStackTrace(error, stack);
      }
      Error.throwWithStackTrace(
        HostFailure(
          'Authentication failed: $error',
          kind: HostFailureKind.authFailed,
        ),
        stack,
      );
    }
    return client;
  }

  Future<bool> _verify(Host host, String fingerprint) async {
    final stored = host.hostKeyFingerprint;
    if (stored == fingerprint) return true;
    final trusted = await _confirmations.ask(
      host,
      fingerprint,
      isChanged: stored != null,
    );
    if (!trusted) {
      throw HostFailure(
        stored == null ? 'Host key rejected by user' : 'Host key changed',
        kind: stored == null
            ? HostFailureKind.hostKeyRejected
            : HostFailureKind.hostKeyMismatch,
      );
    }
    final repo = _hosts;
    await repo.save(host.copyWith(hostKeyFingerprint: fingerprint));
    return true;
  }

  /// PEM берётся из secure storage. Файл по [Host.keyPath] (с раскрытием `~`) читается только там, где это возможно.
  Future<List<SSHKeyPair>?> _loadIdentities(Host host) async {
    if (host.authType != SshAuthType.key) return null;
    final stored = await _secrets.read(hostPrivateKeyKey(host.id));
    final fromPath =
        host.keyPath != null && AppPlatform.current.canOpenExternalKeys;
    final pem =
        stored ??
        (fromPath
            ? await File(expandHomePath(host.keyPath!)).readAsString()
            : null);
    if (pem == null) return null;
    final passphrase = await _secrets.read(hostPassphraseKey(host.id));
    return SSHKeyPair.fromPem(pem, passphrase);
  }
}

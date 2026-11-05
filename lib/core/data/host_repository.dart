import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';
import 'package:probably_works/core/db/app_database.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/platform/app_platform.dart';
import 'package:probably_works/core/security/secret_store.dart';

/// Хосты в SQLite. Переменные окружения — JSON в [SecretStore] (`host.<id>.environment`):
/// значения могут быть токенами, поэтому колонки в таблице нет.
@lazySingleton
class HostRepository {
  HostRepository(this._db, this._secrets);

  final AppDatabase _db;
  final SecretStore _secrets;

  $HostsTable get _hostsTable => _db.hosts;

  static const localHostId = 'local';

  Stream<List<Host>> watchAll() =>
      (_db.select(_hostsTable)..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .watch()
          .asyncMap(_withEnvironment);

  Future<List<Host>> all() async => _withEnvironment(
    await (_db.select(
      _hostsTable,
    )..orderBy([(t) => OrderingTerm.asc(t.createdAt)])).get(),
  );

  Future<Host?> byId(String id) async {
    final row = await (_db.select(
      _hostsTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _toDomain(row);
  }

  /// Создаёт локальный Host, если его ещё нет. Он неудаляемый.
  /// На платформах без локального Host (iOS) ничего не создаёт.
  Future<void> ensureLocalHost(DateTime now) async {
    if (!AppPlatform.current.hasLocalHost) return;
    if (await byId(localHostId) != null) return;
    await save(
      Host(
        id: localHostId,
        name: 'Local',
        kind: HostKind.local,
        createdAt: now,
        updatedAt: now,
        os: _currentOs(),
      ),
    );
  }

  /// Пишет строку, затем карту окружения. Недопустимое имя бросает [ArgumentError] до любой записи,
  /// чтобы битое имя не оставило ни строку, ни секрет. Пустая карта удаляет ключ: старый секрет не остаётся.
  Future<void> save(Host host) async {
    _requireEnvironmentNames(host.environment);
    await _db.into(_hostsTable).insertOnConflictUpdate(_toRow(host));
    await _writeEnvironment(host.id, host.environment);
  }

  /// Пишет только результат проверки: не затирает остальные поля Host и секрет окружения.
  Future<void> recordCheck(
    String id, {
    required DateTime at,
    int? latencyMs,
    String? error,
  }) => (_db.update(_hostsTable)..where((t) => t.id.equals(id))).write(
    HostsCompanion(
      lastCheckAt: Value(at),
      lastLatencyMs: Value(latencyMs),
      lastCheckError: Value(error),
    ),
  );

  /// Удаляет строку и ключ окружения. Пароль и ключ SSH снимает вызывающий код: они пишутся отдельно.
  Future<void> delete(String id) async {
    await (_db.delete(_hostsTable)..where((t) => t.id.equals(id))).go();
    await _secrets.delete(hostEnvironmentKey(id));
  }

  static HostOs _currentOs() {
    if (Platform.isMacOS) return HostOs.macos;
    if (Platform.isWindows) return HostOs.windows;
    return HostOs.posix;
  }

  Future<List<Host>> _withEnvironment(List<HostRow> rows) async {
    final hosts = <Host>[];
    for (final row in rows) {
      hosts.add(await _toDomain(row));
    }
    return hosts;
  }

  Future<Host> _toDomain(HostRow row) async => Host(
    id: row.id,
    name: row.name,
    kind: HostKind.values.byName(row.kind),
    address: row.address,
    port: row.port,
    username: row.username,
    authType: SshAuthType.values.byName(row.authType),
    keyPath: row.keyPath,
    hostKeyFingerprint: row.hostKeyFingerprint,
    os: HostOs.values.byName(row.osFamily),
    defaultWorkspace: row.defaultWorkspace,
    shellOverride: row.shellOverride,
    notes: row.notes,
    connectTimeoutSeconds: row.connectTimeoutSeconds,
    lastCheckAt: row.lastCheckAt,
    lastLatencyMs: row.lastLatencyMs,
    lastCheckError: row.lastCheckError,
    environment: await _readEnvironment(row.id),
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );

  HostsCompanion _toRow(Host host) => HostsCompanion.insert(
    id: host.id,
    name: host.name,
    kind: host.kind.name,
    address: Value(host.address),
    port: Value(host.port),
    username: Value(host.username),
    authType: Value(host.authType.name),
    keyPath: Value(host.keyPath),
    hostKeyFingerprint: Value(host.hostKeyFingerprint),
    osFamily: Value(host.os.name),
    defaultWorkspace: Value(host.defaultWorkspace),
    shellOverride: Value(host.shellOverride),
    notes: Value(host.notes),
    connectTimeoutSeconds: Value(host.connectTimeoutSeconds),
    lastCheckAt: Value(host.lastCheckAt),
    lastLatencyMs: Value(host.lastLatencyMs),
    lastCheckError: Value(host.lastCheckError),
    createdAt: host.createdAt,
    updatedAt: host.updatedAt,
  );

  void _requireEnvironmentNames(Map<String, String> environment) {
    for (final name in environment.keys) {
      if (!isHostEnvironmentName(name)) {
        throw ArgumentError.value(
          name,
          'environment',
          'Имя переменной должно совпадать с [A-Za-z_][A-Za-z0-9_]*.',
        );
      }
    }
  }

  Future<void> _writeEnvironment(
    String id,
    Map<String, String> environment,
  ) async {
    final key = hostEnvironmentKey(id);
    if (environment.isEmpty) {
      await _secrets.delete(key);
      return;
    }
    await _secrets.write(key, jsonEncode(environment));
  }

  /// Битый JSON, не-объект и значение не-строка дают пустую карту: список хостов не должен падать
  /// из-за повреждённого секрета. Частичную карту не возвращаем — в ней мог остаться чужой токен.
  Future<Map<String, String>> _readEnvironment(String id) async {
    final raw = await _secrets.read(hostEnvironmentKey(id));
    if (raw == null || raw.isEmpty) return const {};
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const {};
    }
    if (decoded is! Map) return const {};
    final environment = <String, String>{};
    for (final entry in decoded.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || value is! String || !isHostEnvironmentName(key)) {
        return const {};
      }
      environment[key] = value;
    }
    return environment;
  }
}

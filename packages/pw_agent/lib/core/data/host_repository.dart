import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/platform/local_system_info.dart';
import 'package:pw_agent/core/platform/platform_profile.dart';
import 'package:pw_agent/core/security/secret_store.dart';

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
    if (!PlatformProfile.current.hasLocalHost) return;
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
  ///
  /// [expectedRevision] — ревизия, на которой основана форма. При несовпадении
  /// бросает `409 host_conflict` до записи: два окна не затирают поля друг
  /// друга. Без неё (служебная запись, миграция) ревизия просто растёт.
  Future<void> save(Host host, {int? expectedRevision}) async {
    _requireEnvironmentNames(host.environment);
    final row = _toRow(host);
    if (expectedRevision == null) {
      final current = await (_db.select(
        _hostsTable,
      )..where((t) => t.id.equals(host.id))).getSingleOrNull();
      await _db
          .into(_hostsTable)
          .insertOnConflictUpdate(
            row.copyWith(revision: Value((current?.revision ?? 0) + 1)),
          );
    } else {
      // Сравнение и запись — один UPDATE: два окна не проходят проверку
      // одновременно и потом не затирают друг друга.
      final next = expectedRevision + 1;
      final updated =
          await (_db.update(_hostsTable)..where(
                (t) =>
                    t.id.equals(host.id) & t.revision.equals(expectedRevision),
              ))
              .write(row.copyWith(revision: Value(next)));
      if (updated == 0) {
        final exists = await (_db.select(
          _hostsTable,
        )..where((t) => t.id.equals(host.id))).getSingleOrNull();
        if (exists != null || expectedRevision != 0) {
          throw const AgentApiException(
            409,
            'host_conflict',
            'host was changed by another client',
          );
        }
        final inserted = await _db
            .into(_hostsTable)
            .insert(
              row.copyWith(revision: Value(next)),
              mode: InsertMode.insertOrIgnore,
            );
        if (inserted == 0) {
          throw const AgentApiException(
            409,
            'host_conflict',
            'host was changed by another client',
          );
        }
      }
    }
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

  Future<Host> _toDomain(HostRow row) async {
    final kind = HostKind.values.byName(row.kind);
    return Host(
      id: row.id,
      name: row.name,
      kind: kind,
      address: row.address,
      port: row.port,
      username: row.username,
      authType: SshAuthType.values.byName(row.authType),
      keyPath: row.keyPath,
      hostKeyFingerprint: row.hostKeyFingerprint,
      os: HostOs.values.byName(row.osFamily),
      // Подпись системы относится к машине, где работает агент, поэтому есть
      // только у локального Host. В БД её нет: она вычисляется при чтении.
      systemLabel: kind == HostKind.local
          ? LocalSystemInfo.current?.displayName
          : null,
      defaultWorkspace: row.defaultWorkspace,
      shellOverride: row.shellOverride,
      notes: row.notes,
      connectTimeoutSeconds: row.connectTimeoutSeconds,
      lastCheckAt: row.lastCheckAt,
      lastLatencyMs: row.lastLatencyMs,
      lastCheckError: row.lastCheckError,
      environment: await _readEnvironment(row.id),
      revision: row.revision,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }

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
    revision: Value(host.revision),
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

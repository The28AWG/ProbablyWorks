import 'dart:io';

import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';
import 'package:probably_works/core/db/app_database.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/platform/app_platform.dart';

@lazySingleton
class HostRepository {
  HostRepository(this._db);

  final AppDatabase _db;

  $HostsTable get _hostsTable => _db.hosts;

  static const localHostId = 'local';

  Stream<List<Host>> watchAll() =>
      (_db.select(_hostsTable)..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .watch()
          .map((rows) => rows.map(_toDomain).toList());

  Future<List<Host>> all() async =>
      (await (_db.select(
            _hostsTable,
          )..orderBy([(t) => OrderingTerm.asc(t.createdAt)])).get())
          .map(_toDomain)
          .toList();

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

  Future<void> save(Host host) => _db
      .into(_hostsTable)
      .insertOnConflictUpdate(
        HostsCompanion.insert(
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
        ),
      );

  /// Пишет только результат проверки: не затирает остальные поля Host.
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

  Future<void> delete(String id) =>
      (_db.delete(_hostsTable)..where((t) => t.id.equals(id))).go();

  static HostOs _currentOs() {
    if (Platform.isMacOS) return HostOs.macos;
    if (Platform.isWindows) return HostOs.windows;
    return HostOs.posix;
  }

  Host _toDomain(HostRow row) => Host(
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
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );
}
